// ignore_for_file: unused_element_parameter

import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// SPATIAL BLOCK INDEX TESTS
// =============================================================================

/// Minimal test block for package-level SpatialBlockIndex tests.
class _TestBlock implements TrackedBlock<Never> {
  @override
  final AbsoluteRect absoluteRect;
  @override
  final bool isViewportRelative;
  @override
  final bool isInnerScrollerChild;
  @override
  final double innerScrollerTop;
  @override
  final ContainerId? containerId;
  @override
  final bool isHorizontalScrollChild;
  @override
  Never get payload => throw UnsupportedError('_TestBlock has no payload');

  // Tier A identity/coordinate fields
  @override
  final String originalText;
  final double captureScrollY;
  final double captureScrollX;
  final int hzScrollerIndex;
  @override
  final bool isFromStickyElement;
  final double stickyFallbackScrollY;
  final double stickyFallbackScrollX;
  final bool stickyFallbackIsIc;
  final int stickyFallbackHzIndex;
  @override
  final double positionConfidence;
  @override
  final double textConfidence;
  @override
  final int sourceQuality;

  _TestBlock({
    required this.absoluteRect,
    this.isViewportRelative = false,
    this.isInnerScrollerChild = false,
    this.innerScrollerTop = 0,
    this.containerId,
    this.isHorizontalScrollChild = false,
    this.originalText = '',
    this.captureScrollY = 0,
    this.captureScrollX = 0,
    this.hzScrollerIndex = -1,
    this.isFromStickyElement = false,
    this.stickyFallbackScrollY = 0,
    this.stickyFallbackScrollX = 0,
    this.stickyFallbackIsIc = false,
    this.stickyFallbackHzIndex = -1,
    this.positionConfidence = 0.5,
    this.textConfidence = 0.5,
    this.sourceQuality = 0,
  });

  @override
  ScrollContext get scrollContext => ScrollContext(
    scrollY: captureScrollY,
    scrollX: captureScrollX,
    hzScrollerIndex: hzScrollerIndex,
  );

  @override
  StickyFallback get stickyFallback => StickyFallback(
    scrollY: stickyFallbackScrollY,
    scrollX: stickyFallbackScrollX,
    isIc: stickyFallbackIsIc,
    hzScrollerIndex: stickyFallbackHzIndex,
  );
}

_TestBlock _makeBlock({
  required double left,
  required double top,
  double width = 200,
  double height = 20,
  bool isViewportRelative = false,
  bool isInnerScrollerChild = false,
  double innerScrollerTop = 0,
  ContainerId? containerId,
}) {
  return _TestBlock(
    absoluteRect: AbsoluteRect.fromLTWH(left, top, width, height),
    isViewportRelative: isViewportRelative,
    isInnerScrollerChild: isInnerScrollerChild,
    innerScrollerTop: innerScrollerTop,
    containerId: containerId,
  );
}

