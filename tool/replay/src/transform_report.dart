// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

import 'capture_stream.dart';
import 'replay_session.dart';

/// #135: replay [stream] through the SHIPPING configuration
/// (`agreementWeighted`, `StepResponse.coherentShift`,
/// `coherentShiftAdoptAgreeing: true` — the engine's own defaults, named
/// explicitly so this report cannot drift with them) and record every
/// capture's `StabilizationResult.transformEstimate`.
///
/// A separate mode rather than an `ab-report` field: the committed
/// `.ab.json` reports are held byte-identical to a live replay
/// (`test/replay/ab_report_committed_equivalence_test.dart`), so a new
/// arm field would force a regeneration of every one of them for a
/// value none of their tables read.
///
/// Per capture: `scale`, `dx` / `dy` (the translation), `pairs`,
/// `residualPx`, `spanPx`, or `null` when the engine reported no estimate
/// (a session's first sighting, a rewrap that starved the fit). The
/// `summary` block carries the two numbers the zoom entry's tables read:
/// the largest `|scale - 1|` over the stream's captures and the residual
/// at that capture.
Map<String, Object?> transformReport(
  CaptureStream stream, {
  Viewport? viewport,
  BucketPolicy bucketPolicy = BucketPolicy.auto,
}) {
  final effective = viewport ?? stream.viewport;
  final r = replay(stream,
      model: PositionMergeModel.agreementWeighted,
      stepResponse: StepResponse.coherentShift,
      coherentShiftAdoptAgreeing: true,
      viewport: effective,
      useStreamViewport: false,
      bucketPolicy: bucketPolicy);
  final byCapture = <String, Object?>{};
  int? peakCapture;
  var peakDev = -1.0;
  final identityByCapture = <String, Object?>{};
  for (var i = 0; i < stream.batches.length; i++) {
    final cap = stream.batches[i].captureId;
    final e = r.transformEstimates[i];
    final t = r.identityTurnovers[i];
    identityByCapture['$cap'] = {'merged': t.merged, 'admitted': t.admitted};
    byCapture['$cap'] = e == null
        ? null
        : {
            'scale': e.scale,
            'dx': e.translation.dx,
            'dy': e.translation.dy,
            'pairs': e.pairCount,
            'rejected': e.rejectedPairs,
            'residualPx': e.residualPx,
            'spanPx': e.spanPx,
          };
    if (e != null && (e.scale - 1).abs() > peakDev) {
      peakDev = (e.scale - 1).abs();
      peakCapture = cap;
    }
  }
  final peak = peakCapture == null
      ? null
      : byCapture['$peakCapture'] as Map<String, Object?>;
  return {
    'mode': 'transform-report',
    'input': {
      'batches': stream.batches.length,
      'observations': stream.observationCount,
      'viewport': viewportJson(effective),
      'bucketPolicy': bucketPolicy.name,
      'bucketsApplied': bucketsJson(r),
    },
    'config': {
      'positionMergeModel': 'agreementWeighted',
      'stepResponse': 'coherentShift',
      'coherentShiftAdoptAgreeing': true,
    },
    'transformByCapture': byCapture,
    // 2.5.0's census per capture: how many fresh blocks merged (the pool
    // the fit draws from) vs were admitted as new identities.
    'identityByCapture': identityByCapture,
    'summary': {
      'estimatedCaptures': byCapture.values.where((v) => v != null).length,
      'peakScaleDeviationCapture': peakCapture,
      'peakScaleDeviation': peak == null ? null : peakDev,
      'peakScale': peak?['scale'],
      'residualAtPeakPx': peak?['residualPx'],
      'pairsAtPeak': peak?['pairs'],
    },
  };
}
