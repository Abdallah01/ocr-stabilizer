// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_stats.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(String text,
        {double left = 0, double top = 0}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, 50, 20),
      payload: const Object(),
      originalText: text,
    );

void main() {
  group('StabilizationEngine band mode=off — primary counters tick (#20)', () {
    late StabilizationEngine<DefaultTrackedBlock<Object>, Object> engine;

    setUp(() {
      engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        // bandFallback defaults to const BandFallbackConfig() — mode: off
      );
    });

    test('primaryMatchesAdmitted ticks when fresh matches an existing block',
        () {
      // Seed an existing block. The seed call reaches _findMatch with an
      // empty spatial index — no candidates, no match — so primaryRejected
      // ticks per the spec invariant
      // (admitted + rejected == total fresh reaching _findMatch).
      engine.stabilize([_block('hello world', left: 0, top: 0)]);

      // Re-observe with identical text and overlapping position — primary
      // path finds the seeded candidate, admits.
      engine.stabilize([_block('hello world', left: 0, top: 0)]);

      expect(engine.bandStats.primaryMatchesAdmitted, 1);
      expect(engine.bandStats.primaryMatchesRejected, 1,
          reason:
              'seed call had no candidates → rejected; second call admitted');
      expect(engine.bandStats.candidatesConsidered, 0,
          reason: 'off mode does zero band work');
    });

    test('primaryMatchesRejected ticks when fresh finds no primary match', () {
      // Seed (rejected — empty index).
      engine.stabilize([_block('hello world', left: 0, top: 0)]);

      // Observe a completely-different text at the same position —
      // primary path evaluates the seed candidate, similarity below 0.70,
      // rejected. Off mode declines to enter the band loop.
      engine.stabilize([_block('xxxxxxxxxxx', left: 0, top: 0)]);

      expect(engine.bandStats.primaryMatchesAdmitted, 0);
      expect(engine.bandStats.primaryMatchesRejected, 2,
          reason: 'both calls reached _findMatch without admitting; '
              'each ticks rejected per the spec invariant');
      expect(engine.bandStats.candidatesConsidered, 0);
    });

    test('bandStats getter returns BandFallbackStats supertype (not Internal)',
        () {
      // Compile-time check that the getter's return type is the supertype
      // and not the Internal subclass — consumers can't see mutators.
      final stats = engine.bandStats;
      expect(stats, isA<BandFallbackStats>());
    });
  });
}
