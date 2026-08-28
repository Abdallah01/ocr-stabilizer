// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

import 'capture_stream.dart';
import 'replay_session.dart';
import 'stats.dart';

/// #58 decision data: replay the SAME observation stream through both
/// position-merge models (band off) and compare positional stickiness and
/// confidence informativeness. Same input for both arms — a cleaner A/B
/// than two separate live sessions could provide.
///
/// [viewport] (2.1.0) is applied to both arms via `updateViewport` and
/// recorded in the report's `input` block, so a committed `.ab.json` says
/// which geometry produced its numbers; null means default buckets.
Map<String, Object?> abReport(CaptureStream stream, {Viewport? viewport}) {
  final legacy =
      replay(stream, model: PositionMergeModel.legacy, viewport: viewport);
  final agreement = replay(stream,
      model: PositionMergeModel.agreementWeighted, viewport: viewport);

  return {
    'mode': 'ab-report',
    'input': {
      'batches': stream.batches.length,
      'observations': stream.observationCount,
      'skippedLines': stream.skippedLines,
      'invalidRecords': stream.invalidRecords,
      'viewport': viewport == null
          ? null
          : {'width': viewport.width, 'height': viewport.height},
    },
    'legacy': _arm(legacy),
    'agreementWeighted': _arm(agreement),
    'caveats': [
      'Arms may diverge in pairing over time: positions evolve per model, '
          'and matching is spatial+text. Compare mergeCount before reading '
          'displacement deltas.',
      'Replay pairing uses the package funnel, not the consumer\'s own '
          'matching stage; consumer-side `merge` events in live-report give '
          'the production-path legacy reference.',
    ],
  };
}

Map<String, Object?> _arm(ReplayResult r) {
  final byBucket = <String, List<MergeSample>>{};
  for (final m in r.merges) {
    byBucket.putIfAbsent(_bucket(m.obsNBefore), () => []).add(m);
  }
  final wellObserved =
      r.merges.where((m) => m.obsNBefore >= 5).toList();
  return {
    'mergeCount': r.merges.length,
    // Jitter: displacement of the merged position per re-observation,
    // bucketed by how well-observed the block already was. A stabilizing
    // model should push displacement toward 0 as n grows.
    'displacementByObsN': {
      for (final e in byBucket.entries)
        e.key: NumStats([for (final m in e.value) m.displacement]).toJson(),
    },
    // Confidence informativeness on well-observed blocks: legacy's
    // saturating sum pins pconf at 1.0 (zero information for NMS /
    // qualityScore); agreement-weighted should show spread.
    'wellObservedPconf':
        NumStats([for (final m in wellObserved) m.pconfAfter]).toJson(),
    'wellObservedPconfSaturated': share(
        wellObserved.where((m) => m.pconfAfter >= 0.999).length,
        wellObserved.length),
  };
}

String _bucket(int obsN) {
  if (obsN <= 2) return 'n1-2';
  if (obsN <= 5) return 'n3-5';
  if (obsN <= 10) return 'n6-10';
  return 'n11+';
}
