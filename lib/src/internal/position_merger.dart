// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// Position merging (the weighted lerp, the step response and the merged
// position confidence), extracted from `StabilizationEngine._mergeImpl`
// in #150 with no behaviour change (differential harness byte-identical).
// Pure: reads the two blocks, the drift-corrected fresh rect and the
// decided coherent-shift translation; never touches the drift tracker.
// The engine keeps the merge's ORDER of operations exactly as before —
// [PositionMerger.resolve] at step 3, [PositionMerger.mergedConfidence]
// after the votes — so even the order of two validation throws is
// unchanged.

import 'dart:math' show max, min;

import '../observation.dart';
import '../stabilization_engine.dart' show PositionMergeModel;
import '../step_response.dart';
import '../track.dart';
import '../types/geometry.dart' show Offset, Rect;
import 'block_geometry.dart';

/// The position half of one merge: the merged rect, the baseline the
/// residual is measured from, the residual override a snap sets, and
/// which step response (if any) applied.
typedef PositionResolution = ({
  Rect mergedRect,
  Rect baselineRect,
  double? residualOverride,
  StepResponse? stepResponseApplied,
});

/// Merges an existing block's position with a fresh drift-corrected
/// observation under one [PositionMergeModel] and one [StepResponse].
class PositionMerger<T extends Track<Object?>> {
  /// Creates a merger. Config invariants (`snapThresholdMultiplier` finite
  /// and > 0) are validated by the engine at construction.
  const PositionMerger({
    required this.model,
    required this.stepResponse,
    required this.snapThresholdMultiplier,
  });

  /// The position model (`StabilizerConfig.merge.positionModel`).
  final PositionMergeModel model;

  /// The step response (`StabilizerConfig.stepResponse.mode`).
  final StepResponse stepResponse;

  /// [StepResponse.snap]'s threshold as a multiple of the block's
  /// [agreementScale].
  final double snapThresholdMultiplier;

  /// Lerp weight toward the fresh (drift-corrected) observation.
  double mergeWeight(T fresh, T existing) {
    final freshConf = fresh.positionConfidence.raw;
    final existingConf = existing.positionConfidence.raw;
    switch (model) {
      case PositionMergeModel.legacy:
        // 0.x behavior: confidence ratio only. Locks near
        // fresh/(1+fresh) once existing confidence saturates, so even a
        // 100-times-observed block moves ~33% toward every noisy rect.
        final totalConf = existingConf + freshConf;
        return totalConf > 0 ? freshConf / totalConf : 0.5;
      case PositionMergeModel.agreementWeighted:
        // Existing confidence is anchored by its observation count —
        // a 1/n-style decay, so long-observed blocks become
        // positionally sticky while a twice-seen block still adapts.
        // The count is clamped to >= 1: a consumer block with a zero or
        // negative count (invalid, but reachable via the public index
        // seam) must not drive the weight past 1.0 and extrapolate the
        // lerp (PR #65 review).
        final anchored = existingConf * max(1, existing.observationCount);
        final total = anchored + freshConf;
        return total > 0 ? freshConf / total : 0.5;
    }
  }

  /// Whether a step response may apply to this pair at all (#116 finding
  /// D): ordinary matches only — never a band admission — under the
  /// agreement-weighted model (legacy has no residual/scale concept to
  /// gate either option on), and never for viewport-relative or
  /// carousel-child blocks, mirroring the coherent-shift detector's own
  /// eligible-pairs filter exactly.
  bool stepResponseEligible(T fresh, T existing,
          {required bool wasBandFallback}) =>
      !wasBandFallback &&
      model == PositionMergeModel.agreementWeighted &&
      !fresh.isViewportRelative &&
      !fresh.isHorizontalScrollChild &&
      !existing.isHorizontalScrollChild;

  /// Step 3 of a merge: resolve the effective baseline and weight (the
  /// step response, #116) and lerp toward [correctedRect].
  ///
  /// [coherentShiftTranslation] — non-null only when [stepResponse] is
  /// [StepResponse.coherentShift] and [existing] is a member of this
  /// batch's qualifying shift group: the baseline becomes `existing`'s
  /// rect translated by it. [StepResponse.snap] instead re-anchors fully
  /// (weight 1, residual 0) when the residual exceeds
  /// `snapThresholdMultiplier x agreementScale(existing)`.
  PositionResolution resolve({
    required T fresh,
    required T existing,
    required Rect correctedRect,
    required bool wasBandFallback,
    Offset? coherentShiftTranslation,
  }) {
    var baselineRect = existing.absoluteRect.raw;
    var w = mergeWeight(fresh, existing);
    double? residualOverride;
    StepResponse? applied;
    final eligible =
        stepResponseEligible(fresh, existing, wasBandFallback: wasBandFallback);

    if (eligible && stepResponse == StepResponse.snap) {
      final residual = (correctedRect.topLeft - baselineRect.topLeft).distance;
      final scale = agreementScale(existing);
      if (residual > snapThresholdMultiplier * scale) {
        w = 1.0;
        residualOverride = 0.0;
        applied = StepResponse.snap;
      }
    } else if (eligible &&
        stepResponse == StepResponse.coherentShift &&
        coherentShiftTranslation != null) {
      baselineRect = baselineRect.translate(
        coherentShiftTranslation.dx,
        coherentShiftTranslation.dy,
      );
      applied = StepResponse.coherentShift;
    }

    return (
      mergedRect: Rect.lerp(baselineRect, correctedRect, w)!,
      baselineRect: baselineRect,
      residualOverride: residualOverride,
      stepResponseApplied: applied,
    );
  }

  /// Merged position confidence for [model].
  ///
  /// [baselineRect] is the position the residual is measured FROM —
  /// defaults to `existing.absoluteRect.raw`. [StepResponse.coherentShift]
  /// passes the existing rect already translated by the batch shift, so
  /// the residual reflects how well this pair agreed with the GROUP's
  /// shift rather than with the untranslated tracked position.
  /// [residualOverride], when non-null, is used in place of the computed
  /// residual outright — [StepResponse.snap] passes `0.0`: a full
  /// re-anchor is agreement with the new position, not disagreement with
  /// the old one.
  double mergedConfidence(
    T fresh,
    T existing,
    Rect correctedRect, {
    Rect? baselineRect,
    double? residualOverride,
  }) {
    switch (model) {
      case PositionMergeModel.legacy:
        // 0.x behavior: additive with clamp — saturates to 1.0 after two
        // ~0.5-confidence observations regardless of agreement (#58).
        final totalConf =
            existing.positionConfidence.raw + fresh.positionConfidence.raw;
        return min(totalConf, 1.0);
      case PositionMergeModel.agreementWeighted:
        // Confidence is a running mean of positional AGREEMENT: how
        // close the corrected fresh observation landed to the tracked
        // position, scaled by the block's OWN jitter allowance
        // ([kAgreementJitterAllowance] x the existing block's height,
        // #75). Disagreeing observations REDUCE confidence instead of
        // saturating it. Why the block's own height and not a region
        // median: doc/decisions/agreement-jitter-allowance.md.
        final residual = residualOverride ??
            (correctedRect.topLeft -
                    (baselineRect ?? existing.absoluteRect.raw).topLeft)
                .distance;
        final scale = agreementScale(existing);
        final agreement =
            scale > 0 ? (1.0 - residual / scale).clamp(0.0, 1.0) : 0.0;
        // Clamped for the same reason as the merge weight: n <= -1
        // would zero or invert the running-mean denominator
        // (PR #65 review).
        final n = max(1, existing.observationCount);
        return ((existing.positionConfidence.raw * n) + agreement) / (n + 1);
    }
  }
}
