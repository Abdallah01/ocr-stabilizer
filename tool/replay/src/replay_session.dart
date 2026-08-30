// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:math' as math;

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

import 'capture_stream.dart';

typedef ReplayBlock = DefaultTrackedBlock<Object>;

/// JSON form of a viewport for report `input` blocks; null stays null so
/// a report on default buckets says so.
Map<String, double>? viewportJson(Viewport? v) =>
    v == null ? null : {'width': v.width, 'height': v.height};

/// How the rig sizes the engine's spatial-index buckets after the
/// viewport formula (2.2.0, #113).
enum BucketPolicy {
  /// The stream's own `meta.bk` when present, applied before the first
  /// batch it precedes and again wherever it changes — the buckets the
  /// producer actually used. A stream without `bk` stays on the viewport
  /// formula, and the report says so (`bucketPolicy: viewportFormula`).
  auto,

  /// The viewport formula only (`updateViewport`), as rig 2.1.0 did;
  /// ignores `bk`. For comparing against the 2.1.0 committed numbers.
  viewportFormula,

  /// Emulate the reference consumer's adaptive rule from the stream
  /// alone: before each capture, once the tracked state holds at least
  /// [kMedianWarmUpBlocks] blocks, both bucket sides become
  /// `clamp(2 × median tracked-block height, 80, 220)`; the viewport
  /// formula until then. The consumer takes its median over its whole
  /// cache (many captures deep); the rig's nearest population is the
  /// engine's tracked state, so this is an emulation, not a replay of
  /// recorded buckets — prefer [auto] on a stream that carries `bk`.
  medianHeight,
}

/// Warm-up for [BucketPolicy.medianHeight]: the reference consumer needs
/// this many cached blocks before it trusts a median.
const int kMedianWarmUpBlocks = 4;

/// [BucketPolicy.medianHeight] for one capture: null before warm-up.
/// Median = the upper-middle element of the sorted heights (the
/// consumer's `heights[n ~/ 2]`), doubled, clamped to the consumer's
/// 80–220 px range.
Buckets? medianHeightBuckets(Iterable<TrackedBlock> tracked) {
  final heights = [for (final b in tracked) b.absoluteRect.raw.height]
    ..sort();
  if (heights.length < kMedianWarmUpBlocks) return null;
  final size = (heights[heights.length ~/ 2] * 2).clamp(80.0, 220.0);
  return (width: size, height: size);
}

/// Applies a [BucketPolicy] to an engine capture by capture (2.2.0, #113).
///
/// Shared by [replay] and `tool/replay/dump_frames.dart` so the frame
/// dump runs on exactly the geometry the reports run on (PR #114 review:
/// the dump used to carry its own copy of this loop, untested). [applied]
/// lists every distinct size in the order it was applied; [policyUsed]
/// names the source of the last applied size (`viewportFormula` until a
/// size is applied, then `stream` or `medianHeight`).
class BucketPolicyApplier {
  BucketPolicyApplier(this.engine, this.policy);

  final StabilizationEngine<ReplayBlock, Object> engine;
  final BucketPolicy policy;
  final List<Buckets> applied = [];
  String policyUsed = 'viewportFormula';
  Buckets? _current;

  /// Apply the policy's size for [batch] — call before `stabilize`.
  void beforeBatch(ObsBatch batch) {
    switch (policy) {
      case BucketPolicy.auto:
        final bk = batch.buckets;
        if (bk != null) _apply(bk, 'stream');
      case BucketPolicy.medianHeight:
        final m = medianHeightBuckets(engine.spatialIndex.allBlocks);
        if (m != null) _apply(m, 'medianHeight');
      case BucketPolicy.viewportFormula:
        break;
    }
  }

  void _apply(Buckets b, String source) {
    if (b == _current) return;
    engine.updateBucketSizes(bucketWidth: b.width, bucketHeight: b.height);
    _current = b;
    applied.add(b);
    policyUsed = source;
  }
}

/// One merge observed during replay (recorded inside the merger callback,
/// i.e. exactly what the engine computed).
class MergeSample {
  MergeSample({
    required this.captureId,
    required this.obsNBefore,
    required this.displacement,
    required this.pconfAfter,
    required this.wasFrozen,
    required this.wasAdmission,
    required this.freshTconf,
    required this.textDiffers,
    required this.remainingAfter,
    this.nestedFragment = false,
    this.topLagAfterPx = 0,
    this.stepResponseApplied,
  });

  final int captureId;

  /// The engine reported this merge as a nested-fragment confirmation
  /// (2.2.0, #112): existing geometry kept, count incremented. Zero
  /// displacement by construction — reports keep these out of the
  /// position statistics.
  final bool nestedFragment;

  /// Existing block's observation count at merge time.
  final int obsNBefore;

  /// |merged center − existing center| in absolute px.
  final double displacement;

  final double pconfAfter;

  /// Existing block was provisional → the engine froze this merge.
  final bool wasFrozen;

  /// Non-provisional existing, provisional merged → band admission.
  final bool wasAdmission;

  final double freshTconf;

