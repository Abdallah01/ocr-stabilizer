import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

MergeResult _validResult({
  PositionConfidence positionConfidence = PositionConfidence.groundTruth,
  TextConfidence textConfidence = TextConfidence.groundTruth,
  int observationCount = 1,
  bool isProvisional = false,
  int provisionalCapturesRemaining = 0,
  bool isNestedFragment = false,
  StepResponse? stepResponseApplied,
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
    isNestedFragment: isNestedFragment,
    stepResponseApplied: stepResponseApplied,
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
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('must be a finite double in [0.0, 1.0]'),
        )),
        reason: 'MergeResult must surface the canonical assertConfidenceRange '
            'message wording; a silent message drift would make ArgumentError '
            'matching across the codebase inconsistent.',
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

    test('throws on NaN confidence (primary ctor bypass)', () {
      // NaN fails both `< 0` and `> 1.0` comparisons — the boundary guard
      // must test isNaN explicitly or a NaN confidence slips through.
      expect(
        () => _validResult(
          positionConfidence: const PositionConfidence(double.nan),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => _validResult(
          textConfidence: const TextConfidence(double.nan),
        ),
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

    // #116: a nested-fragment confirmation keeps the host's existing
    // geometry by construction (see the class doc) — the engine never runs
    // step-response logic on that path (StabilizationEngine._mergeImpl
    // returns before `stepResponseEligible` is even computed). A
    // `MergeResult` combining both flags is a state the engine can never
    // produce; constructing it directly (bypassing the engine) must be
    // caught here rather than silently accepted as a "valid" but
    // unreachable combination.
    test('throws when isNestedFragment and stepResponseApplied are both set',
        () {
      expect(
        () => _validResult(
          isNestedFragment: true,
          stepResponseApplied: StepResponse.snap,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => _validResult(
          isNestedFragment: true,
          stepResponseApplied: StepResponse.coherentShift,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('isNestedFragment alone (no step response) succeeds', () {
      expect(
        () => _validResult(isNestedFragment: true),
        returnsNormally,
      );
    });

    // #116 finding D: a band-fallback (provisional) admission never runs
    // step-response logic either — StabilizationEngine._mergeImpl computes
    // `stepResponseEligible = !wasBandFallback && ...` (see #116), and the
    // provisional-freeze path at the top of `_mergeImpl` returns before
    // that computation runs on any LATER capture of an already-provisional
    // block. A `MergeResult` combining both is, like the nested-fragment
    // combination above, a state the engine can never produce — the
    // constructor must catch a direct-construction bypass here too.
    test('throws when isProvisional and stepResponseApplied are both set',
        () {
      expect(
        () => _validResult(
          isProvisional: true,
          provisionalCapturesRemaining: 2,
          stepResponseApplied: StepResponse.snap,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => _validResult(
          isProvisional: true,
          provisionalCapturesRemaining: 2,
          stepResponseApplied: StepResponse.coherentShift,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('isProvisional alone (no step response) succeeds', () {
      expect(
        () => _validResult(
          isProvisional: true,
          provisionalCapturesRemaining: 2,
        ),
        returnsNormally,
      );
    });
  });
}
