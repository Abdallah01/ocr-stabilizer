// =============================================================================
// SPATIAL INDEX READ-ONLY VIEW TESTS (#96)
// =============================================================================
// The engine exposes its spatial index as a read-only [SpatialIndexView];
// mutation is only reachable through a concrete [SpatialBlockIndex] the
// consumer constructed and injected themselves — the injector owns
// mutation (and the validated-construction responsibility that comes with
// it). The static type is the enforcement; these tests pin the ownership
// semantics and the view's query surface.
// =============================================================================

import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

DefaultTrackedBlock<void> _block(String text, Rect rect) =>
    DefaultTrackedBlock<void>(
      absoluteRect: AbsoluteRect(rect),
      payload: null,
      originalText: text,
    );

void main() {
  group('SpatialIndexView (#96)', () {
    test('engine.spatialIndex is the read-only view type', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
        merger: (existing, fresh, merge) => existing.applyMerge(merge),
      );
      final SpatialIndexView<DefaultTrackedBlock<void>> view =
          engine.spatialIndex;
      expect(view.isEmpty, isTrue);
    });

    test('the view answers queries over engine-stabilized blocks', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
        merger: (existing, fresh, merge) => existing.applyMerge(merge),
      );
      engine.stabilize([_block('hello', const Rect.fromLTWH(10, 100, 200, 30))]);
      expect(engine.spatialIndex.allBlocks, hasLength(1));
      expect(
        engine.spatialIndex
            .blocksInRegion(const Rect.fromLTWH(0, 50, 400, 200)),
        hasLength(1),
      );
    });

    test('an injected index stays mutable through the INJECTOR\'s reference',
        () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<void>>();
      final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
        merger: (existing, fresh, merge) => existing.applyMerge(merge),
        spatialIndex: index,
      );
      // Pre-seeding through the injector's own reference is the supported
      // fixture pattern — the engine's public surface no longer offers it.
      index.add(_block('seeded', const Rect.fromLTWH(10, 100, 200, 30)));
      expect(engine.spatialIndex.allBlocks, hasLength(1),
          reason: 'the view reflects the injected instance');
    });
  });
}
