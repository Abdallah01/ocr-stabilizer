// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';

/// Locks the layered defense against `NaN`/`Infinity` band floors:
///
/// 1. [BandFallbackConfig]'s `assert` (debug-only — stripped in release,
///    but also fires at compile-time when the analyzer can evaluate the
///    const ctor and prove the invariant violation).
/// 2. [StabilizationEngine]'s `_validateBandFallbackConfig` (release-safe
///    `throw ArgumentError` — defense-in-depth for the case where a
///    non-`const` config is built from runtime values in a release build).
///
/// IEEE 754 quirk that motivates this test: the bare range check
/// `value < 0.0 || value >= 0.70` evaluates `false || false == false` for
/// NaN, so without an explicit `!isFinite` short-circuit, NaN would
/// silently pass through the release-build defense. Caught by the v0.4.0
/// release PR's bot review.
///
/// We deliberately drop `const` from the invalid-config constructions so
/// the analyzer can't reject them at compile time. Under `flutter test`
/// (debug mode), the ctor `assert` then fires at runtime with
/// `AssertionError`; in a hypothetical release-mode test it would be
/// `ArgumentError` from the engine. The test accepts either — locking
/// "NaN is rejected by some defense layer" without depending on which.
void main() {
  group(
    'StabilizationEngine — NaN / Infinity band floors are rejected',
    () {
      StabilizationEngine<DefaultTrackedBlock<Object>, Object> makeEngine(
        BandFallbackConfig cfg,
      ) {
        return StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
          merger: (existing, fresh, m) => existing.applyMerge(m),
          bandFallback: cfg,
        );
      }

      final throwsAnyError =
          throwsA(anyOf(isA<ArgumentError>(), isA<AssertionError>()));

      test('NaN bandLevenshteinFloor is rejected', () {
        // ignore: prefer_const_constructors
        expect(
          () => makeEngine(BandFallbackConfig(
            bandLevenshteinFloor: double.nan,
          )),
          throwsAnyError,
        );
      });

      test('NaN bandJaccardFloor is rejected', () {
        // ignore: prefer_const_constructors
        expect(
          () => makeEngine(BandFallbackConfig(
            bandJaccardFloor: double.nan,
          )),
          throwsAnyError,
        );
      });

      test('+Infinity bandLevenshteinFloor is rejected', () {
        // ignore: prefer_const_constructors
        expect(
          () => makeEngine(BandFallbackConfig(
            bandLevenshteinFloor: double.infinity,
          )),
          throwsAnyError,
        );
      });

      test('-Infinity bandJaccardFloor is rejected', () {
        // ignore: prefer_const_constructors
        expect(
          () => makeEngine(BandFallbackConfig(
            bandJaccardFloor: double.negativeInfinity,
          )),
          throwsAnyError,
        );
      });

      test('valid edge config constructs cleanly', () {
        // candidateObservationFloor=0, provisionalCaptures=1 are the
        // tightest legal values; both band floors at 0.0 are also legal.
        expect(
          () => makeEngine(const BandFallbackConfig(
            bandLevenshteinFloor: 0.0,
            bandJaccardFloor: 0.0,
            candidateObservationFloor: 0,
            provisionalCaptures: 1,
          )),
          returnsNormally,
        );
      });
    },
  );
}
