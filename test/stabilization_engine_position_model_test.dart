import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

// =============================================================================
// POSITION MERGE MODEL (#58 / v0.7.0)
// =============================================================================
// Opt-in agreementWeighted prototype vs the preserved legacy numerics.
// =============================================================================

StabilizationEngine<DefaultTrackedBlock<void>, void> _engine(
  PositionMergeModel model,
) {
  return StabilizationEngine<DefaultTrackedBlock<void>, void>(
    merger: (existing, fresh, merge) => existing.applyMerge(merge),
    positionMergeModel: model,
  );
}

DefaultTrackedBlock<void> _at(double left, {double confidence = 0.5}) {
  return DefaultTrackedBlock<void>(
    absoluteRect: AbsoluteRect(Rect.fromLTWH(left, 100, 200, 30)),
    payload: null,
    originalText: 'stable paragraph text',
    positionConfidence: PositionConfidence.from(confidence),
    textConfidence: TextConfidence.from(confidence),
  );
}

/// Observe blocks at the given left positions; return the final block.
DefaultTrackedBlock<void> _run(
  StabilizationEngine<DefaultTrackedBlock<void>, void> engine,
  List<double> lefts,
) {
  late DefaultTrackedBlock<void> latest;
  for (final left in lefts) {
    latest = engine.stabilize([_at(left)]).stableBlocks.single;
  }
  return latest;
}

void main() {
  group('PositionMergeModel.legacy preserves 0.x numerics', () {
    test('default engine uses agreementWeighted (#74 1.0 flip)', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
        merger: (existing, fresh, merge) => existing.applyMerge(merge),
      );
      expect(engine.positionMergeModel, PositionMergeModel.agreementWeighted,
          reason: '1.0 default per the #58 validation verdict + the #74 '
              'consumer final gate (paired same-stream ab-report on two '
              'current consumer captures, 2026-07-24): equal young-block '
              'tracking, halved established-block displacement, informative '
              'confidence. legacy remains selectable for 0.x numerics.');
    });

    test('confidence saturates additively after two observations', () {
      final engine = _engine(PositionMergeModel.legacy);
      final merged = _run(engine, [10, 10]);
      // 0.5 + 0.5 clamped → 1.0 even though nothing disagrees or agrees
      // "fully" — the documented legacy saturation (#58).
      expect(merged.positionConfidence.raw, 1.0);
    });

    test('merge weight never decays: old blocks still chase jitter', () {
      final engine = _engine(PositionMergeModel.legacy);
      // 6 stable captures, then one 12px-jittered observation.
      final merged = _run(engine, [10, 10, 10, 10, 10, 10, 22]);
      // Legacy weight after saturation: fresh 0.5 / (1.0 + 0.5) = 1/3 —
      // the block moves 4px toward a single outlier despite 6 prior
      // agreeing observations.
      expect(merged.absoluteRect.left, closeTo(14.0, 0.5));
    });
  });

  group('PositionMergeModel.agreementWeighted', () {
    test('long-observed blocks become positionally sticky', () {
      final legacy = _run(
        _engine(PositionMergeModel.legacy),
        [10, 10, 10, 10, 10, 10, 22],
      );
      final agreement = _run(
        _engine(PositionMergeModel.agreementWeighted),
        [10, 10, 10, 10, 10, 10, 22],
      );
      final legacyShift = legacy.absoluteRect.left - 10.0;
      final agreementShift = agreement.absoluteRect.left - 10.0;
      expect(agreementShift, lessThan(legacyShift),
          reason: 'observation-count anchoring must damp jitter harder '
              'than the legacy confidence-ratio weight');
      expect(agreementShift, lessThan(1.5),
          reason: 'a 6-times-confirmed block should barely move for one '
              '12px outlier');
    });

    test('agreeing observations raise confidence toward 1.0', () {
      final engine = _engine(PositionMergeModel.agreementWeighted);
      final merged = _run(engine, [10, 10, 10, 10, 10]);
      // Perfect agreement each capture: running mean climbs from the
      // initial 0.5 toward 1.0 and must exceed the seed.
      expect(merged.positionConfidence.raw, greaterThan(0.8));
      expect(merged.positionConfidence.raw, lessThanOrEqualTo(1.0));
    });

    test('disagreeing observations reduce confidence', () {
      final engine = _engine(PositionMergeModel.agreementWeighted);
      // Establish agreement, then feed a far-off observation of the
      // same text (same 3×3 cell neighborhood so it still matches).
      final settled = _run(engine, [10, 10, 10]);
      final settledConf = settled.positionConfidence.raw;
      final disturbed = _run(engine, [180]);
      expect(disturbed.positionConfidence.raw, lessThan(settledConf),
          reason: 'a large residual is disagreement evidence, not '
              'saturation fuel — the legacy model would report 1.0 here');
    });

    test('confidence stays within [0, 1] across mixed sequences', () {
      final engine = _engine(PositionMergeModel.agreementWeighted);
      final merged = _run(engine, [10, 180, 10, 120, 10, 10]);
      expect(merged.positionConfidence.raw, inInclusiveRange(0.0, 1.0));
    });

    test('agreement scale is the 3x-median-height jitter allowance', () {
      final engine = _engine(PositionMergeModel.agreementWeighted);
      // Settle 3 observations at left=10: seed 0.5 -> 0.75 -> 0.8333,
      // observationCount 3, median block height 30 (fixture rect height).
      // Then observe at left=70: residual 60.
      //   scale = 3 x 30 = 90 -> agreement = 1 - 60/90 = 1/3
      //   newConf = (0.8333*3 + 1/3) / 4 = 0.7083
      // A 1x scale (30) clamps agreement to 0 and yields 0.625 instead —
      // sub-allowance jitter must degrade confidence, not zero it.
      _run(engine, [10, 10, 10]);
      final disturbed = _run(engine, [70]);
      expect(disturbed.positionConfidence.raw, closeTo(0.7083, 0.005),
          reason: 'a residual inside the jitter allowance (3x median '
              'block height) is partial agreement; the #58 sweep showed '
              '1x chases deep-chain jitter (15.8px/merge) while 3x damps '
              'it to 3.8px with confidence still regime-discriminating');
    });

    test('numeric-residue drift must not become the agreement scale', () {
      final engine = _engine(PositionMergeModel.agreementWeighted);
      // Production streams are pixel-stable but not bit-stable: coordinate
      // normalization leaves ~1e-6 px residue on re-observed rects, so the
      // region's median drift lands nonzero-tiny rather than exactly zero.
      // An exact-zero "margin established?" test then adopts that residue
      // as the agreement scale and divides noise by noise (production
      // capture: pconf decayed 1.0 → 0.34 by obsN 59 on a block that
      // never moved more than 1e-5 px).
      final lefts = [for (var k = 0; k < 12; k++) 10 + k * 2e-6];
      final merged = _run(engine, lefts);
      expect(merged.positionConfidence.raw, greaterThan(0.9),
          reason: 'a sub-quantum residual on a stationary block is perfect '
              'agreement — the agreement scale must never derive from '
              'numeric residue');
    });
  });
}
