import 'dart:ui' show Offset, Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

MergeResult _validResult({
  PositionConfidence positionConfidence = PositionConfidence.groundTruth,
  TextConfidence textConfidence = TextConfidence.groundTruth,
  int observationCount = 1,
  bool isProvisional = false,
  int provisionalCapturesRemaining = 0,
}) {
  return MergeResult(
    mergedRect: const AbsoluteRect(Rect.fromLTWH(0, 0, 100, 30)),
    positionConfidence: positionConfidence,
    driftCorrection: Offset.zero,
    winningOriginalText: 'x',
    textConfidence: textConfidence,
    updatedTextVotes: const {},
    textWasPromoted: false,
    updatedClassificationVotes: const {},
    needsReclassification: false,
    updatedCarouselIdVotes: const {-1: 1},
    observationCount: observationCount,
    isProvisional: isProvisional,
    provisionalCapturesRemaining: provisionalCapturesRemaining,
    sourceQuality: 0,
  );
}

void main() {
  group('MergeResult invariants', () {
    test('valid construction succeeds', () {
      expect(() => _validResult(), returnsNormally);
    });

    test('throws on out-of-range positionConfidence (primary ctor bypass)', () {
      // The primary `PositionConfidence(double)` constructor is intentionally
      // unvalidated to allow `const PositionConfidence(0.5)` test fixtures.
      // MergeResult must catch the bypass at the engine-output boundary.
      expect(
        () => _validResult(positionConfidence: const PositionConfidence(-0.1)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => _validResult(positionConfidence: const PositionConfidence(1.1)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on out-of-range textConfidence (primary ctor bypass)', () {
      expect(
        () => _validResult(textConfidence: const TextConfidence(-0.1)),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => _validResult(textConfidence: const TextConfidence(1.1)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws on observationCount < 1', () {
      expect(
        () => _validResult(observationCount: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when isProvisional but provisionalCapturesRemaining is 0', () {
      expect(
        () => _validResult(
          isProvisional: true,
          provisionalCapturesRemaining: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('all invariants throw (not assert) so release-mode bypass is caught',
        () {
      // Belt-and-suspenders: ArgumentError is unconditionally thrown,
      // unlike `assert` which strips in release builds. This is the
      // load-bearing property — confidence-corruption bugs surface
      // immediately in production rather than silently propagating
      // through the cache cascade.
      try {
        _validResult(positionConfidence: const PositionConfidence(2.0));
        fail('expected ArgumentError');
      } catch (e) {
        expect(e, isA<ArgumentError>());
        expect((e as ArgumentError).name, 'positionConfidence');
      }
    });
  });
}