  /// Fresh original text differed from the held text (the evidence a
  /// frozen merge discards — #57 item 2).
  final bool textDiffers;

  final int remainingAfter;

  /// |fresh.absoluteRect.raw.top − merged.absoluteRect.raw.top| in
  /// absolute px (#116): how far the tracked position still is from where
  /// OCR actually saw the block, AFTER this merge — the per-merge lag.
  /// The issue's lag table (#116) is exactly this quantity averaged over
  /// the retained shifted lines of one capture (see `ab_report.dart`'s
  /// `meanTopLagByCapture`, which averages it over non-nested merges — a
  /// nested-fragment confirmation's `fresh` is a sub-box positioned
  /// inside the (unmoved) host, so its raw top-vs-top difference is not a
  /// tracking lag and would just add noise to the mean).
  final double topLagAfterPx;

  /// Which `StepResponse`, if any, the engine applied to this merge —
  /// read straight off `MergeResult.stepResponseApplied`. Null under the
  /// default `StepResponse.damp`, under `PositionMergeModel.legacy`
  /// (documented no-op), or when a merge was eligible but a residual/
  /// group never actually qualified.
  final StepResponse? stepResponseApplied;
}

/// A provisional chain followed across merges (admission → promotion, or
/// left unresolved when the block stops being re-observed).
class ProvisionalOutcome {
  ProvisionalOutcome({required this.admittedAtCapture});

  final int admittedAtCapture;
  int? promotedAtCapture;
  int freezes = 0;

  bool get promoted => promotedAtCapture != null;
  int? get latencyCaptures =>
      promoted ? promotedAtCapture! - admittedAtCapture : null;
}

/// Result of replaying an observation stream through `stabilize()`.
class ReplayResult {
  ReplayResult({
    required this.batches,
    required this.observations,
    required this.merges,
    required this.chains,
    required this.stats,
    this.bucketPolicy = 'viewportFormula',
    this.bucketsApplied = const [],
  });

  final int batches;
  final int observations;
  final List<MergeSample> merges;
  final List<ProvisionalOutcome> chains;
  final BandFallbackStats stats;

  /// The bucket policy that actually took effect (2.2.0, #113):
  /// `viewportFormula` when nothing beyond the viewport formula was
  /// applied (no `bk` in the stream under [BucketPolicy.auto], or the
  /// median never warmed up), else `stream` or `medianHeight`.
  final String bucketPolicy;

  /// Every distinct bucket size applied after the viewport formula, in
  /// order. Empty when the viewport formula was all that ran.
  final List<Buckets> bucketsApplied;

  Iterable<MergeSample> get freezes => merges.where((m) => m.wasFrozen);
  Iterable<MergeSample> get admissions => merges.where((m) => m.wasAdmission);
}

/// JSON for a report's `input.bucketsApplied` (or per-arm) block.
Map<String, Object?> bucketsJson(ReplayResult r) => {
      'policy': r.bucketPolicy,
      'sizes': [
        for (final b in r.bucketsApplied) {'width': b.width, 'height': b.height},
      ],
    };

/// Parse a `--buckets=auto|formula|median` argument; null when malformed.
BucketPolicy? bucketPolicyFromArg(String arg) {
  if (!arg.startsWith('--buckets=')) return null;
  return switch (arg.substring('--buckets='.length)) {
    'auto' => BucketPolicy.auto,
    'formula' => BucketPolicy.viewportFormula,
    'median' => BucketPolicy.medianHeight,
    _ => null,
  };
}

