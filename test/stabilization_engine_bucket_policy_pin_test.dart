// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// BUCKET SIZES: SELF RE-KEY + POLICY PIN (#113, PR #114 review)
// =============================================================================
// Two P1s from the 2.2.0 review. (1) `SpatialBlockIndex.setBucketSizes`
// carried a prose-only "callers must rebuild afterwards" contract on a
// public, exported mutator — the index now re-keys its own blocks whenever
// its sizes change, by construction. (2) `updateViewport` re-derived the
// sizes from the viewport formula unconditionally, silently reverting a
// consumer's non-formula policy on the next rotation — `updateBucketSizes`
// now pins the sizes until `updateViewport(resetBucketPolicy: true)`.
// =============================================================================

DefaultTrackedBlock<void> _at(double left, double top, String text) =>
    DefaultTrackedBlock<void>(
      absoluteRect: AbsoluteRect(Rect.fromLTWH(left, top, 200, 30)),
      payload: null,
      originalText: text,
    );

StabilizationEngine<DefaultTrackedBlock<void>, void> _engine() =>
    StabilizationEngine<DefaultTrackedBlock<void>, void>(
      merger: (existing, fresh, merge) => existing.applyMerge(merge),
    );

void main() {
  group('SpatialBlockIndex re-keys itself on a size change', () {
    test('setBucketSizes: a deep block stays findable with NO rebuild call',
        () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<void>>();
      final deep = _at(10, 4000, 'deep paragraph text');
      index.add(deep); // filed under the default 200 px cells (row 20)
      index.setBucketSizes(bucketWidth: 100, bucketHeight: 100);
      expect(index.candidates(_at(12, 4002, 'deep paragraph text')),
          contains(deep),
          reason: 'row 40 under the new geometry — the index must have '
              're-filed it itself');
      expect(index.allBlocks, hasLength(1));
    });

    test('updateBucketSizes (viewport formula) re-keys the same way', () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<void>>();
      final deep = _at(10, 4000, 'deep paragraph text');
      index.add(deep);
      index.updateBucketSizes(viewportWidth: 360, viewportHeight: 587);
      expect(index.candidates(_at(12, 4002, 'deep paragraph text')),
          contains(deep));
    });
  });

  group('updateBucketSizes pins the sizes against updateViewport', () {
    test('a later updateViewport keeps the pinned sizes', () {
      final engine = _engine();
      engine.updateBucketSizes(bucketWidth: 100, bucketHeight: 100);
      expect(engine.bucketsPinned, isTrue);
      engine.updateViewport(viewportWidth: 360, viewportHeight: 587);
      expect(engine.spatialIndex.bucketWidth, 100,
          reason: 'the consumer\'s policy is not the viewport formula; a '
              'rotation must not revert it');
      expect(engine.spatialIndex.bucketHeight, 100);
      expect(engine.bucketWidth, 100, reason: 'dedup keys follow the index');
    });

    test('resetBucketPolicy returns to the formula — the same sizes a '
        'never-pinned engine derives', () {
      final reference = _engine()
        ..updateViewport(viewportWidth: 360, viewportHeight: 587);
      final engine = _engine();
      engine.updateBucketSizes(bucketWidth: 100, bucketHeight: 100);
      engine.updateViewport(
          viewportWidth: 360, viewportHeight: 587, resetBucketPolicy: true);
      expect(engine.bucketsPinned, isFalse);
      expect(engine.spatialIndex.bucketWidth,
          reference.spatialIndex.bucketWidth);
      expect(engine.spatialIndex.bucketHeight,
          reference.spatialIndex.bucketHeight);
    });

    test('a pinned engine still re-keys through the pin (blocks stay '
        'matchable across the ignored viewport update)', () {
      final engine = _engine();
      engine.stabilize([_at(10, 4000, 'deep paragraph text')]);
      engine.updateBucketSizes(bucketWidth: 100, bucketHeight: 100);
      engine.updateViewport(viewportWidth: 360, viewportHeight: 587);
      final r = engine.stabilize([_at(12, 4002, 'deep paragraph text')]);
      expect(r.stableBlocks.single.observationCount, 2);
    });
  });
}
