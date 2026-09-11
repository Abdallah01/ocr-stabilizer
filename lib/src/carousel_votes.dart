// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// =============================================================================
// CAROUSEL VOTES (#148, 3.0)
// =============================================================================
// The histogram of horizontal-scroller (carousel) indices a block has been
// observed under, as a value type. Before 3.0 this was a bare
// `Map<int, int>` that had to default to `{-1: 1}` — a phantom "never seen
// in a carousel" vote the engine's merge path recognised and cleared on the
// first real carousel observation. That protocol detail leaked into every
// consumer's block type; `CarouselVotes.none()` replaces it and carries no
// vote at all, so there is nothing to clear.
// =============================================================================

import 'package:meta/meta.dart';

/// How many times a block has been observed under each horizontal-scroller
/// index (`-1` = outside any horizontal scroller).
///
/// Immutable. The engine advances it with [record] on every merge; a
/// consumer only ever constructs [CarouselVotes.none] (or
/// [CarouselVotes.seeded] when it wants the block's own construction to
/// count as an observation, as the reference consumer does).
@immutable
final class CarouselVotes {
  /// No observation yet. This is what a freshly constructed block carries.
  const CarouselVotes.none() : votes = const {};

  /// One vote for the block's own [hzScrollerIndex] at construction; a
  /// negative index (outside any horizontal scroller) seeds nothing, so
  /// the first real carousel observation is never out-voted by the
  /// block's own non-carousel origin.
  factory CarouselVotes.seeded(int hzScrollerIndex) => hzScrollerIndex < 0
      ? const CarouselVotes.none()
      : CarouselVotes._(Map.unmodifiable({hzScrollerIndex: 1}));

  /// From a raw histogram (deserialisation). The map is copied.
  ///
  /// A histogram that is exactly `{-1: 1}` is the 2.x phantom sentinel and
  /// maps to [CarouselVotes.none]; any other content is kept as real
  /// history, including larger `-1` counts.
  factory CarouselVotes.fromHistogram(Map<int, int> votes) {
    if (votes.isEmpty || (votes.length == 1 && votes[-1] == 1)) {
      return const CarouselVotes.none();
    }
    return CarouselVotes._(Map.unmodifiable(Map<int, int>.of(votes)));
  }

  const CarouselVotes._(this.votes);

  /// The histogram: horizontal-scroller index → observation count.
  /// Unmodifiable.
  final Map<int, int> votes;

  /// Whether any observation placed this block inside a horizontal
  /// scroller (an index `>= 0`).
  bool get hasObservedCarousel => votes.keys.any((k) => k >= 0);

  /// This histogram plus one observation under [hzScrollerIndex].
  CarouselVotes record(int hzScrollerIndex) {
    final next = Map<int, int>.of(votes);
    next[hzScrollerIndex] = (next[hzScrollerIndex] ?? 0) + 1;
    return CarouselVotes._(Map.unmodifiable(next));
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! CarouselVotes || other.votes.length != votes.length) {
      return false;
    }
    for (final e in votes.entries) {
      if (other.votes[e.key] != e.value) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAllUnordered(
      [for (final e in votes.entries) (e.key, e.value)]);

  @override
  String toString() => 'CarouselVotes($votes)';
}
