// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// Missed-frame retention and cross-frame supersession (#46, 2.1.0),
// extracted from `StabilizationEngine.stabilize` in #150 with no
// behaviour change (differential harness byte-identical, `retention2`
// arm included). Owns the per-block miss counters, the region query
// the nested matcher shares, and the supersession coverage rule.

import '../overlap_resolver.dart';
import '../spatial_block_index.dart';
import '../track.dart';
import '../observation.dart';

/// What retention decided for one capture: the unmatched cached blocks
/// kept as match candidates, and how many cached identities left.
typedef RetentionOutcome<T> = ({List<T> retained, int dropped});

/// Keeps cached blocks that were not re-observed this capture in the
/// index as match candidates for up to [missedFrames] further calls, so
/// a single OCR miss does not reset a block's accumulated identity.
class RetentionManager<T extends Track<Object?>> {
  /// Creates a manager over the engine's [index] and [resolver].
  /// [missedFrames] (`RetentionConfig.missedFrames`) is validated `>= 0`
  /// by the engine at construction; 0 disables retention.
  RetentionManager({
    required this.missedFrames,
    required this.index,
    required this.resolver,
  });

  /// How many further captures an unmatched cached block stays matchable.
  final int missedFrames;

  /// The engine's spatial index, read for the current cached set.
  final SpatialIndexView<T> index;

  /// The engine's overlap resolver (per-script coverage threshold).
  final OverlapResolver resolver;

  /// Consecutive misses per retained block. REBUILT from the current
  /// index contents each call rather than mutated incrementally: the
  /// index is a queryable field the consumer may rebuild, clear, or
  /// remove blocks from between calls, and an incrementally-maintained
  /// map would keep strong references (and stale counts) for every
  /// instance that left the index externally. Rebuilding bounds the map
  /// to exactly the currently-retained set (PR #61 review).
  final Map<T, int> _missCounts = Map<T, int>.identity();

  /// Least share of a retained block's own area one fresh block must cover
  /// to supersede it. Script-independent on purpose: the resolver's
  /// per-script NMS threshold gives CJK-dominant text its LOOSEST value
  /// (0.35), which is right for matching jittery boxes of the same text
  /// and wrong here, where the texts differ — a sliver covering 40% of a
  /// CJK block must not evict it while an equal Latin block survives.
  static const double _kSupersessionCoverageFloor = 0.5;

  /// Cached blocks a fresh block could supersede (or nest inside): every
  /// block whose cell intersects the fresh block's RECT (plus the index's
  /// one-cell margin), not just the 3×3 cells around the fresh block's
  /// centre — a tall paragraph covers blocks whose cells sit far from its
  /// centre cell. [SpatialIndexView.candidates] is added for the
  /// viewport-relative namespace, which [SpatialIndexView.blocksInRegion]
  /// excludes. Shared with the matcher's nested-host lookup.
  Iterable<T> regionCandidates(T fresh) sync* {
    final seen = Set<T>.identity();
    for (final b in index.blocksInRegion(fresh.absoluteRect.raw)) {
      if (seen.add(b)) yield b;
    }
    for (final b in index.candidates(fresh)) {
      if (seen.add(b)) yield b;
    }
  }

  /// Cross-frame supersession test (2.1.0): does [fresh] cover enough of
  /// [cached]'s OWN area to say the cached region has been replaced?
  ///
  /// Deliberately not the smaller-area ratio `checkOverlap` uses for
  /// batch NMS: there a small fresh box inside a large cached one would
  /// score 1.0 and evict a paragraph because one of its lines was
  /// reported. The bar is [_kSupersessionCoverageFloor] (half of the
  /// cached block's own area), raised to the resolver's per-script NMS
  /// threshold only where that is stricter (short Latin snippets, 0.65).
  /// No drift margin is applied (a margin only makes eviction easier, and
  /// the fail-safe direction here is to retain). The two coordinate
  /// contracts `checkOverlap` refuses to compare are refused here too:
  /// viewport-relative vs page-absolute blocks, and blocks from different
  /// carousels.
  bool coversRetained(T fresh, T cached) {
    if (fresh.isViewportRelative != cached.isViewportRelative) return false;
    if (fresh.isHorizontalScrollChild &&
        cached.isHorizontalScrollChild &&
        fresh.scrollContext.hzScrollerIndex !=
            cached.scrollContext.hzScrollerIndex) {
      return false;
    }
    final f = fresh.absoluteRect.raw;
    final c = cached.absoluteRect.raw;
    final cachedArea = c.width * c.height;
    if (!(cachedArea > 0)) return false;
    final inter = f.intersect(c);
    if (inter.isEmpty) return false;
    final covered = inter.width * inter.height;
    final scriptThreshold = resolver.overlapThresholdFor(cached);
    final threshold = scriptThreshold > _kSupersessionCoverageFloor
        ? scriptThreshold
        : _kSupersessionCoverageFloor;
    return covered / cachedArea >= threshold;
  }

  /// Decide retention for one capture, after its matches and merges.
  ///
  /// [stableBlocks] is this capture's output so far (merged and admitted
  /// fresh blocks); [matchedExisting] the cached blocks consumed by a
  /// merge. Matched blocks are consumed (their history lives on in the
  /// merged result); expired blocks are dropped along with their miss
  /// counter. Under retention 0 nothing is retained and every unmatched
  /// cached identity counts as dropped.
  ///
  /// Cross-frame supersession (2.1.0): a cached block that was NOT
  /// matched this capture, but whose region a fresh block now covers
  /// (measured against the CACHED block's own area, so a single line
  /// reported inside a retained paragraph does not evict the paragraph),
  /// is not retained. The region has visibly changed — or the old box
  /// sat in a lagged coordinate frame — and retaining it makes a
  /// consumer of the tracked state draw the old box on top of the new
  /// one for the whole retention window. This deliberately trades
  /// identity for a clean frame: when the FRESH block is the wrongly
  /// placed one (a lagged scroll stamp), a correct retained block loses
  /// its history; the alternative is two boxes on screen. Batch-scoped
  /// NMS never sees cached blocks; this is the only cross-frame rule.
  RetentionOutcome<T> retain({
    required List<T> stableBlocks,
    required Set<T> matchedExisting,
  }) {
    final retained = <T>[];
    var droppedCount = 0;
    if (missedFrames > 0) {
      final superseded = Set<T>.identity();
      for (final fresh in stableBlocks) {
        for (final cached in regionCandidates(fresh)) {
          if (matchedExisting.contains(cached)) continue;
          if (coversRetained(fresh, cached)) superseded.add(cached);
        }
      }
      final nextMissCounts = Map<T, int>.identity();
      for (final cached in index.allBlocks) {
        if (matchedExisting.contains(cached)) continue;
        if (superseded.contains(cached)) {
          droppedCount++;
          continue;
        }
        final misses = (_missCounts[cached] ?? 0) + 1;
        if (misses <= missedFrames) {
          nextMissCounts[cached] = misses;
          retained.add(cached);
        } else {
          droppedCount++;
        }
      }
      _missCounts
        ..clear()
        ..addAll(nextMissCounts);
    } else {
      _missCounts.clear();
      // Retention 0: every cached identity nothing matched leaves the
      // index at the rebuild that follows.
      for (final cached in index.allBlocks) {
        if (!matchedExisting.contains(cached)) droppedCount++;
      }
    }
    return (retained: retained, dropped: droppedCount);
  }
}
