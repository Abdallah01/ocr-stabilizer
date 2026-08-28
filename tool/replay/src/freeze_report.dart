// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

import 'capture_stream.dart';
import 'replay_session.dart';
import 'stats.dart';

/// #57 decision data: replay the observation stream with the band path in
/// `admit` mode and report what the provisional freeze actually does —
/// freeze frequency, evidence lost, promotion latency — as computed by the
/// package's own funnel.
///
/// Viewport (2.1.0): [viewport] overrides, else the stream's `meta.vp`;
/// the EFFECTIVE value is applied and recorded in the report's `input`
/// block (null = the engine's default buckets). The position-merge model
/// is replay()'s `legacy` default and is recorded too; this report's
/// outputs are counts and text fields, which the model does not change.
Map<String, Object?> freezeReport(
  CaptureStream stream, {
  int? candidateObservationFloor,
  Viewport? viewport,
  BucketPolicy bucketPolicy = BucketPolicy.auto,
}) {
  final effective = viewport ?? stream.viewport;
  final result = replay(
    stream,
    band: BandFallbackConfig(
      mode: BandFallbackMode.admit,
      candidateObservationFloor: candidateObservationFloor,
    ),
    viewport: effective,
    useStreamViewport: false,
    bucketPolicy: bucketPolicy,
  );

  final freezes = result.freezes.toList();
  final differing = freezes.where((f) => f.textDiffers).toList();
  final highConfDiffering =
      differing.where((f) => f.freshTconf >= 0.8).length;
  final promoted = result.chains.where((c) => c.promoted).toList();
  final s = result.stats;

  return {
    'mode': 'freeze-report',
    'input': {
      'batches': result.batches,
      'observations': result.observations,
      'skippedLines': stream.skippedLines,
      'invalidRecords': stream.invalidRecords,
      'viewport': viewportJson(effective),
      'positionMergeModel': 'legacy',
      'bucketPolicy': bucketPolicy.name,
      'bucketsApplied': bucketsJson(result),
    },
    'funnel': {
      'primaryMatchesAdmitted': s.primaryMatchesAdmitted,
      'primaryMatchesRejected': s.primaryMatchesRejected,
      'candidatesConsidered': s.candidatesConsidered,
      'rejectedCandidateFloor': s.rejectedCandidateFloor,
      'rejectedSpatial': s.rejectedSpatial,
      'rejectedTextBand': s.rejectedTextBand,
      'bandMatchesIdentified': s.bandMatchesIdentified,
      'matchesAdmitted': s.matchesAdmitted,
    },
    'freeze': {
      'totalMerges': result.merges.length,
      'frozenMerges': freezes.length,
      'frozenShare': share(freezes.length, result.merges.length),
      'freshTconf': NumStats([for (final f in freezes) f.freshTconf]).toJson(),
      'textDiffers': differing.length,
      'textDiffersShare': share(differing.length, freezes.length),
      'highConfDiscardedVotes': highConfDiffering,
    },
    'provisional': {
      'admissions': result.chains.length,
      'promoted': promoted.length,
      'unresolved': result.chains.length - promoted.length,
      'promotionLatencyCaptures':
          NumStats([for (final c in promoted) c.latencyCaptures!]).toJson(),
      'freezesPerChain':
          NumStats([for (final c in result.chains) c.freezes]).toJson(),
    },
    'caveats': [
      'Replay starts from an empty engine (no consumer cache seed).',
      'Unresolved chains = admitted blocks never re-observed to expiry. '
          'Replay uses missedFrameRetention: 0 (matching current consumer '
          'production config), so a single missed capture — routine OCR '
          'glare, not necessarily scroll-away — permanently drops a '
          'provisional block; do not read unresolved as purely '
          '"scrolled away". The live-report view is the consumer-side '
          'complement.',
    ],
  };
}
