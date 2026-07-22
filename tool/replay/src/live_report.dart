// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'capture_stream.dart';
import 'stats.dart';

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
  // exact original text. Unjoined terminals are reported, not dropped.
  final stampCapByText = <String, int>{};
  for (final s in stamps) {
    for (final side in ['fresh', 'existing']) {
      final text = ((s[side] as Map?)?['otext']) as String?;
      final cap = (s['cap'] as num?)?.toInt();
      if (text != null && cap != null) {
        stampCapByText.putIfAbsent(text, () => cap);
      }
    }
  }
  final latencies = <int>[];
  var unjoined = 0;
  void joinTerminal(String? text, int? cap) {
    if (text == null || cap == null) return;
    final start = stampCapByText[text];
    if (start == null || cap < start) {
      unjoined++;
    } else {
      latencies.add(cap - start);
    }
  }

  for (final d in decrements.where((d) => d['expired'] == true)) {
    joinTerminal(
        ((d['block'] as Map?)?['otext']) as String?,
        (d['cap'] as num?)?.toInt());
  }
  for (final r in resolves) {
    joinTerminal(
        ((r['survivor'] as Map?)?['otext']) as String?,
        (r['cap'] as num?)?.toInt());
  }

  return {
    'mode': 'live-report',
    'input': {
      'obsBatches': stream.batches.length,
      'observations': stream.observationCount,
      'events': stream.events.length,
      'skippedLines': stream.skippedLines,
    },
    'freeze': {
      'merges': merges.length,
      'frozenMerges': freezes.length,
      'frozenShare': merges.isEmpty && freezes.isEmpty
          ? null
          : (freezes.length * 1000 ~/
                  (merges.length + freezes.length)) /
              1000,
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
