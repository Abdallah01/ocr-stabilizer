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

    test('constructor throws on TrackedBlock invariant violation', () {
      // containerId set without isInnerScrollerChild=true violates the
      // TrackedBlock invariant — DefaultTrackedBlock throws ArgumentError
      // (not just asserts) so the check holds in release builds, where
      // a silent misclassification would corrupt drift corrections.
      expect(
        () => DefaultTrackedBlock<int>(
          absoluteRect: const AbsoluteRect(Rect.fromLTWH(0, 0, 100, 30)),
          payload: 0,
          containerId: const ContainerId('sidebar'),
          // intentionally NOT setting isInnerScrollerChild: true
        ),
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
      // stabilize() rebuilds engine.spatialIndex internally (#13) — the
      // second call matches against batch1 with no caller-side rebuild.
      final result2 = engine.stabilize(batch2);
      expect(result2.stableBlocks, hasLength(1));
      expect(result2.stableBlocks.single.observationCount, 2);
    });
  });

  group('copyWith containerId sentinel (#47 / v0.6.0)', () {
    DefaultTrackedBlock<void> icBlock() => DefaultTrackedBlock<void>(
          absoluteRect: const AbsoluteRect(Rect.fromLTWH(0, 0, 100, 30)),
          payload: null,
          originalText: 'ic text',
          isInnerScrollerChild: true,
          containerId: const ContainerId('c1'),
        );

    test('demoting an IC block clears containerId without throwing', () {
      // Pre-0.6.0: `containerId ?? this.containerId` could never restore
      // null, so this exact call threw ArgumentError from the ctor
      // invariant (containerId requires isInnerScrollerChild).
      final demoted = icBlock().copyWith(
        isInnerScrollerChild: false,
        containerId: null,
      );
      expect(demoted.isInnerScrollerChild, isFalse);
      expect(demoted.containerId, isNull);
    });

    test('omitting containerId preserves the current value', () {
      final moved = icBlock().copyWith(
        absoluteRect: const AbsoluteRect(Rect.fromLTWH(5, 5, 100, 30)),
      );
      expect(moved.containerId, const ContainerId('c1'));
      expect(moved.isInnerScrollerChild, isTrue);
    });

    test('passing a new containerId updates it', () {
      final rehomed = icBlock().copyWith(
        containerId: const ContainerId('c2'),
      );
      expect(rehomed.containerId, const ContainerId('c2'));
    });

    test('clearing containerId alone still enforces the ctor invariant', () {
      // containerId: null with isInnerScrollerChild still true is valid —
      // an IC block without a known container. The reverse (keeping the
      // container on a non-IC block) is what the constructor rejects.
      final anonymous = icBlock().copyWith(containerId: null);
      expect(anonymous.containerId, isNull);
      expect(anonymous.isInnerScrollerChild, isTrue);

      expect(
        () => icBlock().copyWith(isInnerScrollerChild: false),
        throwsArgumentError,
        reason: 'demotion without clearing containerId keeps violating '
            'the invariant and must still throw',
      );
    });
  });
}