/// Feed every `obs` batch, in order, through a fresh engine configured with
/// [band] and [model]; collect per-merge samples and provisional-chain
/// outcomes via the merger callback (the engine's own computation, not a
/// reimplementation).
///
/// Viewport (2.1.0): a consumer sizes the spatial index's buckets from its
/// viewport — via `engine.updateViewport`, or via
/// `SpatialBlockIndex.updateBucketSizes` on an index it injects (the
/// reference consumer does the latter). The rig must apply the same
/// viewport or it replays on the 200 px default buckets — not production
/// geometry. [viewport] overrides; otherwise the stream's `meta.vp` is
/// used when [useStreamViewport] is true (the default). With neither, the
/// engine keeps its defaults (callers that report numbers should warn —
/// see replay.dart).
///
/// What the rig does NOT model (PR #111 review, rig-fidelity charge —
/// each one is a consumer configuration the capture schema cannot carry
/// or that the reference consumer performs outside the engine):
/// - the consumer's own matching stage: the reference consumer calls
///   `engine.merge` from its own dedup cascade and never `stabilize()`,
///   so `stabilize()`-only behaviour (retention, supersession) is not on
///   its path at all;
/// - bucket adaptation beyond the viewport formula is modelled since
///   2.2.0 (#113) — [BucketPolicy.auto] applies the stream's recorded
///   `meta.bk`, [BucketPolicy.medianHeight] emulates the reference
///   consumer's 2× median rule from the tracked state — but the
///   emulation's population (the engine's tracked state) is not the
///   consumer's whole cache, and a stream without `bk` still replays on
///   the viewport formula;
/// - `contextualCheck` (group-signature invalidation): the schema carries
///   no group signatures;
/// - a consumer-supplied `DriftTracker` / `SubmapMembership`: defaults
///   are used;
/// - the position-merge model defaults to `legacy` here so the A/B arms
///   can be named explicitly; `freeze-report` inherits that default and
///   records it (its outputs are model-neutral: counts and text fields,
///   no positions).
/// - [stepResponse] (#116) defaults to `StepResponse.damp` here — same
///   precedent as [model] above: the replay rig's own default stays
///   pinned so every A/B arm can be named explicitly and this tool's
///   baseline numerics do not silently move when `StabilizationEngine`'s
///   OWN default changes (it flipped to `StepResponse.coherentShift` in
///   2.3.0 — the #116 A/B winner; this parameter did not follow it).
///   `ab_report.dart`'s `agreementWeighted` arm now passes `damp`
///   explicitly for the same reason; its `agreementSnap` and
///   `agreementCoherent` arms are the ones that pass `snap` /
///   `coherentShift`.
/// - [coherentShiftFloorPx] (#119) defaults to `null` (off) here, same
///   precedent as [stepResponse] above — `ab_report.dart` threads a
///   non-null value only into its optional `agreementCoherentFloor` arm,
///   so every existing arm's numerics are unaffected by this parameter's
///   mere existence.
ReplayResult replay(
  CaptureStream stream, {
  BandFallbackConfig band = const BandFallbackConfig(),
  PositionMergeModel model = PositionMergeModel.legacy,
  StepResponse stepResponse = StepResponse.damp,
  double? coherentShiftFloorPx,
  Viewport? viewport,
  bool useStreamViewport = true,
  BucketPolicy bucketPolicy = BucketPolicy.auto,
}) {
  final effectiveViewport =
      viewport ?? (useStreamViewport ? stream.viewport : null);
  final merges = <MergeSample>[];
  final chains = <ProvisionalOutcome>[];
  // Latest merged instance of each open chain → its outcome record.
  // Identity works because the engine threads the merged instance back as
  // `existing` on the next match.
  final openChains = Map<ReplayBlock, ProvisionalOutcome>.identity();
  var currentCapture = -1;

  late final StabilizationEngine<ReplayBlock, Object> engine;
  engine = StabilizationEngine<ReplayBlock, Object>(
    bandFallback: band,
    positionMergeModel: model,
    stepResponse: stepResponse,
    coherentShiftFloorPx: coherentShiftFloorPx,
    merger: (existing, fresh, m) {
      final merged = existing.applyMerge(m);
      final e = existing.absoluteRect.raw.center;
      final g = merged.absoluteRect.raw.center;
      final dx = g.dx - e.dx;
      final dy = g.dy - e.dy;
      final wasFrozen = existing.isProvisional;
      final wasAdmission = !existing.isProvisional && m.isProvisional;
      merges.add(MergeSample(
        captureId: currentCapture,
        obsNBefore: existing.observationCount,
        displacement: math.sqrt(dx * dx + dy * dy),
        pconfAfter: m.positionConfidence.raw,
        wasFrozen: wasFrozen,
        wasAdmission: wasAdmission,
        freshTconf: fresh.textConfidence.raw,
        textDiffers: fresh.originalText != existing.originalText,
        remainingAfter: m.provisionalCapturesRemaining,
        nestedFragment: m.isNestedFragment,
        topLagAfterPx:
            (fresh.absoluteRect.raw.top - merged.absoluteRect.raw.top).abs(),
        stepResponseApplied: m.stepResponseApplied,
      ));

      if (wasAdmission) {
        final chain = ProvisionalOutcome(admittedAtCapture: currentCapture);
        chains.add(chain);
        openChains[merged] = chain;
      } else if (wasFrozen) {
        final chain = openChains.remove(existing);
        if (chain != null) {
          chain.freezes++;
          if (!m.isProvisional) {
            chain.promotedAtCapture = currentCapture; // window expired
          } else {
            openChains[merged] = chain;
          }
        }
      }
      return merged;
    },
  );

  if (effectiveViewport != null) {
    engine.updateViewport(
      viewportWidth: effectiveViewport.width,
      viewportHeight: effectiveViewport.height,
    );
  }

  // Bucket policy (2.2.0, #113): the viewport formula above is the floor;
  // `auto` applies the stream's own `bk` exactly where the producer
  // applied it, `medianHeight` re-derives the reference consumer's rule
  // from the tracked state before each capture. One applier class serves
  // this loop and dump_frames.dart, so the dump's geometry is the replay's.
  final buckets = BucketPolicyApplier(engine, bucketPolicy);

  for (final batch in stream.batches) {
    currentCapture = batch.captureId;
    buckets.beforeBatch(batch);
    engine.stabilize(batch.blocks);
  }

  return ReplayResult(
    batches: stream.batches.length,
    observations: stream.observationCount,
    merges: merges,
    chains: chains,
    stats: engine.bandStats,
    bucketPolicy: buckets.policyUsed,
    bucketsApplied: buckets.applied,
  );
}
