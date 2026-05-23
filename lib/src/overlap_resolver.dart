// ============================================================================
// OVERLAP RESOLVER
// ============================================================================
// Pure spatial overlap detection and NMS (non-maximum suppression) resolution
// for the block deduplication pipeline.  Extracted from OverlayCacheService
// for independent testability and swappability.
//
// All methods are pure: they take blocks and parameters, return results,
// and have zero side effects.
// ============================================================================

import 'dart:math' show max, min;

import 'hierarchy_weight.dart';
import 'text_dedup_utils.dart';
import 'tracked_block.dart';
import 'types/absolute_rect.dart';

/// Result of resolving a spatial overlap between two blocks.
enum OverlapResult {
  /// Incoming block replaces the existing block.
  evict,

  /// Incoming block is dropped (existing block kept).
  drop,

  /// Both blocks kept (no conflict — existing is stability-biased).
  keep,
}

/// Pure spatial overlap detection and NMS resolution for block deduplication.
///
/// Usage:
///   final resolver = OverlapResolver();
///   final match = resolver.checkOverlap(newBlock, nr, existing, threshold, dm);
///   if (match != null) {
///     final result = resolver.resolveOverlap(incoming: newBlock, existing: match, ...);
///   }
class OverlapResolver {
  /// Creates a const overlap resolver.
  const OverlapResolver();

  // ── Overlap thresholds (language-aware) ────────────────────────────

  /// CJK-dominant blocks (≥60% CJK chars): looser threshold.
  static const double kCjkOverlapThreshold = 0.35;

  /// Short Latin-dominant blocks (<30% CJK, ≤8 runes): stricter threshold.
  static const double kShortLatinOverlapThreshold = 0.65;

  /// Default overlap threshold (mixed content or longer Latin text).
  static const double kDefaultOverlapThreshold = 0.50;

  /// Area ratio above which an existing block is considered a "giant squatter".
  static const double kGiantAreaRatioFallback = 3.0;

  // ── Threshold selection ────────────────────────────────────────────

  /// Select overlap threshold based on block script composition.
  double overlapThresholdFor(TrackedBlock block) {
    final fraction = TextDedupUtils.cjkFraction(block.originalText);
    if (fraction >= 0.6) return kCjkOverlapThreshold;
    if (fraction < 0.3 && block.originalText.runes.length <= 8) {
      return kShortLatinOverlapThreshold;
    }
    return kDefaultOverlapThreshold;
  }

  // ── Overlap detection ──────────────────────────────────────────────

  /// Check whether [existing] overlaps [newBlock] above [threshold],
  /// accounting for drift margin [dm].
  ///
  /// Returns [existing] on match, null otherwise.
  T? checkOverlap<T extends TrackedBlock>(
    T newBlock,
    AbsoluteRect nr,
    T existing,
    double threshold,
    double dm,
  ) {
    // VR and non-VR use different coordinate contracts.
    if (existing.isViewportRelative != newBlock.isViewportRelative) {
      return null;
    }
    // Blocks in different carousels should never overlap-match.
    if (existing.isHorizontalScrollChild &&
        newBlock.isHorizontalScrollChild &&
        existing.scrollContext.hzScrollerIndex !=
            newBlock.scrollContext.hzScrollerIndex) {
      return null;
    }

    final er = existing.absoluteRect;

    // Inner-scroller children: use scroller-relative Y to avoid
    // vvPageTop drift causing false misses.
    final double nTop, nBottom, eTop, eBottom;
    if (newBlock.isInnerScrollerChild && existing.isInnerScrollerChild) {
      nTop = nr.top - newBlock.innerScrollerTop;
      nBottom = nr.bottom - newBlock.innerScrollerTop;
      eTop = er.top - existing.innerScrollerTop;
      eBottom = er.bottom - existing.innerScrollerTop;
    } else {
      nTop = nr.top;
      nBottom = nr.bottom;
      eTop = er.top;
      eBottom = er.bottom;
    }

    final nHeight = nBottom - nTop;
    final eHeight = eBottom - eTop;

    final nCenterY = nTop + nHeight / 2;
    final eCenterY = eTop + eHeight / 2;
    final nCenterX = nr.left + nr.width / 2;
    final eCenterX = er.left + er.width / 2;

    if ((nCenterY - eCenterY).abs() >= (nHeight + eHeight) / 2 + dm ||
        (nCenterX - eCenterX).abs() >= (nr.width + er.width) / 2 + dm) {
      return null;
    }

    final oLeft = max(nr.left - dm, er.left);
    final oTop = max(nTop - dm, eTop);
    final oRight = min(nr.right + dm, er.right);
    final oBottom = min(nBottom + dm, eBottom);

    if (oLeft >= oRight || oTop >= oBottom) return null;

    final overlapArea = (oRight - oLeft) * (oBottom - oTop);
    final smallerArea = min(nr.width * nHeight, er.width * eHeight);

    if (smallerArea > 0 && overlapArea / smallerArea >= threshold) {
      return existing;
    }
    return null;
  }

