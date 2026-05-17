import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  group('DefaultTrackedBlock', () {
    test('minimal construction sets safe defaults', () {
      final block = DefaultTrackedBlock<int>(
        absoluteRect: const AbsoluteRect(Rect.fromLTWH(0, 0, 100, 30)),
        payload: 42,
      );

      // Payload + identity
      expect(block.payload, 42);
      expect(block.originalText, '');

      // Confidence defaults to ground truth (deterministic origin)
      expect(block.positionConfidence, PositionConfidence.groundTruth);
      expect(block.textConfidence, TextConfidence.groundTruth);

      // Critical: carouselIdVotes must be {-1: 1}, NOT {}, so the engine's
      // phantom-carousel-vote clearing logic works on first observation.
      expect(block.carouselIdVotes, {-1: 1});
      expect(block.classificationVotes, isEmpty);
      expect(block.textVotes, isEmpty);

      // Observation count starts at 1 (constructing = one observation)
      expect(block.observationCount, 1);
      expect(block.isProvisional, isFalse);
      expect(block.provisionalCapturesRemaining, 0);

      // Coordinate-space flags default to "normal page-scrolled content"
      expect(block.isViewportRelative, isFalse);
      expect(block.isInnerScrollerChild, isFalse);
      expect(block.isHorizontalScrollChild, isFalse);
      expect(block.isFromStickyElement, isFalse);
      expect(block.containerId, isNull);
    });

    test('copyWith returns same instance when no fields specified', () {
      final block = DefaultTrackedBlock<String>(
        absoluteRect: const AbsoluteRect(Rect.fromLTWH(0, 0, 100, 30)),
        payload: 'p',
        originalText: 'hello',
      );

      final clone = block.copyWith();

      expect(clone.originalText, 'hello');
      expect(clone.payload, 'p');
      expect(clone.observationCount, 1);
    });

    test('applyMerge wires MergeResult fields through copyWith', () {
      final block = DefaultTrackedBlock<String>(
        absoluteRect: const AbsoluteRect(Rect.fromLTWH(0, 0, 100, 30)),
        payload: 'p',
        originalText: 'hello',
      );

      final merge = MergeResult(
        mergedRect: const AbsoluteRect(Rect.fromLTWH(5, 5, 100, 30)),
        positionConfidence: PositionConfidence.from(0.9),
        driftCorrection: Offset.zero,
        winningOriginalText: 'goodbye',
        textConfidence: TextConfidence.from(0.8),
        updatedTextVotes: const {},
        textWasPromoted: true,
        updatedClassificationVotes: const {10: 2},
        needsReclassification: false,
        updatedCarouselIdVotes: const {-1: 2},
        observationCount: 2,
        isProvisional: false,
        provisionalCapturesRemaining: 0,
        sourceQuality: 1,
      );

      final merged = block.applyMerge(merge);

      expect(merged.originalText, 'goodbye');
      expect(merged.absoluteRect.left, 5.0);
      expect(merged.positionConfidence.raw, 0.9);
      expect(merged.textConfidence.raw, 0.8);
      expect(merged.observationCount, 2);
      expect(merged.classificationVotes, {10: 2});
      // Payload is preserved — not part of MergeResult.
      expect(merged.payload, 'p');
    });

    test('serves as a drop-in BlockMerger for StabilizationEngine', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
        merger: (existing, fresh, merge) => existing.applyMerge(merge),
      );

      final batch1 = [
        DefaultTrackedBlock<void>(
          absoluteRect: const AbsoluteRect(Rect.fromLTWH(0, 100, 200, 30)),
          payload: null,
          originalText: 'hello',
        ),
      ];
      final result1 = engine.stabilize(batch1);
      expect(result1.stableBlocks, hasLength(1));

      // Same text at jittered position should merge (re-observed).
      final batch2 = [
        DefaultTrackedBlock<void>(
          absoluteRect: const AbsoluteRect(Rect.fromLTWH(2, 102, 200, 30)),
          payload: null,
          originalText: 'hello',
        ),
      ];
      // App must rebuild the index between calls — DefaultTrackedBlock
      // doesn't change that contract.
      engine.spatialIndex.add(result1.stableBlocks.single);
      final result2 = engine.stabilize(batch2);
      expect(result2.stableBlocks, hasLength(1));
      expect(result2.stableBlocks.single.observationCount, 2);
    });
  });
}
