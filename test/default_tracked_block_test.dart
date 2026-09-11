// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';
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

      // 3.0 (#148): no phantom vote — the value type starts empty.
      expect(block.carouselVotes, const CarouselVotes.none());
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

    test('copyWith preserves all fields when no overrides given', () {
      final block = DefaultTrackedBlock<String>(
        absoluteRect: const AbsoluteRect(Rect.fromLTWH(0, 0, 100, 30)),
        payload: 'p',
        originalText: 'hello',
      );

      final clone = block.copyWith();

      // A fresh instance with identical field values — not the same object.
      expect(identical(clone, block), isFalse);
      expect(clone.originalText, 'hello');
      expect(clone.payload, 'p');
      expect(clone.observationCount, 1);
    });

    test('a container id without an inner scroller is unrepresentable', () {
      // 3.0 (#147): the old constructor invariant (containerId requires
      // isInnerScrollerChild) is now a property of the sealed type — the
      // only way to spell the invalid combination is the flat-flag adapter,
      // which rejects it.
      expect(
        () => CoordinateContext.fromFlags(
            containerId: const ContainerId('sidebar')),
        throwsA(isA<ArgumentError>()),
      );
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
        updatedCarouselVotes: CarouselVotes.fromHistogram({-1: 2}),
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
      // stabilize() rebuilds engine.spatialIndex internally (#13) — the
      // second call matches against batch1 with no caller-side rebuild.
      final result2 = engine.stabilize(batch2);
      expect(result2.stableBlocks, hasLength(1));
      expect(result2.stableBlocks.single.observationCount, 2);
    });
  });

  group('copyWith(coordinates:) replaces the whole frame (3.0, #147)', () {
    DefaultTrackedBlock<void> icBlock() => DefaultTrackedBlock<void>(
          absoluteRect: const AbsoluteRect(Rect.fromLTWH(0, 0, 100, 30)),
          payload: null,
          originalText: 'ic text',
          coordinates: const CoordinateContext.innerScroller(
              top: 0, containerId: ContainerId('c1')),
        );

    test('demoting an IC block is one frame swap; nothing to clear', () {
      // Before 3.0 this took `copyWith(isInnerScrollerChild: false,
      // containerId: null)` with a sentinel to tell "not passed" from
      // "clear" (#47). A frame cannot carry a container id without being
      // an inner scroller, so the demotion is the new frame itself.
      final demoted =
          icBlock().copyWith(coordinates: const CoordinateContext.page());
      expect(demoted.isInnerScrollerChild, isFalse);
      expect(demoted.containerId, isNull);
    });

    test('omitting coordinates preserves the current frame', () {
      final moved = icBlock().copyWith(
        absoluteRect: const AbsoluteRect(Rect.fromLTWH(5, 5, 100, 30)),
      );
      expect(moved.containerId, const ContainerId('c1'));
      expect(moved.isInnerScrollerChild, isTrue);
    });

    test('an inner scroller without a known container is still valid', () {
      final anonymous = icBlock()
          .copyWith(coordinates: const CoordinateContext.innerScroller(top: 0));
      expect(anonymous.containerId, isNull);
      expect(anonymous.isInnerScrollerChild, isTrue);
    });
  });
}