  // ── Overlap ratio ──────────────────────────────────────────────────

  /// Compute overlap ratio between two blocks (0.0–1.0) relative to the
  /// smaller block's area.  Uses drift margin [dm] for consistency with
  /// [checkOverlap].
  double overlapRatio(TrackedBlock a, TrackedBlock b, double dm) {
    final ar = a.absoluteRect;
    final br = b.absoluteRect;
    final double aTop, aBottom, bTop, bBottom;
    if (a.isInnerScrollerChild && b.isInnerScrollerChild) {
      aTop = ar.top - a.innerScrollerTop;
      aBottom = ar.bottom - a.innerScrollerTop;
      bTop = br.top - b.innerScrollerTop;
      bBottom = br.bottom - b.innerScrollerTop;
    } else {
      aTop = ar.top;
      aBottom = ar.bottom;
      bTop = br.top;
      bBottom = br.bottom;
    }
    final oLeft = max(ar.left - dm, br.left);
    final oTop = max(aTop - dm, bTop);
    final oRight = min(ar.right + dm, br.right);
    final oBottom = min(aBottom + dm, bBottom);
    if (oLeft >= oRight || oTop >= oBottom) return 0.0;
    final overlapArea = (oRight - oLeft) * (oBottom - oTop);
    final aHeight = aBottom - aTop;
    final bHeight = bBottom - bTop;
    final smallerArea = min(ar.width * aHeight, br.width * bHeight);
    return smallerArea > 0 ? (overlapArea / smallerArea).clamp(0.0, 1.0) : 0.0;
  }

  // ── Quality score ─────────────────────────────────────────────────

  /// Combined quality score: text confidence weighted higher than position
  /// confidence because a bad translation is worse than slight position jitter.
  ///
  /// NaN-on-input is a logic bug — the production guard is
  /// [StabilizationEngine.stabilize]'s entry validation (#27).
  /// This assert is the developer-facing safety net in debug builds;
  /// release builds strip it for zero overhead.
  static double qualityScore(TrackedBlock block) {
    final pos = block.positionConfidence.raw;
    final txt = block.textConfidence.raw;
    assert(!pos.isNaN && !txt.isNaN,
        'qualityScore reached with NaN confidence — '
        'engine-entry validation should have caught this.');
    return pos * 0.4 + txt * 0.6;
  }

  // ── NMS Resolution ─────────────────────────────────────────────────

  /// Resolve a spatial overlap between [incoming] and [existing].
  ///
  /// Strategies (checked in priority order):
  /// A. **Hierarchy weight** — higher-classified type wins instantly.
  /// B. **David and Goliath** — smaller focused block evicts giant squatter.
  /// C. **Quality + overlap ratio** — standard tiered NMS comparison.
  OverlapResult resolveOverlap({
    required TrackedBlock incoming,
    required TrackedBlock existing,
    required double driftMargin,
    required double confidenceMad,
    double? giantAreaFence,
  }) {
    final newWeight = incoming.hierarchyWeight;
    final existingWeight = existing.hierarchyWeight;

    // ── A. Hierarchy weight mismatch ──
    if (newWeight > existingWeight) return OverlapResult.evict;
    if (newWeight < existingWeight) return OverlapResult.drop;

    // ── B. David and Goliath (equal weight, area mismatch) ──
    final existingArea =
        existing.absoluteRect.width * existing.absoluteRect.height;
    final incomingArea =
        incoming.absoluteRect.width * incoming.absoluteRect.height;
    final incomingQuality = qualityScore(incoming);
    final existingQuality = qualityScore(existing);
    if (incomingArea > 0 && incomingQuality >= existingQuality) {
      final isGiant =
          (giantAreaFence != null && existingArea > giantAreaFence) ||
          existingArea > incomingArea * kGiantAreaRatioFallback;
      if (isGiant) return OverlapResult.evict;
    }

    // ── C. Standard quality + overlap ratio ──
    final ratio = overlapRatio(incoming, existing, driftMargin);
    final qualityMargin = ratio >= 0.70 ? 0.0 : confidenceMad;
    if (incomingQuality >= existingQuality + qualityMargin) {
      return OverlapResult.evict;
    }

    return OverlapResult.keep;
  }
}
