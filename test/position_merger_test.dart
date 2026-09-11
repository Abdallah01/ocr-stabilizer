// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #150: the position merger standing on its own. The engine-level
// numerics (every position model × step response over the corpus) stay
// pinned by the differential replay harness and the step-response test
// files; these tests pin the class's own contract.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:ocr_stabilizer/src/internal/position_merger.dart';
import 'package:test/test.dart';

DefaultTrackedBlock<Object> _block(double top,
        {double conf = 0.5, int observationCount = 1}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(10, top, 200, 30),
      originalText: 't',
      positionConfidence: PositionConfidence(conf),
      textConfidence: const TextConfidence(0.9),
      payload: const Object(),
      observationCount: observationCount,
    );

PositionMerger<DefaultTrackedBlock<Object>> _merger({
  PositionMergeModel model = PositionMergeModel.agreementWeighted,
  StepResponse stepResponse = StepResponse.damp,
}) =>
    PositionMerger(
        model: model, stepResponse: stepResponse, snapThresholdMultiplier: 1.5);

void main() {
  group('PositionMerger', () {
    test(
        'agreement-weighted weight decays with observation count; '
        'legacy does not', () {
      final fresh = _block(100);
      final young = _block(100, observationCount: 1);
      final old = _block(100, observationCount: 10);
      final agreement = _merger();
      expect(agreement.mergeWeight(fresh, old),
          lessThan(agreement.mergeWeight(fresh, young)));
      final legacy = _merger(model: PositionMergeModel.legacy);
      expect(legacy.mergeWeight(fresh, old), legacy.mergeWeight(fresh, young));
    });

    test('damp: the merged rect is the lerp toward the corrected rect', () {
      final existing = _block(100, conf: 0.5);
      final fresh = _block(200, conf: 0.5);
      final r = _merger().resolve(
          fresh: fresh,
          existing: existing,
          correctedRect: fresh.absoluteRect.raw,
          wasBandFallback: false);
      expect(r.stepResponseApplied, isNull);
      expect(r.mergedRect.top, 150, reason: 'equal confidence, n=1 → w=0.5');
    });

    test(
        'snap: a residual over 1.5 × the agreement scale re-anchors '
        'fully with residual 0', () {
      final existing = _block(100); // scale = 3 × 30 = 90; threshold 135
      final fresh = _block(300);
      final r = _merger(stepResponse: StepResponse.snap).resolve(
          fresh: fresh,
          existing: existing,
          correctedRect: fresh.absoluteRect.raw,
          wasBandFallback: false);
      expect(r.stepResponseApplied, StepResponse.snap);
      expect(r.mergedRect.top, 300);
      expect(r.residualOverride, 0.0);
    });

    test(
        'coherentShift: the baseline is the existing rect translated by '
        'the decided shift; a band admission never gets one', () {
      final existing = _block(100);
      final fresh = _block(400);
      final merger = _merger(stepResponse: StepResponse.coherentShift);
      final r = merger.resolve(
          fresh: fresh,
          existing: existing,
          correctedRect: fresh.absoluteRect.raw,
          wasBandFallback: false,
          coherentShiftTranslation: const Offset(0, 300));
      expect(r.stepResponseApplied, StepResponse.coherentShift);
      expect(r.baselineRect.top, 400);
      final band = merger.resolve(
          fresh: fresh,
          existing: existing,
          correctedRect: fresh.absoluteRect.raw,
          wasBandFallback: true,
          coherentShiftTranslation: const Offset(0, 300));
      expect(band.stepResponseApplied, isNull);
      expect(band.baselineRect.top, 100);
    });

    test(
        'agreement-weighted confidence falls on disagreement and rises on '
        'agreement; legacy saturates', () {
      final existing = _block(100, conf: 0.5, observationCount: 1);
      final agreement = _merger();
      final agree = agreement.mergedConfidence(
          _block(100), existing, _block(100).absoluteRect.raw);
      final disagree = agreement.mergedConfidence(
          _block(190), existing, _block(190).absoluteRect.raw);
      expect(agree, greaterThan(0.5));
      expect(disagree, lessThan(0.5));
      expect(
          _merger(model: PositionMergeModel.legacy).mergedConfidence(
              _block(190, conf: 0.6), existing, _block(190).absoluteRect.raw),
          1.0);
    });
  });
}
