// ============================================================================
// ROBUST STATISTICS
// ============================================================================
// Implements robust statistical estimators that are resistant to outliers.
// Used to replace standard deviation (σ) in adaptive threshold computations.
// MAD (Median Absolute Deviation) is preferred over σ for real-world data
// with heavy tails (e.g., layout shifts, OCR errors).

/// Robust statistical methods — MAD (Median Absolute Deviation) and median.
///
/// MAD is a robust estimator of spread that resists outliers. While σ can be
/// inflated 3–5× by a single extreme value, MAD remains stable.
/// Scale factor 1.4826 makes MAD approximately equal to σ under normality.
class RobustStats {
  RobustStats._();

  /// Minimum samples for reliable IQR computation.
  static const int _kMinIqrSamples = 4;

  /// Minimum samples for reliable MAD-or-fallback.
  static const int _kMinMadFallbackSamples = 3;

  /// IQR-to-σ conversion factor (IQR ≈ 1.35σ under normality).
  static const double _kIqrToSigma = 1.35;

  /// Fraction of median used as last-resort spread estimate.
  static const double _kMedianFallbackFraction = 0.1;

  /// Compute the median of [values].
  ///
  /// Returns `null` if [values] is empty.
  ///
  /// **Time complexity:** O(N log N) (due to sorting).
  /// **Space complexity:** O(N) (sorts a copy).
  ///
  /// **Example:**
  /// ```dart
  /// final m = RobustStats.median([1.0, 2.0, 3.0, 4.0, 5.0]);
  /// // m == 3.0 (middle element of sorted list)
  /// ```
  static double? median(List<double> values) {
    if (values.isEmpty) return null;
    if (values.length == 1) return values[0];

    final sorted = List<double>.from(values)..sort();
    return _medianOfSorted(sorted);
  }

  /// Median of an already-sorted list. Avoids redundant O(N log N) sort
  /// when the caller has already sorted the data (e.g., quartile computation
  /// in [iqr] and [IqrOutlier.fences]).
  ///
  /// Returns `null` if [sorted] is empty.
  static double? medianOfSorted(List<double> sorted) => _medianOfSorted(sorted);

  static double? _medianOfSorted(List<double> sorted) {
    if (sorted.isEmpty) return null;
    if (sorted.length == 1) return sorted[0];
    final n = sorted.length;
    if (n.isOdd) {
      return sorted[n ~/ 2];
    } else {
      return (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2.0;
    }
  }

  /// Compute the Median Absolute Deviation (MAD) scaled by 1.4826.
  ///
  /// MAD is defined as: `1.4826 × median(|x - median(x)|)`
  ///
  /// The scale factor 1.4826 is chosen so that MAD ≈ σ under a normal
  /// distribution, making MAD a consistent alternative to σ. However, under
  /// heavy-tailed distributions, MAD << σ, making it more robust.
  ///
  /// Returns `null` if [values] is empty.
  /// Returns `0.0` if all values are identical.
  ///
  /// **Time complexity:** O(N log N) (sorts twice).
  /// **Space complexity:** O(N) (copies the list twice).
  ///
  /// **References:**
  /// - Huber, P. J. (1981). Robust Statistics. Wiley.
  /// - Leys, C., et al. (2013). Detecting outliers: Do not use standard
  ///   deviation around the mean, use absolute deviation around the median.
  ///   Journal of Experimental Social Psychology, 49(6), 764–766.
  ///
  /// **Example:**
  /// ```dart
  /// // Normal data: MAD ≈ σ
  /// final normal = [1.0, 2.0, 3.0, 4.0, 5.0];
  /// final madNormal = RobustStats.mad(normal); // ~1.48
  ///
  /// // Heavy-tailed data: MAD << σ
  /// final outlier = [1.0, 2.0, 3.0, 4.0, 100.0]; // 100 is extreme
  /// final madOutlier = RobustStats.mad(outlier); // ~1.48 (robust)
  /// final sigmaOutlier = stddev(outlier);       // ~44.7 (inflated)
  /// ```
  static double? mad(List<double> values) {
    if (values.isEmpty) return null;
    if (values.length == 1) return 0.0;

    final medianVal = median(values);
    if (medianVal == null) return null;

    // Compute absolute deviations from the median.
    final deviations = values.map((v) => (v - medianVal).abs()).toList();

    // Compute the median of the deviations.
    final madValue = median(deviations);
    if (madValue == null) return null;

    // Scale by 1.4826 for consistency with σ under normality.
    return 1.4826 * madValue;
  }

  /// Compute the Interquartile Range (Q3 − Q1).
  ///
  /// Uses the median-of-halves (exclusive median) method: the sorted data is
  /// split at the median index, then Q1 and Q3 are the medians of the lower
  /// and upper halves respectively.
  ///
  /// Returns `null` if [values] has fewer than 4 elements (insufficient data
  /// for reliable quartile estimation).
  ///
  /// **Time complexity:** O(N log N) (due to sorting).
  /// **Space complexity:** O(N) (sorts a copy).
  static double? iqr(List<double> values) {
    if (values.length < _kMinIqrSamples) return null;

    final sorted = List<double>.from(values)..sort();
    final n = sorted.length;
    final mid = n ~/ 2;

    final lower = sorted.sublist(0, mid);
    final upper = sorted.sublist(n.isEven ? mid : mid + 1);

    final q1 = _medianOfSorted(lower)!;
    final q3 = _medianOfSorted(upper)!;
    return q3 - q1;
  }

  /// Returns MAD if non-zero; falls back to robust alternatives when MAD = 0.
  ///
  /// **Fallback chain:**
  /// 1. MAD > 0 → return MAD (normal case)
  /// 2. MAD = 0 but IQR > 0 → return IQR / 1.35 (heavy concentration at median)
  /// 3. IQR also = 0 → return `0.1 × median`, clamped to [minSpread, ∞)
  /// 4. N < 3 or empty → return [minSpread] (insufficient data)
  ///
  /// The constant 1.35 converts IQR to the same σ-equivalent scale as MAD
  /// (IQR ≈ 1.35σ under normality, so IQR / 1.35 ≈ σ).
  ///
  /// **Guaranteed:** Never returns zero or negative, provided
  /// [minSpread] is positive (the default is 1.0). Every fallback arm
  /// bottoms out at [minSpread], so a zero or negative [minSpread]
  /// voids the guarantee.
  static double madOrFallback(List<double> values, {double minSpread = 1.0}) {
    if (values.length < _kMinMadFallbackSamples) return minSpread;

    final madVal = mad(values);
    if (madVal != null && madVal > 0) return madVal;

    final iqrVal = iqr(values);
    if (iqrVal != null && iqrVal > 0) return iqrVal / _kIqrToSigma;

    final medVal = median(values);
    if (medVal != null && medVal.abs() > 0) {
      return (_kMedianFallbackFraction * medVal.abs()).clamp(
        minSpread,
        double.infinity,
      );
    }
    return minSpread;
  }
}
