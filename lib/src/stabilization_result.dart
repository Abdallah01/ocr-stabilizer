// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'coherent_shift_event.dart';
import 'identity_turnover.dart';
import 'transform_estimate.dart';
import 'merge_result.dart';
import 'observable_block.dart';
import 'step_response.dart';

/// How a consumer constructs an updated block from engine-computed merge data.
///
/// The engine calls this with the existing block, the fresh observation, and
/// the computed [MergeResult]. The consumer returns a new immutable instance
/// (e.g. via `copyWith`). The [fresh] block is provided so the consumer can
/// access app-specific pass-through fields (scroll context, classification
/// flags, translated text) that the engine does not compute.
///
/// **Nested confirmations (2.2.0, `merge.isNestedFragment`):** the fresh
/// observation was one LINE of [existing] reported on its own, and it
/// carries nothing the host should adopt. The engine therefore passes
/// [existing] as [fresh] too, so a merger that copies pass-through fields
/// from [fresh] keeps the host's own — no consumer change is needed to
/// stay correct. Every [MergeResult] field except `observationCount` and
/// `sourceQuality` repeats the host's current value on that path.
///
/// **Required field mappings from [MergeResult]:**
/// - `mergedRect` → `absoluteRect`
/// - `positionConfidence` → `positionConfidence`
/// - `winningOriginalText` → `originalText`
/// - `textConfidence` → `textConfidence`
/// - `updatedTextVotes` → `textVotes`
/// - `updatedClassificationVotes` → `classificationVotes`
/// - `needsReclassification` → `needsReclassification`
/// - `updatedCarouselIdVotes` → `carouselIdVotes`
/// - `observationCount` → `observationCount`
/// - `isProvisional` → `isProvisional`
/// - `provisionalCapturesRemaining` → `provisionalCapturesRemaining`
/// - `sourceQuality` → consumer-specific (e.g. map to enum)
///
/// Omitting fields causes state drift between engine and consumer.
typedef BlockMerger<T extends ObservableBlock<P>, P> = T Function(
    T existing, T fresh, MergeResult merge);

/// Type of contradiction detected between fresh and cached blocks.
enum ContradictionType {
  /// Fresh blocks subdivide a cached block (grouping changed).
  grouping,

  /// A fresh block subsumes multiple cached blocks (splitting changed).
  splitting,
}

/// A detected contradiction between fresh and cached blocks.
///
/// **Direction depends on [type]:**
/// - [ContradictionType.grouping]: [target] is a cached block,
///   [evidence] is 2+ fresh blocks that subdivide it.
/// - [ContradictionType.splitting]: [target] is a fresh block,
///   [evidence] is 2+ cached blocks it subsumes.
///
/// Detection-only: the package detects contradictions and returns events.
/// The app decides the reaction (evict, re-translate, flag for review).
class ContradictionEvent<T> {
  /// The kind of contradiction detected.
  final ContradictionType type;

  /// Target block — cached for grouping, fresh for splitting (see [type]).
  final T target;

  /// 2+ blocks that prove the contradiction (subdividers or subsumed blocks).
  final List<T> evidence;

  /// Creates a contradiction event.
  ///
  /// Throws [ArgumentError] if [evidence] has fewer than 2 entries — a
  /// "contradiction" proven by a single block is not a contradiction.
  /// Uses `throw` (not `assert`) per the package's storage-invariant
  /// policy (see CONTRIBUTING.md): asserts strip in release builds. This
  /// cost the constructor its `const`-ability in 0.6.0 (#51).
  ContradictionEvent({
    required this.type,
    required this.target,
    required this.evidence,
  }) {
    if (evidence.length < 2) {
      throw ArgumentError(
        'ContradictionEvent invariant: evidence must contain >= 2 blocks '
        '(got ${evidence.length}). A contradiction is proven by multiple '
        'agreeing blocks; a single block cannot subdivide or subsume.',
      );
    }
  }
}

/// Output of a single [StabilizationEngine.merge] call.
///
/// Contains the merged block and any signals that the merge produced.
/// Consumers that call [StabilizationEngine.merge] directly (instead of
/// [StabilizationEngine.stabilize]) must handle these signals themselves.
class MergeOutput<T> {
  /// The merged block (constructed by the [BlockMerger] callback).
  final T merged;

