// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

/// Minimal descriptive statistics for report tables.
class NumStats {
  NumStats(List<num> values)
      : count = values.length,
        _sorted = [...values.map((v) => v.toDouble())]..sort();

  final int count;
  final List<double> _sorted;

  double get mean => count == 0
      ? double.nan
      : _sorted.reduce((a, b) => a + b) / count;

  double percentile(double p) {
    if (count == 0) return double.nan;
    final idx = (p * (count - 1)).round().clamp(0, count - 1);
    return _sorted[idx];
  }

  double get p50 => percentile(0.50);
  double get p90 => percentile(0.90);
  double get max => count == 0 ? double.nan : _sorted.last;

  Map<String, Object?> toJson() => {
        'count': count,
        'mean': _round(mean),
        'p50': _round(p50),
        'p90': _round(p90),
        'max': _round(max),
      };

  static Object? _round(double v) =>
      v.isNaN ? null : (v * 1000).round() / 1000;

  @override
  String toString() => count == 0
      ? 'n=0'
      : 'n=$count mean=${mean.toStringAsFixed(2)} '
          'p50=${p50.toStringAsFixed(2)} p90=${p90.toStringAsFixed(2)}';
}
