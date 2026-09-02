// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// =============================================================================
// OTSU THRESHOLD UTILITY
// =============================================================================
// Otsu's method for automatic bimodal threshold selection.
//
// Used by paragraph gap clustering (paragraph_grouper.dart) and suitable for
// any 1-D gap-clustering problem (e.g. inline element gap detection) where
// the goal is to separate small (intra-class) from large (inter-class) gaps.
//
// Otsu's method finds the threshold that maximizes inter-class variance,
// with an explicit unimodal rejection test to avoid thresholding uniform or
// nearly-uniform distributions.
// =============================================================================

import 'robust_stats.dart';

/// Otsu's method for automatic gap thresholding.
///
/// Finds the threshold that maximally separates the inter-element/inter-block
/// gap distribution into two classes (small = kerning/line-spacing,
/// large = separator/paragraph-spacing).
///
/// [gaps] may be passed in any order: the algorithm requires ascending
/// order internally, so an already-sorted input is used as-is while an
/// unsorted input is defensively copied and sorted (the caller's list is
/// never mutated). Pre-sorting merely avoids the O(n log n) copy.
///
/// Returns `null` if:
/// - Fewer than 2 gaps provided
/// - Distribution is unimodal: `bestVariance < overallVariance * 0.2`
///
/// Otherwise returns the midpoint between the last "below" and first "above"
/// value at the optimal split point.
double? otsusThreshold(List<double> gaps) {
  final n = gaps.length;
  if (n < 2) return null;

  // ── Ordering normalization ───────────────────────────────────────────────
  // Every branch below (the all-identical first/last probe, the "max gap"
  // read of the final element, cumulative below/above sums) assumes
  // ascending order; on unsorted input they return silently wrong values
  // rather than crashing, so normalize here.
  var sortedGaps = gaps;
  for (int i = 1; i < n; i++) {
    if (sortedGaps[i - 1] > sortedGaps[i]) {
      sortedGaps = List<double>.from(gaps)..sort();
      break;
    }
  }

  // ── Small-sample guards ──────────────────────────────────────────────────
  // All gaps identical → zero variance; return gap + 1.0 to avoid degenerate
  // threshold (must check before median computation).
  if (sortedGaps.first == sortedGaps.last) return sortedGaps.first + 1.0;

  final median = RobustStats.medianOfSorted(sortedGaps)!;

  // N < 5: insufficient data for any statistical method.
  if (n < 5) return median * 1.8;

  // N < 10: histogram is too sparse for reliable Otsu bimodal detection.
  // Use a simple heuristic: if max gap ≫ median, split between them.
  if (n < 10) {
    final maxGap = sortedGaps.last;
    if (maxGap > median * 3) return (median + maxGap) / 2;
    return median * 1.8;
  }

  // ── Standard Otsu (N ≥ 10) ───────────────────────────────────────────────
  final totalSum = sortedGaps.fold<double>(0, (s, g) => s + g);
  final totalMean = totalSum / n;

  double bestVariance = 0;
  double? bestThreshold;

  double sumBelow = 0;
  int countBelow = 0;

  for (int i = 0; i < n - 1; i++) {
    countBelow++;
    sumBelow += sortedGaps[i];

    // Skip duplicates — only evaluate at class boundaries
    if (i < n - 1 && sortedGaps[i] == sortedGaps[i + 1]) continue;

    final countAbove = n - countBelow;
    if (countAbove == 0) break;

    final meanBelow = sumBelow / countBelow;
    final meanAbove = (totalSum - sumBelow) / countAbove;

    // Inter-class variance: wb * wa * (mb - ma)^2
    final wb = countBelow / n;
    final wa = countAbove / n;
    final variance =
        wb * wa * (meanBelow - meanAbove) * (meanBelow - meanAbove);

    if (variance > bestVariance) {
      bestVariance = variance;
      // Threshold at midpoint between last "below" and first "above"
      bestThreshold = (sortedGaps[i] + sortedGaps[i + 1]) / 2;
    }
  }

  // Reject if variance is negligible (unimodal distribution).
  // The 20% floor (rather than 10%) catches more false bimodals — Otsu on
  // nearly-unimodal data returns a meaningless split.
  if (bestThreshold == null) return null;
  final overallVariance = sortedGaps.fold<double>(
          0, (s, g) => s + (g - totalMean) * (g - totalMean)) /
      n;
  if (overallVariance < 1e-6 || bestVariance < overallVariance * 0.2) {
    return null;
  }
  return bestThreshold;
}

/// Convenience wrapper: returns the Otsu threshold, or [fallback] when no
/// threshold can be produced.
///
/// [fallback] is returned only when:
/// - [gaps] is empty
/// - [otsusThreshold] returns `null`, which occurs when:
///   - Fewer than 2 gaps are available
///   - The distribution is rejected as unimodal / near-uniform
///
/// Note: the small-sample heuristics return non-null values, so [fallback]
/// is NOT used in those cases. For N < 5 that is median×1.8; for 5 ≤ N < 10
/// it is `(median + maxGap) / 2` when the max gap exceeds 3× the median and
/// median×1.8 otherwise; all-identical inputs return gap+1.0.
///
/// Unlike [otsusThreshold], callers never receive `null` — making it
/// suitable for pipeline code that always needs a value. (Both functions
/// accept unsorted input; see [otsusThreshold].)
double otsusThresholdWithFallback(
  List<double> gaps, {
  required double fallback,
}) {
  if (gaps.isEmpty) return fallback;
  return otsusThreshold(gaps) ?? fallback;
}
