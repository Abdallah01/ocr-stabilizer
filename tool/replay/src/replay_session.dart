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
  });

  final int captureId;

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
  });

  final int batches;
  final int observations;
  final List<MergeSample> merges;
  final List<ProvisionalOutcome> chains;
  final BandFallbackStats stats;

  Iterable<MergeSample> get freezes => merges.where((m) => m.wasFrozen);
  Iterable<MergeSample> get admissions => merges.where((m) => m.wasAdmission);
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
/// - bucket adaptation beyond the viewport formula: the reference
///   consumer switches to 2× the median block height once it has enough
///   blocks; the rig uses the viewport formula only;
/// - `contextualCheck` (group-signature invalidation): the schema carries
///   no group signatures;
/// - a consumer-supplied `DriftTracker` / `SubmapMembership`: defaults
///   are used;
/// - the position-merge model defaults to `legacy` here so the A/B arms
///   can be named explicitly; `freeze-report` inherits that default and
///   records it (its outputs are model-neutral: counts and text fields,
///   no positions).
ReplayResult replay(
  CaptureStream stream, {
  BandFallbackConfig band = const BandFallbackConfig(),
  PositionMergeModel model = PositionMergeModel.legacy,
  Viewport? viewport,
  bool useStreamViewport = true,
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

  for (final batch in stream.batches) {
    currentCapture = batch.captureId;
    engine.stabilize(batch.blocks);
  }

  return ReplayResult(
    batches: stream.batches.length,
    observations: stream.observationCount,
    merges: merges,
    chains: chains,
    stats: engine.bandStats,
  );
}
