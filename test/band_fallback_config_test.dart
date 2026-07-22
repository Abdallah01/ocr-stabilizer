// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';

void main() {
  group('BandFallbackConfig defaults (#20)', () {
    test('default-constructed config has expected values', () {
      const cfg = BandFallbackConfig();
      expect(cfg.mode, BandFallbackMode.off);
      expect(cfg.bandLevenshteinFloor, 0.50);
      expect(cfg.bandJaccardFloor, 0.60);
      expect(cfg.candidateObservationFloor, 4); // = provisionalCaptures (3) + 1
      expect(cfg.provisionalCaptures, 3);
      expect(cfg.spatialConfirm, isNull);
    });

    test('candidateObservationFloor defaults to provisionalCaptures + 1', () {
      const cfg = BandFallbackConfig(provisionalCaptures: 5);
      expect(cfg.candidateObservationFloor, 6);
    });

    test('explicit candidateObservationFloor overrides the derivation', () {
      const cfg = BandFallbackConfig(
        provisionalCaptures: 5,
        candidateObservationFloor: 2,
      );
      expect(cfg.candidateObservationFloor, 2);
    });
  });

  group(
      'BandFallbackConfig invariants (#20) — assert in const ctor fires AssertionError in debug',
      () {
    test('throws when bandLevenshteinFloor is at upper bound 0.70', () {
      expect(() => BandFallbackConfig(bandLevenshteinFloor: 0.70),
          throwsA(isA<AssertionError>()));
    });

    test('throws when bandLevenshteinFloor is below 0.0', () {
      expect(() => BandFallbackConfig(bandLevenshteinFloor: -0.01),
          throwsA(isA<AssertionError>()));
    });

    test('throws when bandJaccardFloor is at upper bound 0.80', () {
      expect(() => BandFallbackConfig(bandJaccardFloor: 0.80),
          throwsA(isA<AssertionError>()));
    });

    test('throws when bandJaccardFloor is below 0.0', () {
      expect(() => BandFallbackConfig(bandJaccardFloor: -0.01),
          throwsA(isA<AssertionError>()));
    });

    test('throws when candidateObservationFloor is negative', () {
      expect(() => BandFallbackConfig(candidateObservationFloor: -1),
          throwsA(isA<AssertionError>()));
    });

    test('throws when provisionalCaptures is 0', () {
      expect(() => BandFallbackConfig(provisionalCaptures: 0),
          throwsA(isA<AssertionError>()));
    });

    test('accepts boundary values just inside the ranges', () {
      expect(
        () => const BandFallbackConfig(
          bandLevenshteinFloor: 0.0,
          bandJaccardFloor: 0.0,
          candidateObservationFloor: 0,
          provisionalCaptures: 1,
        ),
        returnsNormally,
      );
      expect(
        () => const BandFallbackConfig(
          bandLevenshteinFloor: 0.6999999,
          bandJaccardFloor: 0.7999999,
        ),
        returnsNormally,
      );
    });
  });
}
