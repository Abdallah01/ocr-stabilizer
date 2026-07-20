import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// UNIFIED VIEWPORT ENTRY POINT + KNOB VALIDATION (#52 / v0.6.0)
// =============================================================================

StabilizationEngine<DefaultTrackedBlock<void>, void> _engine() {
  return StabilizationEngine<DefaultTrackedBlock<void>, void>(
    merger: (existing, fresh, merge) => existing.applyMerge(merge),
  );
}

void main() {
  group('updateViewport (#52)', () {
    test('fans out to the spatial index and adopts its buckets', () {
      final engine = _engine();
      engine.updateViewport(viewportWidth: 1000, viewportHeight: 800);
      // Index formula: width×0.18 / height×0.15, clamped to [80, 220].
      expect(engine.spatialIndex.bucketWidth, 180.0);
      expect(engine.spatialIndex.bucketHeight, 120.0);
      // Dedup-key buckets adopt the same values — the two quantizations
      // can no longer drift apart.
      expect(engine.bucketWidth, 180.0);
      expect(engine.bucketHeight, 120.0);
    });

    test('scale only changes when passed', () {
      final engine = _engine();
      engine.scale = 2.0;
      engine.updateViewport(viewportWidth: 1000, viewportHeight: 800);
      expect(engine.scale, 2.0);
      engine.updateViewport(
        viewportWidth: 1000,
        viewportHeight: 800,
        scale: 1.5,
      );
      expect(engine.scale, 1.5);
    });

    test('rejects non-finite and non-positive dimensions atomically', () {
      final engine = _engine();
      final before = engine.spatialIndex.bucketWidth;
      for (final bad in [double.nan, double.infinity, 0.0, -100.0]) {
        expect(
          () => engine.updateViewport(viewportWidth: bad, viewportHeight: 800),
          throwsArgumentError,
        );
        expect(
          () => engine.updateViewport(viewportWidth: 800, viewportHeight: bad),
          throwsArgumentError,
        );
        expect(
          () => engine.updateViewport(
            viewportWidth: 800,
            viewportHeight: 600,
            scale: bad,
          ),
          throwsArgumentError,
        );
      }
      expect(engine.spatialIndex.bucketWidth, before,
          reason: 'no state may change when validation fails');
    });
  });

  group('quantization knob validation (#52)', () {
    test('bucketWidth / bucketHeight / scale setters validate', () {
      final engine = _engine();
      for (final bad in [double.nan, double.infinity, 0.0, -1.0]) {
        expect(() => engine.bucketWidth = bad, throwsArgumentError);
        expect(() => engine.bucketHeight = bad, throwsArgumentError);
        expect(() => engine.scale = bad, throwsArgumentError);
      }
      // Valid writes still work.
      engine.bucketWidth = 150.0;
      engine.bucketHeight = 90.0;
      engine.scale = 1.25;
      expect(engine.bucketWidth, 150.0);
      expect(engine.bucketHeight, 90.0);
      expect(engine.scale, 1.25);
    });
  });
}
