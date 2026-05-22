import 'dart:ui' show Offset;

import 'text_vote.dart';
import 'types/absolute_rect.dart';
import 'types/confidence_types.dart';

/// Exhaustive delta from a SAR merge. Every field is engine-computed.
///
/// The consumer receives this via [BlockMerger] and uses it to construct
/// an updated block instance (e.g. via `copyWith`). No fields are
/// pass-through — the engine owns the computation of every value.
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
  final int observationCount;

  /// Whether the merged block remains provisional (not yet promoted).
  final bool isProvisional;

  /// Captures left before the provisional block is promoted or evicted.
  final int provisionalCapturesRemaining;

  // ── Source quality (engine picks higher tier) ──

  /// Best source-quality tier observed (engine picks max of fresh/existing).
  final int sourceQuality;

  /// All fields are engine-computed. Invariants:
  /// - If [isProvisional], [provisionalCapturesRemaining] must be > 0
  /// - [observationCount] is >= 1
  /// - [positionConfidence] / [textConfidence] range invariant is enforced
  ///   by the [PositionConfidence] / [TextConfidence] types themselves.
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
    if (positionConfidence.raw.isNaN ||
        positionConfidence.raw < 0 ||
        positionConfidence.raw > 1.0) {
      throw ArgumentError.value(
        positionConfidence.raw,
        'positionConfidence',
        'must be in [0.0, 1.0]',
      );
    }
    if (textConfidence.raw.isNaN ||
        textConfidence.raw < 0 ||
        textConfidence.raw > 1.0) {
      throw ArgumentError.value(
        textConfidence.raw,
        'textConfidence',
        'must be in [0.0, 1.0]',
      );
    }
  }
}