void main() {
  group('SpatialBlockIndex', () {
    // ┌─────────────────────────────────────────────────────────────────
    // Add / Candidates
    // ┌─────────────────────────────────────────────────────────────────

    test('added block appears in its own candidates', () {
      final index = SpatialBlockIndex<_TestBlock>();
      final block = _makeBlock(left: 100, top: 100);

      index.add(block);
      final candidates = index.candidates(block).toList();

      expect(candidates, contains(block));
    });

    test('nearby block appears in candidates', () {
      final index = SpatialBlockIndex<_TestBlock>();
      // Set bucket sizes: width = 200, height = 200
      index.updateBucketSizes(viewportWidth: 1000, viewportHeight: 1000);

      final block1 = _makeBlock(left: 100, top: 100);
      final block2 = _makeBlock(left: 250, top: 150); // Within neighboring cell

      index.add(block1);
      index.add(block2);

      final candidates = index.candidates(block1).toList();
      expect(candidates, contains(block2));
    });

    test('distant block does NOT appear in candidates', () {
      final index = SpatialBlockIndex<_TestBlock>();
      index.updateBucketSizes(viewportWidth: 1000, viewportHeight: 1000);

      final block1 = _makeBlock(left: 100, top: 100);
      final block2 = _makeBlock(left: 1000, top: 1000); // Far away

      index.add(block1);
      index.add(block2);

      final candidates = index.candidates(block1).toList();
      expect(candidates, isNot(contains(block2)));
    });

    // ┌─────────────────────────────────────────────────────────────────
    // Remove
    // ┌─────────────────────────────────────────────────────────────────

    test('removed block no longer appears in candidates', () {
      final index = SpatialBlockIndex<_TestBlock>();
      final block = _makeBlock(left: 100, top: 100);

      index.add(block);
      expect(index.candidates(block).toList(), contains(block));

      index.remove(block);
      expect(index.candidates(block).toList(), isNot(contains(block)));
    });

    // ┌─────────────────────────────────────────────────────────────────
    // Rebuild
    // ┌─────────────────────────────────────────────────────────────────

    test('rebuild replaces entire index', () {
      final index = SpatialBlockIndex<_TestBlock>();
      final block1 = _makeBlock(left: 100, top: 100);
      final block2 = _makeBlock(left: 200, top: 200);
      final block3 = _makeBlock(left: 300, top: 300);

      index.add(block1);
      index.add(block2);

      // Rebuild with block3 only
      index.rebuild([block3]);

      final candidates = index.candidates(block3).toList();
      expect(candidates, contains(block3));
      expect(candidates, isNot(contains(block1)));
      expect(candidates, isNot(contains(block2)));
    });

    // ┌─────────────────────────────────────────────────────────────────
    // Clear
    // ┌─────────────────────────────────────────────────────────────────

    test('clear empties the index', () {
      final index = SpatialBlockIndex<_TestBlock>();
      final block = _makeBlock(left: 100, top: 100);

      index.add(block);
      expect(index.candidates(block).toList(), contains(block));

      index.clear();
      expect(index.candidates(block).toList(), isEmpty);
    });

    // ┌─────────────────────────────────────────────────────────────────
    // VR Namespace Isolation
    // ┌─────────────────────────────────────────────────────────────────

    test('VR blocks do not appear in blocksInRegion', () {
      final index = SpatialBlockIndex<_TestBlock>();
      final normalBlock = _makeBlock(left: 100, top: 100);
      final vrBlock = _makeBlock(left: 100, top: 100, isViewportRelative: true);

      index.add(normalBlock);
      index.add(vrBlock);

      final region = Rect.fromLTWH(0, 0, 500, 500);
      final blocks = index.blocksInRegion(region).toList();

      expect(blocks, contains(normalBlock));
      expect(blocks, isNot(contains(vrBlock)));
    });

    test('VR and normal blocks at same position have different cell keys', () {
      final index = SpatialBlockIndex<_TestBlock>();
      final normalBlock = _makeBlock(left: 100, top: 100);
      final vrBlock = _makeBlock(left: 100, top: 100, isViewportRelative: true);

      final normalKey = index.absoluteCellKey(normalBlock);
      final vrKey = index.absoluteCellKey(vrBlock);

      expect(normalKey, isNot(equals(vrKey)));
      expect(vrKey, startsWith('vr:'));
      expect(normalKey, isNot(startsWith('vr:')));
    });

    // ┌─────────────────────────────────────────────────────────────────
    // IC Dual Indexing
    // ┌─────────────────────────────────────────────────────────────────

    test(
      'IC blocks are findable via both page-absolute and IC-relative candidates',
      () {
        final index = SpatialBlockIndex<_TestBlock>();
        index.updateBucketSizes(viewportWidth: 1000, viewportHeight: 1000);

        final icBlock = _makeBlock(
          left: 100,
          top: 200,
          isInnerScrollerChild: true,
          innerScrollerTop: 150,
        );

        index.add(icBlock);

        // Create query blocks: one for page-absolute matching, one for IC-relative
        final pageAbsoluteQuery = _makeBlock(left: 150, top: 210);
        final icRelativeQuery = _makeBlock(
          left: 150,
          top: 210,
          isInnerScrollerChild: true,
          innerScrollerTop: 150,
        );

        final pageCandidates = index.candidates(pageAbsoluteQuery).toList();
        final icCandidates = index.candidates(icRelativeQuery).toList();

        // IC block should appear in both
        expect(pageCandidates, contains(icBlock));
        expect(icCandidates, contains(icBlock));
      },
    );

    test('IC remove cleans both cells', () {
      final index = SpatialBlockIndex<_TestBlock>();
      final icBlock = _makeBlock(
        left: 100,
        top: 200,
        isInnerScrollerChild: true,
        innerScrollerTop: 150,
      );

      index.add(icBlock);

      // Verify both keys were populated
      final absKey = index.absoluteCellKey(icBlock);
      final icKey = index.icRelativeCellKey(icBlock);
      expect(absKey, isNot(equals(icKey)));

      // Remove and verify both are cleaned
      index.remove(icBlock);

      final absQuery = _makeBlock(left: 100, top: 200);
      final icQuery = _makeBlock(
        left: 100,
        top: 200,
        isInnerScrollerChild: true,
        innerScrollerTop: 150,
      );

      expect(index.candidates(absQuery).toList(), isNot(contains(icBlock)));
      expect(index.candidates(icQuery).toList(), isNot(contains(icBlock)));
    });

    // ┌─────────────────────────────────────────────────────────────────
    // Adaptive Bucket Sizing
    // ┌─────────────────────────────────────────────────────────────────

    test('updateBucketSizes computes from viewport ratios with clamping', () {
      final index = SpatialBlockIndex<_TestBlock>();

      // Normal viewport (1000×1000)
      // Expected: 1000 * 0.18 = 180 (within 80-220), 1000 * 0.15 = 150
      index.updateBucketSizes(viewportWidth: 1000, viewportHeight: 1000);
      expect(index.bucketWidth, closeTo(180, 0.1));
      expect(index.bucketHeight, closeTo(150, 0.1));
    });

    test('updateBucketSizes clamps tiny viewport to minimum', () {
      final index = SpatialBlockIndex<_TestBlock>();

      // Tiny viewport (100×100)
      // Expected: 100 * 0.18 = 18, clamped to min 80
      index.updateBucketSizes(viewportWidth: 100, viewportHeight: 100);
      expect(index.bucketWidth, equals(80));
      expect(index.bucketHeight, equals(80));
    });

    test('updateBucketSizes clamps huge viewport to maximum', () {
      final index = SpatialBlockIndex<_TestBlock>();

      // Huge viewport (2000×2000)
      // Expected: 2000 * 0.18 = 360, clamped to max 220; 2000 * 0.15 = 300, clamped
      index.updateBucketSizes(viewportWidth: 2000, viewportHeight: 2000);
      expect(index.bucketWidth, equals(220));
      expect(index.bucketHeight, equals(220));
    });

    // ┌─────────────────────────────────────────────────────────────────
    // blocksInRegion
    // ┌─────────────────────────────────────────────────────────────────

    test('blocksInRegion returns blocks overlapping query rect', () {
      final index = SpatialBlockIndex<_TestBlock>();
      index.updateBucketSizes(viewportWidth: 1000, viewportHeight: 1000);

      final block1 = _makeBlock(left: 100, top: 100);
      final block2 = _makeBlock(left: 300, top: 300);

      index.add(block1);
      index.add(block2);

      final region = Rect.fromLTWH(50, 50, 300, 300); // Overlaps block1
      final blocks = index.blocksInRegion(region).toList();

      expect(blocks, contains(block1));
    });

    test('blocksInRegion excludes distant blocks', () {
      final index = SpatialBlockIndex<_TestBlock>();
      index.updateBucketSizes(viewportWidth: 1000, viewportHeight: 1000);

      final block1 = _makeBlock(left: 100, top: 100);
      final block2 = _makeBlock(left: 1000, top: 1000);

      index.add(block1);
      index.add(block2);

      final region = Rect.fromLTWH(50, 50, 200, 200);
      final blocks = index.blocksInRegion(region).toList();

      expect(blocks, contains(block1));
      expect(blocks, isNot(contains(block2)));
    });

    test('blocksInRegion deduplicates', () {
      final index = SpatialBlockIndex<_TestBlock>();
      index.updateBucketSizes(viewportWidth: 1000, viewportHeight: 1000);

      final block = _makeBlock(left: 100, top: 100);
      index.add(block);

      // Query a region that spans multiple cells, overlapping the same block
      final region = Rect.fromLTWH(50, 50, 300, 300);
      final blocks = index.blocksInRegion(region).toList();

      expect(blocks.where((b) => b == block).length, equals(1));
    });

    // ┌─────────────────────────────────────────────────────────────────
    // Cell Key Generation
    // ┌─────────────────────────────────────────────────────────────────

    test('icRelativeCellKey uses scroller-relative Y', () {
      final index = SpatialBlockIndex<_TestBlock>();
      index.updateBucketSizes(viewportWidth: 1000, viewportHeight: 1000);

      final icBlock = _makeBlock(
        left: 100,
        top: 300,
        isInnerScrollerChild: true,
        innerScrollerTop: 100, // scroller top
      );

      final icKey = index.icRelativeCellKey(icBlock);

      // relY = (300 - 100) + 20/2 = 210
      // cy = 210 / 150 = 1.4 rounded to 1
      // cx = (100 + 200/2) / 180 = 200 / 180 = 1.1 rounded to 1
      expect(icKey, startsWith('ic:'));
      expect(icKey, contains(':'));

      // Verify it differs from absolute key for same block
      final absKey = index.absoluteCellKey(icBlock);
      expect(icKey, isNot(equals(absKey)));
    });

    test('absoluteCellKey with offset shifts coordinates', () {
      final index = SpatialBlockIndex<_TestBlock>();
      index.updateBucketSizes(viewportWidth: 1000, viewportHeight: 1000);

      final block = _makeBlock(left: 100, top: 100);

      final key0 = index.absoluteCellKey(block);
      final key1dCol = index.absoluteCellKey(block, 1, 0);
      final key0dRow = index.absoluteCellKey(block, 0, 1);

      // All should be different
      expect(key0, isNot(equals(key1dCol)));
      expect(key0, isNot(equals(key0dRow)));
      expect(key1dCol, isNot(equals(key0dRow)));
    });

    // ┌─────────────────────────────────────────────────────────────────
    // Integration Tests
    // ┌─────────────────────────────────────────────────────────────────

    test('multiple candidates from 3x3 neighborhood', () {
      final index = SpatialBlockIndex<_TestBlock>();
      index.updateBucketSizes(viewportWidth: 1000, viewportHeight: 1000);

      final center = _makeBlock(left: 100, top: 100);
      final adjacent1 = _makeBlock(left: 150, top: 150);
      final adjacent2 = _makeBlock(left: 250, top: 250);

      index.add(center);
      index.add(adjacent1);
      index.add(adjacent2);

      final candidates = index.candidates(center).toList();

      // All should be in candidates (3x3 neighborhood)
      expect(candidates, contains(center));
      expect(candidates, contains(adjacent1));
      expect(candidates, contains(adjacent2));
    });

    test('rebuild with mixed normal and IC blocks', () {
      final index = SpatialBlockIndex<_TestBlock>();
      index.updateBucketSizes(viewportWidth: 1000, viewportHeight: 1000);

      final normalBlock = _makeBlock(left: 100, top: 100);
      final icBlock = _makeBlock(
        left: 200,
        top: 200,
        isInnerScrollerChild: true,
        innerScrollerTop: 150,
      );
      final vrBlock = _makeBlock(left: 300, top: 300, isViewportRelative: true);

      index.rebuild([normalBlock, icBlock, vrBlock]);

      // All should be queryable from their own perspective
      expect(index.candidates(normalBlock).toList(), contains(normalBlock));
      expect(index.candidates(icBlock).toList(), contains(icBlock));
      expect(index.candidates(vrBlock).toList(), contains(vrBlock));
    });

    test('remove and re-add block', () {
      final index = SpatialBlockIndex<_TestBlock>();
      final block = _makeBlock(left: 100, top: 100);

      index.add(block);
      expect(index.candidates(block).toList(), contains(block));

      index.remove(block);
      expect(index.candidates(block).toList(), isEmpty);

      index.add(block);
      expect(index.candidates(block).toList(), contains(block));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Empty Index Edge Cases                                              │
    // └─────────────────────────────────────────────────────────────────────┘

    test('candidates on empty index returns empty iterable', () {
      final index = SpatialBlockIndex<_TestBlock>();
      final block = _makeBlock(left: 100, top: 100);
      expect(index.candidates(block).toList(), isEmpty);
    });

    test('blocksInRegion on empty index returns empty iterable', () {
      final index = SpatialBlockIndex<_TestBlock>();
      final results = index
          .blocksInRegion(const Rect.fromLTWH(0, 0, 500, 500))
          .toList();
      expect(results, isEmpty);
    });

    test('remove on empty index does not throw', () {
      final index = SpatialBlockIndex<_TestBlock>();
      final block = _makeBlock(left: 100, top: 100);
      expect(() => index.remove(block), returnsNormally);
    });
  });
}
