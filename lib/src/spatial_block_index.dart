// =============================================================================
// SPATIAL BLOCK INDEX
// =============================================================================
// Grid-cell spatial index for O(cells) overlap candidate lookup during
// deduplication.  Blocks are indexed by their absoluteRect center into
// grid cells whose dimensions adapt to the viewport.
//
// Three coordinate-space prefixes prevent cross-space false matches:
//   ""    — normal page-absolute blocks
//   "vr:" — viewport-relative (fixed/sticky) blocks
//   "ic:" — inner-scroller relative Y (for IC↔IC matching)
//
// IC blocks are dual-indexed in both page-absolute and scroller-relative
// cells to support both IC↔normal and IC↔IC comparisons.
//
// Extracted from the overlay cache layer to make spatial indexing
// independently testable and replaceable.
// =============================================================================

import 'dart:ui' show Rect;

import 'tracked_block.dart';

/// Grid-cell spatial index for fast overlap candidate lookup.
///
/// Usage:
/// ```dart
/// final index = SpatialBlockIndex<MyBlock>();
/// index.add(block);
/// for (final candidate in index.candidates(newBlock)) { ... }
/// index.remove(block);
/// index.rebuild(allBlocks);
/// ```
class SpatialBlockIndex<T extends TrackedBlock> {
  final Map<String, List<T>> _cells = {};

  // ── Adaptive bucket dimensions ──

  static const double _kBucketWidthRatio = 0.18;
  static const double _kBucketHeightRatio = 0.15;
  static const double _kBucketMin = 80.0;
  static const double _kBucketMax = 220.0;
  static const double _kBucketDefault = 200.0;

  double _bucketWidth = _kBucketDefault;
  double _bucketHeight = _kBucketDefault;

  /// Current bucket width (for testing).
  double get bucketWidth => _bucketWidth;

  /// Current bucket height (for testing).
  double get bucketHeight => _bucketHeight;

  /// Update bucket sizes based on current viewport dimensions.
  void updateBucketSizes({
    required double viewportWidth,
    required double viewportHeight,
  }) {
    _bucketWidth = (viewportWidth * _kBucketWidthRatio).clamp(
      _kBucketMin,
      _kBucketMax,
    );
    _bucketHeight = (viewportHeight * _kBucketHeightRatio).clamp(
      _kBucketMin,
      _kBucketMax,
    );
  }

  // ── Cell key generation ──

  /// Page-absolute cell key for [block], optionally offset by [dCol]/[dRow].
  String absoluteCellKey(T block, [int dCol = 0, int dRow = 0]) {
    final r = block.absoluteRect;
    final cx = ((r.left + r.width / 2) / _bucketWidth).round() + dCol;
    final cy = ((r.top + r.height / 2) / _bucketHeight).round() + dRow;
    return block.isViewportRelative ? 'vr:$cx:$cy' : '$cx:$cy';
  }

  /// IC scroller-relative cell key for [block].
  String icRelativeCellKey(T block, [int dCol = 0, int dRow = 0]) {
    final r = block.absoluteRect;
    final cx = ((r.left + r.width / 2) / _bucketWidth).round() + dCol;
    final relY = (r.top - block.innerScrollerTop) + r.height / 2;
    final cy = (relY / _bucketHeight).round() + dRow;
    return 'ic:$cx:$cy';
  }

  // ── Index operations ──

  /// Add [block] to the spatial index.
  void add(T block) {
    assert(
      block.containerId == null || block.isInnerScrollerChild,
      'TrackedBlock invariant: containerId requires isInnerScrollerChild',
    );
    final absKey = absoluteCellKey(block);
    (_cells[absKey] ??= []).add(block);
    if (block.isInnerScrollerChild) {
      final icKey = icRelativeCellKey(block);
      (_cells[icKey] ??= []).add(block);
    }
  }