  /// Whether the winning text changed (old text should be invalidated).
  final bool textWasPromoted;

  /// The old original text if [textWasPromoted] is true, else null.
  final String? promotedFromText;

  /// Whether a contextual check triggered invalidation.
  final bool contextInvalidated;

  /// Whether this block reached the well-observed threshold.
  final bool isWellObserved;

  /// The step response this merge applied, if any (2.5.0): `null` for a
  /// damped merge, a freeze-path or nested-fragment merge, and a
  /// band-fallback admission; [StepResponse.snap] or
  /// [StepResponse.coherentShift] otherwise — the same value the
  /// [MergeResult] handed to the merger carried in
  /// `MergeResult.stepResponseApplied`. Surfaced here so
  /// `StabilizationEngine.stabilize` counts applied coherent-shift merges
  /// at the APPLICATION site (this field), never from plan membership —
  /// a second fresh block reaching a plan member through a
  /// step-response-ineligible path (a carousel child, a band admission)
  /// is a member by identity but not by application.
  final StepResponse? stepResponseApplied;

  /// Creates a merge output.
  const MergeOutput({
    required this.merged,
    this.textWasPromoted = false,
    this.promotedFromText,
    this.contextInvalidated = false,
    this.isWellObserved = false,
    this.stepResponseApplied,
  });
}

/// Output of [StabilizationEngine.stabilize].
///
/// Contains the merged blocks that survived dedup, any contradiction
/// detections, and signals for the app's translation layer.
class StabilizationResult<T> {
  /// Blocks that survived dedup and were merged into the model.
  final List<T> stableBlocks;

  /// Contradiction detections (app decides how to handle).
  final List<ContradictionEvent<T>> contradictions;

  /// Source texts whose translation should be invalidated
  /// (text was promoted to a different variant via voting).
  final List<String> invalidatedTexts;

  /// Source texts that reached the well-observed threshold
  /// (observationCount >= 3, translation can be cached long-term).
  final List<String> wellObservedTexts;

  /// The coherent shift this capture applied, if one was decided and at
  /// least one merge followed it (2.5.0) — the decided translation, how
  /// many pairs followed it, how many of those were adopted, and which
  /// path decided it. `null` on every capture where no plan was decided:
  /// every control capture, and always under `StepResponse.damp` /
  /// `StepResponse.snap` (snap re-anchors per block and reports only
  /// through `MergeResult.stepResponseApplied`). See [CoherentShiftEvent]
  /// for the reading rules.
  final CoherentShiftEvent? coherentShift;

  /// The per-capture identity census (2.5.0): fresh blocks merged into a
  /// tracked identity vs admitted as new, and cached identities retained
  /// vs dropped. [IdentityTurnover.none] on a hand-built result. A
  /// capture with a high [IdentityTurnover.admittedShare] and no
  /// [coherentShift] is the rewrap shape — same content, new line boxes —
  /// which the engine deliberately treats as an identity reset (contract
  /// U1).
  final IdentityTurnover identityTurnover;

  /// The similarity transform (isotropic scale + translation) fitted
  /// over this capture's eligible matched pairs (2.6.0, #135) —
  /// OBSERVED, never applied: the merge stays per block (contract U9).
  /// `null` when fewer than `StabilizationEngine.transformEstimateMinPairs`
  /// eligible pairs matched (a session's first sighting, a rewrap that
  /// reset most identities) or the pairs give no lever arm for a scale.
  /// See [TransformEstimate] for the reading rules — in particular,
  /// read [TransformEstimate.residualPx] before believing
  /// [TransformEstimate.scale]: a partial step fits as a scale with a
  /// large residual, a zoom as a scale with a small one.
  final TransformEstimate? transformEstimate;

  /// Creates a stabilization result.
  const StabilizationResult({
    required this.stableBlocks,
    this.contradictions = const [],
    this.invalidatedTexts = const [],
    this.wellObservedTexts = const [],
    this.coherentShift,
    this.identityTurnover = IdentityTurnover.none,
    this.transformEstimate,
  });
}
