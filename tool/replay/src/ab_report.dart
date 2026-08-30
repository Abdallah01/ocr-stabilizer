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
/// [coherentShiftFloorPx] (#119): when set, adds a fifth arm,
/// `agreementCoherentFloor` — `StepResponse.coherentShift` with the
/// absolute-pixel floor enabled at this many pixels. `null` (the default)
/// omits the arm entirely, so every committed `.ab.json` and every
/// existing arm is unaffected by this parameter's mere existence.
///
/// [coherentShiftReanchorMinBlocks] (#119): same contract, adding the arm
/// `agreementCoherentReanchor` — `StepResponse.coherentShift` with the
/// batch-level re-anchor enabled at this cluster size.
///
/// [coherentShiftAdoptAgreeing] (#119 item 2): same contract, adding the
/// arm `agreementCoherentAdopt` — `StepResponse.coherentShift` with the
/// agreeing under-gate pairs adopted into a decided shift. `false` (the
/// default) omits the arm.
Map<String, Object?> abReport(
  CaptureStream stream, {
  Viewport? viewport,
  BucketPolicy bucketPolicy = BucketPolicy.auto,
  double? coherentShiftFloorPx,
  int? coherentShiftReanchorMinBlocks,
  bool coherentShiftAdoptAgreeing = false,
}) {
  final effective = viewport ?? stream.viewport;
  final legacy = replay(stream,
      model: PositionMergeModel.legacy,
      viewport: effective,
      useStreamViewport: false,
      bucketPolicy: bucketPolicy);
  final agreement = replay(stream,
      model: PositionMergeModel.agreementWeighted,
      // Explicit, not relied-on-default (2.3.0): `StabilizationEngine`'s
      // own default flipped to `StepResponse.coherentShift` in 2.3.0 (the
      // #116 A/B); `replay()`'s own default stays pinned to `damp` (same
      // precedent as `model`'s default staying `legacy` above regardless
      // of the engine's `agreementWeighted` default), but this arm names
      // its baseline outright so report semantics can never drift silently
      // if either default changes again.
      stepResponse: StepResponse.damp,
      viewport: effective,
      useStreamViewport: false,
      bucketPolicy: bucketPolicy);
  // #116 candidate arms: the same agreement-weighted model, with each of
  // the two opt-in StepResponse alternatives to damp (the arm above).
  final agreementSnap = replay(stream,
      model: PositionMergeModel.agreementWeighted,
      stepResponse: StepResponse.snap,
      viewport: effective,
      useStreamViewport: false,
      bucketPolicy: bucketPolicy);
  final agreementCoherent = replay(stream,
      model: PositionMergeModel.agreementWeighted,
      stepResponse: StepResponse.coherentShift,
      viewport: effective,
      useStreamViewport: false,
      bucketPolicy: bucketPolicy);
  // #119: the absolute-pixel floor arm, only computed when a floor is
  // passed (see this function's doc).
  final agreementCoherentFloor = coherentShiftFloorPx == null
      ? null
      : replay(stream,
          model: PositionMergeModel.agreementWeighted,
          stepResponse: StepResponse.coherentShift,
          coherentShiftFloorPx: coherentShiftFloorPx,
          viewport: effective,
          useStreamViewport: false,
          bucketPolicy: bucketPolicy);
  // #119: the batch-level re-anchor arm, only computed when a cluster
  // size is passed (see this function's doc).
  final agreementCoherentReanchor = coherentShiftReanchorMinBlocks == null
      ? null
      : replay(stream,
          model: PositionMergeModel.agreementWeighted,
          stepResponse: StepResponse.coherentShift,
          coherentShiftReanchorMinBlocks: coherentShiftReanchorMinBlocks,
          viewport: effective,
          useStreamViewport: false,
          bucketPolicy: bucketPolicy);
  // #119 item 2: the adopt-agreeing arm, only computed when asked for.
  final agreementCoherentAdopt = !coherentShiftAdoptAgreeing
      ? null
      : replay(stream,
          model: PositionMergeModel.agreementWeighted,
          stepResponse: StepResponse.coherentShift,
          coherentShiftAdoptAgreeing: true,
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
        'agreementSnap': bucketsJson(agreementSnap),
        'agreementCoherent': bucketsJson(agreementCoherent),
        if (agreementCoherentFloor != null)
          'agreementCoherentFloor': bucketsJson(agreementCoherentFloor),
        if (agreementCoherentReanchor != null)
          'agreementCoherentReanchor': bucketsJson(agreementCoherentReanchor),
        if (agreementCoherentAdopt != null)
          'agreementCoherentAdopt': bucketsJson(agreementCoherentAdopt),
      },
      if (agreementCoherentFloor != null)
        'coherentShiftFloorPx': coherentShiftFloorPx,
      if (agreementCoherentReanchor != null)
        'coherentShiftReanchorMinBlocks': coherentShiftReanchorMinBlocks,
      if (agreementCoherentAdopt != null) 'coherentShiftAdoptAgreeing': true,
    },
    'legacy': _arm(legacy, stream),
    'agreementWeighted': _arm(agreement, stream),
    'agreementSnap': _arm(agreementSnap, stream),
    'agreementCoherent': _arm(agreementCoherent, stream),
    if (agreementCoherentFloor != null)
      'agreementCoherentFloor': _arm(agreementCoherentFloor, stream),
    if (agreementCoherentReanchor != null)
      'agreementCoherentReanchor': _arm(agreementCoherentReanchor, stream),
    if (agreementCoherentAdopt != null)
      'agreementCoherentAdopt': _arm(agreementCoherentAdopt, stream),
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