  /// Remove [block] from the spatial index.
  ///
  /// Cell keys are recomputed from the block's *current* rect and flags.
  /// If those changed since [add] (a different `absoluteRect`, or a
  /// toggled IC flag), the lookup lands in a different cell and the
  /// removal silently no-ops — remove the block *before* mutating it, or
  /// use [rebuild].
  void remove(T block) {
    final absKey = absoluteCellKey(block);
    final absList = _cells[absKey];
    if (absList != null) {
      absList.remove(block);
      if (absList.isEmpty) _cells.remove(absKey);
    }
    if (block.isInnerScrollerChild) {
      final icKey = icRelativeCellKey(block);
      final icList = _cells[icKey];
      if (icList != null) {
        icList.remove(block);
        if (icList.isEmpty) _cells.remove(icKey);
      }
    }
  }

  /// Rebuild the index from scratch using [allBlocks].
  void rebuild(Iterable<T> allBlocks) {
    _cells.clear();
    for (final b in allBlocks) {
      add(b);
    }
  }

  /// Clear the entire index.
  void clear() => _cells.clear();

  /// Whether the index contains zero blocks. O(1) — checks the underlying
  /// cell map. Prefer this over `allBlocks.isEmpty`, which allocates an
  /// identity `Set` and iterates every cell.
  bool get isEmpty => _cells.isEmpty;

  /// All unique blocks in the index (identity-based dedup).
  ///
  /// Uses identity rather than value equality so that Equatable blocks
  /// stored in multiple cells (e.g. IC dual-indexed) are deduplicated by
  /// object identity, not by value — two distinct instances with identical
  /// props are both yielded.
  Iterable<T> get allBlocks sync* {
    final seen = Set<T>.identity();
    for (final cell in _cells.values) {
      for (final b in cell) {
        if (seen.add(b)) yield b;
      }
    }
  }

  /// Yield all non-VR blocks whose page-absolute grid cells overlap [region].
  ///
  /// Enumerates every cell the region spans plus a 1-cell margin, collecting
  /// unique blocks.  Used by the overlay cache layer's region-invalidation
  /// logic to find stale blocks that should be evicted when in-place DOM
  /// content changes.
  ///
  /// Blocks are indexed by their *center* cell, and the margin is fixed at
  /// one cell — a block wider or taller than ~2 cells whose center lies
  /// outside the margin can intersect [region] yet not be yielded. With
  /// viewport-derived bucket sizes this doesn't occur for normal text
  /// blocks; oversized banner-style blocks are the edge case.
  ///
  /// VR (viewport-relative) blocks live in a separate cell namespace ("vr:")
  /// and are not returned — they are unaffected by page-content mutations.
  Iterable<T> blocksInRegion(Rect region) sync* {
    final cxMin = (region.left / _bucketWidth).floor() - 1;
    final cxMax = (region.right / _bucketWidth).ceil() + 1;
    final cyMin = (region.top / _bucketHeight).floor() - 1;
    final cyMax = (region.bottom / _bucketHeight).ceil() + 1;
    final seen = <T>{};
    for (int cx = cxMin; cx <= cxMax; cx++) {
      for (int cy = cyMin; cy <= cyMax; cy++) {
        final cell = _cells['$cx:$cy'];
        if (cell != null) {
          for (final b in cell) {
            if (seen.add(b)) yield b;
          }
        }
      }
    }
  }

  /// Yield blocks in the 3×3 grid neighborhood around [block].
  /// For IC blocks, also checks the IC-relative layer for IC↔IC matches.
  ///
  /// Each block is yielded at most once. Like [allBlocks], deduplication is
  /// by object identity: dual-indexed IC blocks reachable from both their
  /// page-absolute cell and their `ic:` cell appear a single time.
  Iterable<T> candidates(T block) sync* {
    final seen = Set<T>.identity();
    for (int dc = -1; dc <= 1; dc++) {
      for (int dr = -1; dr <= 1; dr++) {
        final key = absoluteCellKey(block, dc, dr);
        final cell = _cells[key];
        if (cell != null) {
          for (final b in cell) {
            if (seen.add(b)) yield b;
          }
        }
      }
    }
    if (block.isInnerScrollerChild) {
      for (int dc = -1; dc <= 1; dc++) {
        for (int dr = -1; dr <= 1; dr++) {
          final key = icRelativeCellKey(block, dc, dr);
          final cell = _cells[key];
          if (cell != null) {
            for (final b in cell) {
              if (seen.add(b)) yield b;
            }
          }
        }
      }
    }
  }
}
