// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// DIRECT BUCKET SIZES (#113 / 2.2.0)
// =============================================================================
// `updateViewport` sizes the spatial-index buckets from a viewport formula.
// A consumer whose policy is different — the reference consumer switches
// to 2× the median block height once it has enough blocks — and the replay
// rig applying a stream's recorded `meta.bk` need to set the sizes
// directly, with the same re-keying contract `updateViewport` has.
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
  group('StabilizationEngine.updateBucketSizes (#113)', () {
    test('sets both sides exactly, no clamp — the caller owns the range',
        () {
      final engine = _engine();
      engine.updateBucketSizes(bucketWidth: 37.5, bucketHeight: 410);
      expect(engine.spatialIndex.bucketWidth, 37.5);
      expect(engine.spatialIndex.bucketHeight, 410);
    });

    test('re-keys the populated index: a deep block stays matchable', () {
      // Mirror of the updateViewport re-key pin (PR #61 review): with the
      // default 200 px buckets a block at y=4000 lives in row 20; at
      // 100 px buckets it must be re-filed under row 40 or the next
      // stabilize() never finds it.
      final engine = _engine();
      engine.stabilize([_at(10, 4000, 'deep paragraph text')]);
      engine.updateBucketSizes(bucketWidth: 100, bucketHeight: 100);
      final r = engine.stabilize([_at(12, 4002, 'deep paragraph text')]);
      expect(r.stableBlocks.single.observationCount, 2,
          reason: 'the cached block must be found under the new geometry');
    });

    test('rejects non-finite and non-positive values, leaving state alone',
        () {
      final engine = _engine();
      engine.updateBucketSizes(bucketWidth: 120, bucketHeight: 130);
      for (final bad in [0.0, -1.0, double.nan, double.infinity]) {
        expect(
            () => engine.updateBucketSizes(bucketWidth: bad, bucketHeight: 130),
            throwsArgumentError,
            reason: 'width $bad');
        expect(
            () => engine.updateBucketSizes(bucketWidth: 120, bucketHeight: bad),
            throwsArgumentError,
            reason: 'height $bad');
      }
      expect(engine.spatialIndex.bucketWidth, 120);
      expect(engine.spatialIndex.bucketHeight, 130);
    });
  });

  group('SpatialBlockIndex.setBucketSizes (#113)', () {
    test('sets the sizes as given', () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<void>>();
      index.setBucketSizes(bucketWidth: 64, bucketHeight: 96);
      expect(index.bucketWidth, 64);
      expect(index.bucketHeight, 96);
    });

    test('validates before mutating', () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<void>>();
      index.setBucketSizes(bucketWidth: 64, bucketHeight: 96);
      expect(() => index.setBucketSizes(bucketWidth: 64, bucketHeight: 0),
          throwsArgumentError);
      expect(index.bucketHeight, 96);
    });
  });
}
