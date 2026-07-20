// TUKEY IQR OUTLIER DETECTION
// ============================================================================
// Implements Tukey's fence (1977) for data-driven outlier detection.
// Used to replace hardcoded pixel thresholds in OCR classification and caching.

import 'robust_stats.dart';

/// Tukey's fence (1977) IQR-based outlier detection.
///
/// Provides statistical methods for identifying anomalous values in a
/// distribution without manual threshold tuning.
class IqrOutlier {
  IqrOutlier._();

  /// Returns both lower and upper Tukey fences as a record.
  ///
  /// Lower fence: `Q1 - k × IQR`. Upper fence: `Q3 + k × IQR`.
  ///
  /// Returns `null` if [values] has fewer than [minSamples] entries, or if all
  /// values are identical (IQR and range both zero — no outliers possible).
  ///
  /// When [k] is `null` (the default), an adaptive multiplier is used:
  /// - N < 15 → k = 2.2 (Hoaglin & Iglewicz, 1987; less aggressive for small samples)
  /// - N ≥ 15 → k = 1.5 (standard Tukey fence)
  ///
  /// When IQR = 0 (≥50% of values are identical), a synthetic spread of
  /// `(max − min) / 4` is used instead. If that is also zero, returns `null`.
  ///
  /// **Formula:**
  /// ```
  /// Q1 = median of lower half
  /// Q3 = median of upper half
  /// IQR = Q3 - Q1
  /// Lower Fence = Q1 - k × IQR
  /// Upper Fence = Q3 + k × IQR
  /// ```
  static ({double lower, double upper})? fences(
    List<double> values, {
    double? k,
    int minSamples = 4,
  }) {
    if (values.length < (minSamples < 2 ? 2 : minSamples)) return null;

    final sorted = List<double>.from(values)..sort();
    final n = sorted.length;

    // Adaptive k: wider fences for small samples to reduce false positives.
    final effectiveK = k ?? (n < 15 ? 2.2 : 1.5);

    // Compute Q1 and Q3 using median-of-halves (exclusive median method).
    // Split sorted list into lower and upper halves, take median of each.
    final mid = n ~/ 2;
    final lower = sorted.sublist(0, mid);
    final upper = sorted.sublist(n.isEven ? mid : mid + 1);
    final q1 = RobustStats.medianOfSorted(lower)!;
    final q3 = RobustStats.medianOfSorted(upper)!;
    final iqr = q3 - q1;

    if (iqr == 0) {
      // Synthetic spread from range when IQR is zero (≥50% identical values).
      final syntheticSpread = (sorted.last - sorted.first) / 4;
      if (syntheticSpread <= 0) return null; // All identical — no outliers.
      return (
        lower: q1 - effectiveK * syntheticSpread,
        upper: q3 + effectiveK * syntheticSpread,
      );
    }

    return (lower: q1 - effectiveK * iqr, upper: q3 + effectiveK * iqr);
  }

  /// Compute the upper fence: Q3 + k × IQR.
  ///
  /// Returns `null` if [values] has fewer than [minSamples] entries, or if all
  /// values are identical (IQR and range both zero — no outliers possible).
  ///
  /// When [k] is `null` (the default), an adaptive multiplier is used:
  /// - N < 15 → k = 2.2 (Hoaglin & Iglewicz, 1987; less aggressive for small samples)
  /// - N ≥ 15 → k = 1.5 (standard Tukey fence)
  ///
  /// When IQR = 0 (≥50% of values are identical), a synthetic spread of
  /// `(max − min) / 4` is used instead. If that is also zero, returns `null`.
  ///
  /// **Example:**
  /// ```dart
  /// final heights = [100.0, 102.0, 105.0, 108.0, 110.0, 112.0, 115.0, 1000.0];
  /// final fence = IqrOutlier.upperFence(heights); // needs ≥4 samples
  /// // fence = 135.5 (adaptive k = 2.2 at N < 15); 1000.0 > fence → outlier
  /// ```
  static double? upperFence(
    List<double> values, {
    double? k,
    int minSamples = 4,
  }) {
    final result = fences(values, k: k, minSamples: minSamples);
    return result?.upper;
  }

  /// Returns `true` if [value] exceeds the upper fence of [distribution].
  ///
  /// Returns `false` if there aren't enough samples in [distribution] to
  /// compute a reliable IQR (falls back to false rather than raising).
  ///
  /// **Usage:**
  /// ```dart
  /// final allHeights = [100.0, 102.0, 105.0, 108.0, 110.0, 112.0, 115.0, 1000.0];
  /// if (IqrOutlier.isOutlier(1000.0, allHeights)) {
  ///   // Block is statistically anomalous; discard it.
  /// }
  /// ```
  static bool isOutlier(
    double value,
    List<double> distribution, {
    double? k,
    int minSamples = 4,
  }) {
    final fence = upperFence(distribution, k: k, minSamples: minSamples);
    if (fence == null) return false;
    return value > fence;
  }
}
