// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #149 (3.0) — the engine's levers live on `StabilizerConfig`. Pins:
//   (a) `StabilizerConfig()` reproduces every 2.6.x constructor default on
//       the engine's effective-value getters;
//   (b) every lever, including the experimental coherent-shift pair,
//       reaches its engine getter;
//   (c) the engine's argument validation still fires through the config.

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

StabilizationEngine<DefaultTrackedBlock<void>, void> _engine(
        [StabilizerConfig config = const StabilizerConfig()]) =>
    StabilizationEngine<DefaultTrackedBlock<void>, void>(
      merger: (existing, fresh, merge) => existing.applyMerge(merge),
      config: config,
    );

void main() {
  group('#149 StabilizerConfig', () {
    test('defaults reproduce the 2.6.x constructor defaults', () {
      final e = _engine();
      expect(e.bandFallback.mode, BandFallbackMode.off);
      expect(e.missedFrameRetention, 0);
      expect(e.positionMergeModel, PositionMergeModel.agreementWeighted);
      expect(e.stepResponse, StepResponse.coherentShift);
      expect(e.snapThresholdMultiplier, 1.5);
      expect(e.coherentShiftMinBlocks, 3);
      expect(e.coherentShiftMinShare, 0.5);
      expect(e.coherentShiftTolerance, 0.5);
      expect(e.coherentShiftAdoptAgreeing, isTrue);
      expect(e.coherentShiftFloorPx, isNull);
      expect(e.coherentShiftReanchorMinBlocks, isNull);
      expect(e.transformEstimateMinPairs, 3);
      expect(identical(e.config, const StabilizerConfig()), isTrue,
          reason: 'the default is a const instance the engine keeps');
    });

    test('every lever reaches its effective-value getter', () {
      const cfg = StabilizerConfig(
        matching: MatchingConfig(
          bandFallback: BandFallbackConfig(mode: BandFallbackMode.observeOnly),
        ),
        merge: MergeConfig(positionModel: PositionMergeModel.legacy),
        stepResponse: StepResponseConfig(
          mode: StepResponse.snap,
          snapThresholdMultiplier: 2.5,
          coherentShift: CoherentShiftConfig(
            minBlocks: 4,
            minShare: 0.6,
            tolerance: 0.25,
            adoptAgreeing: false,
            experimental: ExperimentalCoherentShiftOptions(
              floorPx: 390,
              reanchorMinBlocks: 2,
            ),
          ),
        ),
        retention: RetentionConfig(missedFrames: 2),
        diagnostics: DiagnosticsConfig(transformEstimateMinPairs: 5),
      );
      final e = _engine(cfg);
      expect(e.bandFallback.mode, BandFallbackMode.observeOnly);
      expect(e.positionMergeModel, PositionMergeModel.legacy);
      expect(e.stepResponse, StepResponse.snap);
      expect(e.snapThresholdMultiplier, 2.5);
      expect(e.coherentShiftMinBlocks, 4);
      expect(e.coherentShiftMinShare, 0.6);
      expect(e.coherentShiftTolerance, 0.25);
      expect(e.coherentShiftAdoptAgreeing, isFalse);
      expect(e.coherentShiftFloorPx, 390);
      expect(e.coherentShiftReanchorMinBlocks, 2);
      expect(e.missedFrameRetention, 2);
      expect(e.transformEstimateMinPairs, 5);
      expect(identical(e.config, cfg), isTrue);
    });

    test('engine validation still fires through the config', () {
      expect(
        () => _engine(const StabilizerConfig(
            retention: RetentionConfig(missedFrames: -1))),
        throwsArgumentError,
      );
      expect(
        () => _engine(const StabilizerConfig(
            diagnostics: DiagnosticsConfig(transformEstimateMinPairs: 2))),
        throwsArgumentError,
      );
      expect(
        () => _engine(const StabilizerConfig(
            stepResponse: StepResponseConfig(
                coherentShift: CoherentShiftConfig(
                    experimental:
                        ExperimentalCoherentShiftOptions(floorPx: 0))))),
        throwsArgumentError,
      );
    });

    test('copyWith replaces only the named stage', () {
      const base = StabilizerConfig(retention: RetentionConfig(missedFrames: 2));
      final next = base.copyWith(
          stepResponse: const StepResponseConfig(mode: StepResponse.damp));
      expect(next.retention.missedFrames, 2);
      expect(next.stepResponse.mode, StepResponse.damp);
      expect(identical(next.matching, base.matching), isTrue);
    });
  });
}
