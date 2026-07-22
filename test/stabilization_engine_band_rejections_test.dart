// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/tracked_block.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(String text,
        {required double left,
        required double top,
        int observationCount = 1}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, 50, 20),
      payload: const Object(),
      originalText: text,
      observationCount: observationCount,
    );

void main() {
  group('StabilizationEngine band admit rejections (#20)', () {
    test('rejected by candidateObservationFloor', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 2,
        ),
      );
      // Seed candidate with observationCount: 1 — below floor 2.
      engine.stabilize(
          [_block('hello world', left: 0, top: 0, observationCount: 1)]);
      // Fresh band-similar observation at identical rect.
      engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);

      expect(engine.bandStats.rejectedCandidateFloor, 1);
      expect(engine.bandStats.bandMatchesIdentified, 0);
      expect(engine.bandStats.matchesAdmitted, 0);
    });

    test('rejected by spatialConfirm (custom predicate always returns false)',
        () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
          spatialConfirm: (TrackedBlock a, TrackedBlock b) => false,
        ),
      );
      engine.stabilize(
          [_block('hello world', left: 0, top: 0, observationCount: 5)]);
      engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);

      expect(engine.bandStats.rejectedSpatial, 1);
      expect(engine.bandStats.bandMatchesIdentified, 0);
      expect(engine.bandStats.matchesAdmitted, 0);
    });

    test('text-band miss ticks rejectedTextBand and no other rejection counter',
        () {
      // (Was previously named 'text-band miss is NOT bucketed in any rejection
      // counter' — accurate when the band funnel had no text-miss counter.
      // The v0.5.0 rejectedTextBand counter (#34 C1) closes that gap, so the
      // test is renamed and now asserts the new tick.)
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
        ),
      );
      engine.stabilize(
          [_block('hello world', left: 0, top: 0, observationCount: 5)]);
      // Fresh text totally different — fails both primary AND band text floors.
      // Use a 10-char string with zero significant-char overlap with 'hello world'.
      engine.stabilize([_block('XXXXXXXXXX', left: 0, top: 0)]);

      expect(engine.bandStats.candidatesConsidered, 1);
      expect(engine.bandStats.rejectedCandidateFloor, 0);
      expect(engine.bandStats.rejectedSpatial, 0,
          reason: 'spatial passed (identical rect)');
      expect(engine.bandStats.rejectedTextBand, 1,
          reason:
              'text-band miss is now bucketed in rejectedTextBand (#34 C1)');
      expect(engine.bandStats.bandMatchesIdentified, 0);
      expect(engine.bandStats.matchesAdmitted, 0);
    });
  });
}
