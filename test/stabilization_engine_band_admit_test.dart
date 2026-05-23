// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(String text,
        {required double left,
        required double top,
        double width = 50,
        double height = 20,
        int observationCount = 1}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, width, height),
      payload: const Object(),
      originalText: text,
      observationCount: observationCount,
    );

void main() {
  group('StabilizationEngine band mode=admit (#20)', () {
    late StabilizationEngine<DefaultTrackedBlock<Object>, Object> engine;

    setUp(() {
      engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1, // accept observationCount: 5 candidate
        ),
      );
    });

    test('admits a band-matched candidate as provisional with config captures', () {
      // Seed an existing block with observationCount: 5 (well past floor).
      engine.stabilize([_block('hello world', left: 0, top: 0, observationCount: 5)]);

      // Fresh observation: band-similar text at identical rect (overlap = 1.0).
      // Text choice: 'hxlxo wxrxd' — 7 of 11 sig chars differ, falls in band
      // Lev (~0.55) but fails primary Lev 0.70 AND primary Jacc 0.80
      // (significant-char sets diverge).
      final fresh = _block('hxlxo wxrxd', left: 0, top: 0, observationCount: 1);

      final result = engine.stabilize([fresh]);

      // The merged block in stableBlocks should be provisional with
      // provisionalCapturesRemaining: 3 (default from BandFallbackConfig).
      // Find the block whose rect matches the seeded position.
      final stable = result.stableBlocks.firstWhere(
        (b) => b.absoluteRect.raw.left == 0,
        orElse: () => throw StateError('expected the merged block in results'),
      );
      expect(stable.isProvisional, isTrue,
          reason: 'band-admitted match enters provisional state');
      expect(stable.provisionalCapturesRemaining, 3,
          reason: 'matches bandFallback.provisionalCaptures default');

      // Counters: 1 considered (the seed block), 1 identified, 1 admitted.
      expect(engine.bandStats.candidatesConsidered, 1);
      expect(engine.bandStats.bandMatchesIdentified, 1);
      expect(engine.bandStats.matchesAdmitted, 1);
      // Both calls reached _findMatch; both produced no primary match
      // (seed call has empty index, second call's text doesn't pass primary).
      // So primaryMatchesRejected should be 2.
      expect(engine.bandStats.primaryMatchesRejected, 2);
    });
  });
}