Map<String, Object?> _arm(ReplayResult r, CaptureStream stream) {
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
    // #116: how far a tracked position still lags where OCR actually saw
    // the block, per capture — the issue's lag table is exactly this
    // quantity averaged over the retained shifted lines of one capture.
    // Non-nested merges only (see MergeSample.topLagAfterPx).
    'meanTopLagByCapture': _meanTopLagByCapture(positional, stream),
    // #116: how many merges in each capture received a StepResponse
    // (always 0 under `damp` — no merge ever sets the flag).
    'stepEventsByCapture': _stepEventsByCapture(r.merges, stream),
    // Identity retention per capture: every merge (nested-fragment
    // confirmations INCLUDED — the fragment found its block, which is the
    // identity question, not a position question; see
    // dynamic_reflow_corpus_test.dart's "unit of identity" group) over
    // that capture's raw observed block count.
    'identityByCapture': _identityByCapture(r.merges, stream),
  };
}

/// Every capture id `stream` recorded, in file order — the master key set
/// the three per-capture maps below iterate, so a capture with zero
/// matching merges gets an explicit (meaningful) entry instead of a
/// silent gap a reader could mistake for "no data collected."
Iterable<int> _captureIds(CaptureStream stream) =>
    stream.batches.map((b) => b.captureId);

/// Mean [MergeSample.topLagAfterPx] per capture, over [merges] (callers
/// pass the nested-fragment-excluded list already — see [_arm]). Null for
/// a capture with no non-nested merges — there is nothing to average.
Map<String, Object?> _meanTopLagByCapture(
    List<MergeSample> merges, CaptureStream stream) {
  final byCapture = <int, List<double>>{};
  for (final m in merges) {
    byCapture.putIfAbsent(m.captureId, () => []).add(m.topLagAfterPx);
  }
  return {
    for (final cap in _captureIds(stream))
      '$cap': switch (byCapture[cap]) {
        null => null,
        final xs => _round3(xs.reduce((a, b) => a + b) / xs.length),
      },
  };
}

/// Count of merges with a non-null [MergeSample.stepResponseApplied], per
/// capture — 0 (not a gap) for a capture with none. Includes
/// nested-fragment and frozen merges in the scan (a step response can
/// never apply to either — see `StabilizationEngine._mergeImpl` — so they
/// never contribute a count, but excluding them explicitly would just be
/// a no-op filter).
Map<String, Object?> _stepEventsByCapture(
    List<MergeSample> merges, CaptureStream stream) {
  final byCapture = <int, int>{};
  for (final m in merges) {
    if (m.stepResponseApplied == null) continue;
    byCapture[m.captureId] = (byCapture[m.captureId] ?? 0) + 1;
  }
  return {for (final cap in _captureIds(stream)) '$cap': byCapture[cap] ?? 0};
}

/// Identity retention per capture: merges (all kinds) / that capture's raw
/// observed block count (`ObsBatch.blocks.length` — before dedup, matching
/// `dynamic_reflow_corpus_test.dart`'s retention computation). 0.0 (not a
/// gap) for a capture with zero merges; null only when the capture itself
/// carried zero observed blocks (via `share`'s zero-denominator contract).
Map<String, Object?> _identityByCapture(
    List<MergeSample> merges, CaptureStream stream) {
  final observedByCapture = {
    for (final b in stream.batches) b.captureId: b.blocks.length,
  };
  final mergesByCapture = <int, int>{};
  for (final m in merges) {
    mergesByCapture[m.captureId] = (mergesByCapture[m.captureId] ?? 0) + 1;
  }
  return {
    for (final cap in _captureIds(stream))
      '$cap': share(mergesByCapture[cap] ?? 0, observedByCapture[cap] ?? 0),
  };
}

Object? _round3(double v) => v.isNaN ? null : (v * 1000).round() / 1000;

String _bucket(int obsN) {
  if (obsN <= 2) return 'n1-2';
  if (obsN <= 5) return 'n3-5';
  if (obsN <= 10) return 'n6-10';
  return 'n11+';
}
