// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'capture_stream.dart';
import 'stats.dart';

/// Max rect-center distance for a terminal event to join a band_stamp of
/// the same text. Generous enough for drift/merge movement inside one
/// provisional window; far smaller than distinct page positions.
const double _joinRadiusPx = 200;

(double, double)? _center(Map? blockRef) {
  final rect = (blockRef?['rect'] as List?)?.cast<num>();
  if (rect == null || rect.length != 4) return null;
  return ((rect[0] + rect[2]) / 2, (rect[1] + rect[3]) / 2);
}

/// #57 consumer-side view: aggregate the lifecycle events the consumer
/// recorded from its own integration (no replay). Complements
/// freeze-report: this is what the freeze path did in production, under
/// the consumer's own provisional admission.
Map<String, Object?> liveReport(CaptureStream stream) {
  final byType = <String, List<Map<String, Object?>>>{};
  for (final e in stream.events) {
    byType.putIfAbsent(e['t'] as String, () => []).add(e);
  }
  final merges = byType['merge'] ?? const [];
  final freezes = byType['freeze'] ?? const [];
  final stamps = byType['band_stamp'] ?? const [];
  final decrements = byType['band_decrement'] ?? const [];
  final resolves = byType['cluster_resolve'] ?? const [];

  final differs =
      freezes.where((f) => f['differs'] == true).toList();
  final highConfDiscarded = differs
      .where((f) => ((f['freshTconf'] as num?) ?? 0) >= 0.8)
      .length;
  final expiredDecrements =
      decrements.where((d) => d['expired'] == true).length;
  final evictedTotal = resolves.fold<int>(
      0, (sum, r) => sum + ((r['evicted'] as List?)?.length ?? 0));

  // Promotion latency: join each terminal event (expired decrement or
  // cluster resolve) back to the band_stamp that opened the window, by
  // original text AND rect proximity — text alone false-joins recurring
  // strings (chapter headers, repeated UI labels) across unrelated
  // windows, silently corrupting the latency stats. The join picks the
  // LATEST stamp at-or-before the terminal capture whose rect center is
  // within [_joinRadiusPx]. Unjoined terminals are reported, not dropped.
  final stampsByText = <String, List<({int cap, double cx, double cy})>>{};
  for (final s in stamps) {
    for (final side in ['fresh', 'existing']) {
      final ref = s[side] as Map?;
      final text = ref?['otext'] as String?;
      final cap = (s['cap'] as num?)?.toInt();
      final center = _center(ref);
      if (text != null && cap != null && center != null) {
        stampsByText
            .putIfAbsent(text, () => [])
            .add((cap: cap, cx: center.$1, cy: center.$2));
      }
    }
  }
  final latencies = <int>[];
  var unjoined = 0;
  void joinTerminal(Map? blockRef, int? cap) {
    final text = blockRef?['otext'] as String?;
    final center = _center(blockRef);
    if (text == null || cap == null || center == null) {
      unjoined++;
      return;
    }
    ({int cap, double cx, double cy})? best;
    for (final s in stampsByText[text] ?? const []) {
      if (s.cap > cap) continue;
      final dx = s.cx - center.$1;
      final dy = s.cy - center.$2;
      if (dx * dx + dy * dy > _joinRadiusPx * _joinRadiusPx) continue;
      if (best == null || s.cap > best.cap) best = s;
    }
    if (best == null) {
      unjoined++;
    } else {
      latencies.add(cap - best.cap);
    }
  }

  for (final d in decrements.where((d) => d['expired'] == true)) {
    joinTerminal(d['block'] as Map?, (d['cap'] as num?)?.toInt());
  }
  for (final r in resolves) {
    joinTerminal(r['survivor'] as Map?, (r['cap'] as num?)?.toInt());
  }

  return {
    'mode': 'live-report',
    'input': {
      'obsBatches': stream.batches.length,
      'observations': stream.observationCount,
      'events': stream.events.length,
      'skippedLines': stream.skippedLines,
      'invalidRecords': stream.invalidRecords,
    },
    'freeze': {
      'merges': merges.length,
      'frozenMerges': freezes.length,
      'frozenShare': share(freezes.length, merges.length + freezes.length),
      'textDiffers': differs.length,
      'highConfDiscardedVotes': highConfDiscarded,
      'freshTconf': NumStats(
              [for (final f in freezes) (f['freshTconf'] as num?) ?? 0])
          .toJson(),
    },
    'provisionalLifecycle': {
      'bandStamps': stamps.length,
      'bandDecrements': decrements.length,
      'inlineExpiries': expiredDecrements,
      'clusterResolves': resolves.length,
      'noRivalResolves':
          resolves.where((r) => r['noRivals'] == true).length,
      'evictedInResolution': evictedTotal,
      'promotionLatencyCaptures': NumStats(latencies).toJson(),
      'unjoinedTerminals': unjoined,
    },
  };
}
