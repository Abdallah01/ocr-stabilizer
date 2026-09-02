// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
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
  group('StabilizationEngine band mode=observeOnly (#20)', () {
    test('runs the full loop, ticks band counters, never admits', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.observeOnly,
          candidateObservationFloor: 1, // accept any observation count
        ),
      );

      // Seed a candidate with observationCount >= floor.
      engine.stabilize(
          [_block('hello world', left: 0, top: 0, observationCount: 5)]);

      // Fresh observation: text similar in band (text-band match), identical rect.
      // 'hxlxo wxrxd' shares many chars with 'hello world' but diverges enough
      // to fail primary Lev 0.70 / Jaccard 0.80, while passing band Lev 0.50 /
      // Jaccard 0.60.
      engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);

      // observeOnly: full loop runs, counters tick, no admission.
      expect(engine.bandStats.matchesAdmitted, 0,
          reason: 'observeOnly never admits');
      expect(engine.bandStats.candidatesConsidered, greaterThanOrEqualTo(1),
          reason: 'observeOnly scans candidates');
      expect(engine.bandStats.primaryMatchesRejected, greaterThanOrEqualTo(1),
          reason: 'second call primary missed');
      // 'hxlxo wxrxd' vs 'hello world':
      //   Lev = 1 - 4/11 ≈ 0.636 → below primary 0.70, above band 0.50.
      //   Jaccard (char-set) = 7/9 ≈ 0.778 → below primary 0.80, above band 0.60.
      // Both clear band thresholds, identical rect clears spatial confirm,
      // observationCount=5 clears candidateObservationFloor=1.
      expect(engine.bandStats.bandMatchesIdentified, 1,
          reason: 'band thresholds + spatial gate + obs floor all pass');
    });

    test('observeOnly scans every candidate, not just the first match', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.observeOnly,
          candidateObservationFloor: 1,
        ),
      );
      // Seed three candidates at different positions (so spatial index
      // surfaces all three when the fresh observation is near them).
      engine.stabilize([
        _block('alpha one hello', left: 0, top: 0, observationCount: 5),
        _block('alpha two hello', left: 0, top: 30, observationCount: 5),
        _block('alpha three hi', left: 0, top: 60, observationCount: 5),
      ]);
      // Fresh observation at the same column — should be in the spatial
      // candidates set with all three seeded blocks.
      engine.stabilize([_block('alpha 1', left: 0, top: 15)]);
      // candidatesConsidered should reflect every candidate the loop saw,
      // not just the first match.
      // The exact count depends on spatial-index behavior; assert > 1.
      expect(engine.bandStats.candidatesConsidered, greaterThan(1),
          reason:
              'observeOnly continues scanning after first identified match');
    });
  });
}
