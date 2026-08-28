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
/// Viewport (2.1.0): [viewport] overrides, else the stream's `meta.vp`;
/// the EFFECTIVE value is applied to both arms and recorded in the
/// report's `input` block, so a committed `.ab.json` says which geometry
/// produced its numbers (null = the engine's default buckets). Recording
/// the parameter alone printed null for a replay that ran on the header
/// viewport (PR #111 review).
Map<String, Object?> abReport(
  CaptureStream stream, {
  Viewport? viewport,
  BucketPolicy bucketPolicy = BucketPolicy.auto,
}) {
  final effective = viewport ?? stream.viewport;
  final legacy = replay(stream,
      model: PositionMergeModel.legacy,
      viewport: effective,
      useStreamViewport: false,
      bucketPolicy: bucketPolicy);
  final agreement = replay(stream,
      model: PositionMergeModel.agreementWeighted,
      viewport: effective,
      useStreamViewport: false,
      bucketPolicy: bucketPolicy);

  return {
    'mode': 'ab-report',
    'input': {
      'batches': stream.batches.length,
      'observations': stream.observationCount,
      'skippedLines': stream.skippedLines,
      'invalidRecords': stream.invalidRecords,
      'viewport': viewportJson(effective),
      // 2.2.0 (#113): requested policy, and what each arm actually
      // applied after the viewport formula (per arm — the medianHeight
      // emulation reads the tracked state, which evolves per model).
      'bucketPolicy': bucketPolicy.name,
      'bucketsApplied': {
        'legacy': bucketsJson(legacy),
        'agreementWeighted': bucketsJson(agreement),
      },
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
  // Nested-fragment confirmations (2.2.0, #112) keep the existing geometry
  // by construction: a zero-displacement, unchanged-pconf sample. Folding
  // them into the buckets would pull every mean toward 0 without a single
  // box having moved — so they are counted, and excluded from the
  // position statistics.
  final nested = r.merges.where((m) => m.nestedFragment).length;
  final positional = r.merges.where((m) => !m.nestedFragment).toList();
  final byBucket = <String, List<MergeSample>>{};
  for (final m in positional) {
    byBucket.putIfAbsent(_bucket(m.obsNBefore), () => []).add(m);
  }
  final wellObserved =
      positional.where((m) => m.obsNBefore >= 5).toList();
  return {
    'mergeCount': r.merges.length,
    'nestedFragmentMerges': nested,
    // Jitter: displacement of the merged position per re-observation,
    // bucketed by how well-observed the block already was. A stabilizing
    // model should push displacement toward 0 as n grows. Over the
    // `mergeCount − nestedFragmentMerges` position merges.
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
