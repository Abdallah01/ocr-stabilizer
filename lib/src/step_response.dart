// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

/// How `StabilizationEngine` reacts to a residual that is far outside a
/// tracked block's normal jitter allowance (#116).
///
/// The agreement-weighted position model (`PositionMergeModel
/// .agreementWeighted`) was calibrated to damp ML-Kit-shaped OCR jitter —
/// every residual, however large, is treated as noise and lerped toward
/// gradually. That is right for jitter but wrong for a genuine layout
/// step: an ad or image finishing load pushes every line below it down by
/// a fixed offset in one frame, and the damped model then draws tracked
/// boxes 130-275px above the real text for several seconds (#116).
/// [StepResponse] adds two opt-in alternatives, selected via
/// `StabilizationEngine(stepResponse: ...)`. The default, [damp],
/// preserves the existing behaviour exactly.
///
/// Both non-default values are scoped to
/// `PositionMergeModel.agreementWeighted` — [legacy]'s merge math has no
/// residual/scale concept to gate a step response on, so both are a
/// documented no-op under it (`_mergedPositionConfidence` never computes a
/// residual in the legacy branch). Neither value is ever applied to a
/// provisional (frozen), nested-fragment, or band-fallback-admission
/// merge: those are resolved before step-response logic runs at all (the
/// freeze and nested-fragment paths return early in `_mergeImpl`, and a
/// band admission is explicitly excluded — see `MergeResult
/// .stepResponseApplied`).
enum StepResponse {
  /// Today's behaviour: every residual is damped by the ordinary weighted
  /// merge, however large. The default.
  damp,

  /// Per-block re-anchor: when a merge's residual (the distance between
  /// the drift-corrected fresh observation and the tracked position)
  /// exceeds `StabilizationEngine.snapThresholdMultiplier` times the
  /// block's own agreement scale (3x its own height), the merge weight is
  /// forced to 1.0 — the merged rect becomes the corrected observation
  /// outright — and the merged confidence is computed as if the residual
  /// were 0 (a full re-anchor is treated as agreement, not disagreement,
  /// with the new position).
  snap,

  /// Per-batch translation vote: `StabilizationEngine.stabilize` looks for
  /// a group of matched pairs, within the same capture, whose
  /// drift-corrected displacement agrees (within
  /// `StabilizationEngine.coherentShiftTolerance` times block height) on
  /// (approximately) the same vector. When the group clears both
  /// `StabilizationEngine.coherentShiftMinBlocks` and
  /// `StabilizationEngine.coherentShiftMinShare`, its median displacement
  /// becomes a batch shift `T`: every group member's merge first
  /// translates its existing (tracked) rect by `T`, then runs the normal
  /// weighted merge and confidence computation against that shifted
  /// baseline — so a member's residual against the shift is small and its
  /// confidence stays high, while non-member pairs in the same batch merge
  /// exactly as [damp]. When no group qualifies, the whole batch is
  /// bit-identical to [damp].
  coherentShift,
}
