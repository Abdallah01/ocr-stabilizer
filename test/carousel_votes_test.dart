// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #148 (3.0) — `CarouselVotes` replaces the `{-1: 1}` phantom-vote sentinel
// that `DefaultTrackedBlock.carouselVotes` used to default to. Pins:
//   (a) `none()` carries NO vote — the 2.x sentinel is gone;
//   (b) the first real carousel observation is counted exactly once (the
//       2.x "clear the phantom" rule, now a non-event);
//   (c) a genuine non-carousel observation IS counted (2.x accumulated it
//       on top of the phantom; 3.0 counts it on its own);
//   (d) seeding from the block's own scroll context: a block constructed
//       inside a carousel starts with one vote for it, outside with none;
//   (e) value equality, so `Equatable`-style consumers can list it in props.

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  group('#148 CarouselVotes', () {
    test('none() carries no vote and has not observed a carousel', () {
      const v = CarouselVotes.none();
      expect(v.votes, isEmpty);
      expect(v.hasObservedCarousel, isFalse);
    });

    test('first real carousel observation is counted exactly once', () {
      final v = const CarouselVotes.none().record(2);
      expect(v.votes, {2: 1});
      expect(v.hasObservedCarousel, isTrue);
    });

    test('a non-carousel observation is counted on its own', () {
      final v = const CarouselVotes.none().record(-1);
      expect(v.votes, {-1: 1});
      expect(v.hasObservedCarousel, isFalse);
      expect(v.record(3).votes, {-1: 1, 3: 1},
          reason: 'an earlier real non-carousel vote is kept, as in 2.x');
    });

    test('record accumulates and never mutates the receiver', () {
      final a = const CarouselVotes.none().record(2);
      final b = a.record(2).record(5);
      expect(a.votes, {2: 1});
      expect(b.votes, {2: 2, 5: 1});
      expect(() => b.votes[9] = 1, throwsUnsupportedError,
          reason: 'the exposed histogram is unmodifiable');
    });

    test('seeded(): inside a carousel = one vote, outside = none', () {
      expect(CarouselVotes.seeded(4).votes, {4: 1});
      expect(CarouselVotes.seeded(4).hasObservedCarousel, isTrue);
      expect(CarouselVotes.seeded(-1), const CarouselVotes.none());
    });

    test('fromHistogram copies and normalises the 2.x sentinel', () {
      final raw = {7: 2, -1: 1};
      final v = CarouselVotes.fromHistogram(raw);
      raw[7] = 99;
      expect(v.votes, {7: 2, -1: 1}, reason: 'defensive copy');
      expect(CarouselVotes.fromHistogram({-1: 1}), const CarouselVotes.none(),
          reason: 'a lone {-1: 1} is the 2.x phantom, not evidence');
      expect(CarouselVotes.fromHistogram({-1: 2}).votes, {-1: 2},
          reason: 'anything else is real history');
    });

    test('value equality is order-independent', () {
      final a = const CarouselVotes.none().record(1).record(2);
      final b = const CarouselVotes.none().record(2).record(1);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const CarouselVotes.none().record(1)));
      expect(a.toString(), 'CarouselVotes({1: 1, 2: 1})');
    });
  });

  group('#148 engine + DefaultTrackedBlock wiring', () {
    DefaultTrackedBlock<void> block(String text, {int hz = -1}) =>
        DefaultTrackedBlock<void>(
          absoluteRect: AbsoluteRect.fromLTWH(0, 0, 200, 30),
          payload: null,
          originalText: text,
          coordinates: CoordinateContext.page(
              scroll: ScrollContext(hzScrollerIndex: hz)),
        );
    StabilizationEngine<DefaultTrackedBlock<void>, void> engine() =>
        StabilizationEngine<DefaultTrackedBlock<void>, void>(
          merger: (existing, fresh, m) => existing.applyMerge(m),
        );

    test('DefaultTrackedBlock defaults to CarouselVotes.none()', () {
      expect(block('hello world').carouselVotes, const CarouselVotes.none());
    });

    test('first merge inside a carousel counts one vote for it', () {
      final e = engine();
      e.stabilize([block('hello world')]);
      final merged = e.stabilize([block('hello world', hz: 2)]).stableBlocks;
      expect(merged.single.carouselVotes.votes, {2: 1});
    });

    test('a merge outside any carousel counts a -1 vote', () {
      final e = engine();
      e.stabilize([block('hello world')]);
      final merged = e.stabilize([block('hello world')]).stableBlocks;
      expect(merged.single.carouselVotes.votes, {-1: 1});
    });
  });
}
