// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'types/geometry.dart' show Offset;

import 'internal/confidence_validation.dart';
import 'step_response.dart';
import 'text_vote.dart';
import 'types/absolute_rect.dart';
import 'types/confidence_types.dart';

/// Exhaustive delta from a SAR merge. Every field is engine-computed.
///
/// The consumer receives this via [BlockMerger] and uses it to construct
/// an updated block instance (e.g. via `copyWith`). No fields are
/// pass-through — the engine owns the computation of every value. On a
/// nested confirmation (2.2.0, [isNestedFragment]) that computation is
/// "keep the host's value" for every field except [observationCount] and
/// [sourceQuality]: the fragment casts no vote and pulls no position.
class MergeResult {
  // ── Position (engine computes weighted average) ──

  /// Merged bounding rect (weighted average of fresh + existing).
  final AbsoluteRect mergedRect;

  /// Updated position confidence after merge.
  final PositionConfidence positionConfidence;

  /// Drift correction applied to the fresh observation.
  final Offset driftCorrection;

  // ── Text voting (engine computes winner) ──

  /// Winning original (untranslated) text from the vote.
  final String winningOriginalText;

  /// Updated text confidence after merge.
  final TextConfidence textConfidence;

  /// Updated map of text variants and their accumulated votes.
  final Map<String, TextVote> updatedTextVotes;

  /// Whether the winning text changed (caller should invalidate translation).
  final bool textWasPromoted;

  // ── Classification voting (engine computes majority) ──

  /// Updated classification vote tallies (hierarchy weight → count).
  final Map<int, int> updatedClassificationVotes;

  /// Whether the majority class changed (caller should reclassify).
  final bool needsReclassification;

  // ── Carousel identity voting (engine prevents flip-flop) ──

  /// Updated carousel-index vote tallies (carousel id → count).
  final Map<int, int> updatedCarouselIdVotes;

  // ── Observation state (engine increments) ──

  /// Total observation count after this merge.
  ///
  /// Normally `existing.observationCount + 1`. Exception: while a
  /// band-admitted block is inside its provisional freeze window, the
  /// engine passes the existing count through unchanged — frozen
  /// captures do not accrue observation evidence.
  final int observationCount;

  /// Whether the merged block remains provisional (not yet promoted).
  final bool isProvisional;

  /// Captures left before the provisional block is promoted or evicted.
  final int provisionalCapturesRemaining;

  // ── Source quality (engine picks higher tier) ──

  /// Best source-quality tier observed (engine picks max of fresh/existing).
  final int sourceQuality;

  // ── Merge kind (2.2.0, #112) ──

  /// True when this merge is a NESTED-FRAGMENT confirmation: the fresh
  /// block was one line of the existing block reported on its own (an
  /// engine's grouping flipped between frames). The engine then keeps the
  /// existing geometry, text and votes and only increments
  /// [observationCount] — [mergedRect] equals the existing rect,
  /// [textWasPromoted] is false, [driftCorrection] is zero. Consumers
  /// and measurement tools can tell such a confirmation from a position
  /// merge (a jittered observation of the same box) without comparing
  /// rects: the replay rig keeps them out of its displacement statistics.
  /// Additive; defaults to false.
  final bool isNestedFragment;

  // ── Step response (#116) ──

  /// Which [StepResponse] the engine applied to THIS merge, or `null` when
  /// none did — either because `StabilizationEngine.stepResponse` is
  /// [StepResponse.damp] (#116 finding H, 2026-08-29: [StepResponse]'s own
  /// default flipped to [StepResponse.coherentShift] in 2.3.0 — [damp] is
  /// no longer THE default, only one of the three flag values that never
  /// sets this field), the merge's residual/group never qualified, or this
  /// merge is a provisional freeze, a nested-fragment confirmation, or a
  /// band-fallback admission (step response is never applied to any of
  /// those three — see [StepResponse]'s doc). Additive; defaults to null.
  /// The replay tooling reads this field directly off the [MergeResult]
  /// the merger callback receives, the same way it reads [isNestedFragment].
  final StepResponse? stepResponseApplied;

  /// All fields are engine-computed. The constructor throws [ArgumentError]
  /// on any violation of:
  /// - If [isProvisional], [provisionalCapturesRemaining] must be > 0
  /// - [observationCount] is >= 1
  /// - [positionConfidence] / [textConfidence] are in [0.0, 1.0] and not
  ///   NaN — checked here because the primary [PositionConfidence] /
  ///   [TextConfidence] constructors are unchecked.
  /// - [isNestedFragment] and [stepResponseApplied] are not both set — the
  ///   engine can never produce that combination (see [stepResponseApplied]'s
  ///   doc), so a `MergeResult` combining them can only be a construction
  ///   bug bypassing the engine.
  /// - [isProvisional] and [stepResponseApplied] are not both set (#116
  ///   finding D) — for the same reason: a band-fallback admission is
  ///   never step-response eligible (`stepResponseEligible` excludes
  ///   `wasBandFallback`), and a later capture of an already-provisional
  ///   block returns from the freeze path before step-response logic runs
  ///   at all. Like the nested-fragment case above, this combination is
  ///   unreachable from the engine and can only be a construction bug.
  MergeResult({
    required this.mergedRect,
    required this.positionConfidence,
    required this.driftCorrection,
    required this.winningOriginalText,
    required this.textConfidence,
    required this.updatedTextVotes,
    required this.textWasPromoted,
    required this.updatedClassificationVotes,
    required this.needsReclassification,
    required this.updatedCarouselIdVotes,
    required this.observationCount,
    required this.isProvisional,
    required this.provisionalCapturesRemaining,
    required this.sourceQuality,
    this.isNestedFragment = false,
    this.stepResponseApplied,
  }) {
    // Engine-output state. Per project policy (feedback_assert_vs_throw_in_storage):
    // asserts strip in release; production-critical invariants on stored state
    // must throw so a bypass via the unvalidated primary extension-type
    // constructor (`PositionConfidence(double)`) or a future engine bug
    // cannot silently propagate corrupted values into consumer caches.
    if (isProvisional && provisionalCapturesRemaining <= 0) {
      throw ArgumentError(
        'isProvisional requires provisionalCapturesRemaining > 0',
      );
    }
    if (observationCount < 1) {
      throw ArgumentError.value(
        observationCount,
        'observationCount',
        'must be >= 1',
      );
    }
    assertConfidenceRange('positionConfidence', positionConfidence.raw);
    assertConfidenceRange('textConfidence', textConfidence.raw);
    if (isNestedFragment && stepResponseApplied != null) {
      throw ArgumentError(
        'isNestedFragment and stepResponseApplied cannot both be set — a '
        'nested-fragment confirmation keeps the existing geometry and never '
        'runs step-response logic',
      );
    }
    if (isProvisional && stepResponseApplied != null) {
      throw ArgumentError(
        'isProvisional and stepResponseApplied cannot both be set — a '
        'band-fallback admission is never step-response eligible, and a '
        'later capture of an already-provisional block returns from the '
        'freeze path before step-response logic runs at all',
      );
    }
  }
}
