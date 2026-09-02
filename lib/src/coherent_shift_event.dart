// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'types/geometry.dart';

/// Which path of `StepResponse.coherentShift` decided a capture's plan.
///
/// The three paths are tried in a fixed order and the first to produce a
/// plan wins, so a capture reports exactly one source (see
/// `StabilizationEngine.coherentShiftFloorPx` and
/// `coherentShiftReanchorMinBlocks` for the two fallbacks' semantics).
enum CoherentShiftSource {
  /// The ordinary majority vote: at least `coherentShiftMinBlocks` movers
  /// agreeing within `coherentShiftTolerance`, holding at least
  /// `coherentShiftMinShare` of every mover this capture (#116).
  quorum,

  /// The #119 absolute-pixel floor (`coherentShiftFloorPx`): the quorum
  /// declined and one or more movers cleared the configured floor on
  /// their own magnitude — the large-slab regime where too few movers
  /// survive the match for a quorum.
  floor,

  /// The #119 batch re-anchor (`coherentShiftReanchorMinBlocks`): the
  /// quorum declined and a smaller cluster reached the configured count,
  /// with the share gate dropped. Tried only after the floor.
  reanchor,
}

/// The capture-level record of a decided coherent shift (2.5.0), on
/// `StabilizationResult.coherentShift`.
///
/// Before 2.5.0 a consumer could observe a shift only per block —
/// `MergeResult.stepResponseApplied`, delivered through its own merger
/// callback — and never the decided translation, how many pairs
/// followed it, or which path decided it. This value is that summary. It
/// describes merges that actually HAPPENED this capture, not the plan
/// alone: [memberCount] counts the merges that applied the translation,
/// and a capture whose plan reached nobody reports no event at all
/// (`StabilizationResult.coherentShift == null`).
///
/// Reading rules for a consumer's layout layer:
/// - An event = the tracked content moved as a slab by [translation].
///   Cached geometry the consumer holds outside the engine (its own
///   overlay boxes for these identities) should move by the same vector.
/// - No event on a capture where most fresh blocks were admitted as new
///   identities (`StabilizationResult.identityTurnover.admittedShare`
///   high) WHILE cached identities were left unmatched
///   (`identityTurnover.dropped + retained > 0`) = the line boxes
///   changed, not their position — a rewrap, which the engine
///   deliberately treats as an identity reset (contract U1). The second
///   condition matters: a session's first sighting admits every block
///   with nothing cached and is not a rewrap (README, "Observing the
///   engine's decisions").
/// - `damp` and `snap` never produce an event: snap re-anchors per block
///   and reports only through `MergeResult.stepResponseApplied`.
class CoherentShiftEvent {
  /// The decided translation, in the tracked blocks' own coordinate
  /// space (absolute page coordinates for `AbsoluteRect` consumers).
  /// Applied to every member's baseline before its ordinary merge.
  final Offset translation;

  /// How many merges this capture applied [translation] — voters plus
  /// adopted under-gate pairs. Always >= 1.
  final int memberCount;

  /// How many of the [memberCount] members were adopted under-gate pairs
  /// (`coherentShiftAdoptAgreeing`): pairs that could not vote because
  /// their own displacement sat inside their jitter allowance, but agreed
  /// with the decided translation within the quorum's tolerance. Always
  /// in `[0, memberCount]`. `0` under `coherentShiftAdoptAgreeing: false`.
  final int adoptedCount;

  /// The path that decided the plan.
  final CoherentShiftSource decidedBy;

  /// Creates a coherent-shift event.
  ///
  /// Throws [ArgumentError] when [translation] is not finite, when
  /// [memberCount] < 1, or when [adoptedCount] is outside
  /// `[0, memberCount]` — engine-output invariants, surfaced loudly.
  CoherentShiftEvent({
    required this.translation,
    required this.memberCount,
    required this.adoptedCount,
    required this.decidedBy,
  }) {
    if (!translation.dx.isFinite || !translation.dy.isFinite) {
      throw ArgumentError.value(
        translation,
        'translation',
        'must be finite',
      );
    }
    if (memberCount < 1) {
      throw ArgumentError.value(
        memberCount,
        'memberCount',
        'must be >= 1 — a decided plan nobody followed is not an event',
      );
    }
    if (adoptedCount < 0 || adoptedCount > memberCount) {
      throw ArgumentError.value(
        adoptedCount,
        'adoptedCount',
        'must be in [0, memberCount=$memberCount] — adopted pairs are a '
            'subset of the members',
      );
    }
  }

  /// The members that VOTED for the plan: [memberCount] minus
  /// [adoptedCount]. For a floor-decided plan this is the floor-qualified
  /// cluster; for a re-anchor plan, the re-anchored cluster.
  int get votedCount => memberCount - adoptedCount;

  /// Value equality over all four fields.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CoherentShiftEvent &&
          other.translation == translation &&
          other.memberCount == memberCount &&
          other.adoptedCount == adoptedCount &&
          other.decidedBy == decidedBy;

  @override
  int get hashCode =>
      Object.hash(translation, memberCount, adoptedCount, decidedBy);

  @override
  String toString() =>
      'CoherentShiftEvent(${decidedBy.name} translation=$translation '
      'members=$memberCount adopted=$adoptedCount)';
}
