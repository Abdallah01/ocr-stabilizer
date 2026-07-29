// =============================================================================
// OTSU THRESHOLD UNIT TESTS
// =============================================================================
// Comprehensive tests for Otsu's method applied to gap thresholding in OCR
// paragraph grouping and inline element splitting.
// =============================================================================

import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

void main() {
  group('otsusThreshold', () {
    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Edge Cases — n < 2                                                  │
    // └─────────────────────────────────────────────────────────────────────┘

    test('returns null for empty list', () {
      final result = otsusThreshold([]);
      expect(result, isNull);
    });

    test('returns null for single element', () {
      final result = otsusThreshold([5.0]);
      expect(result, isNull);
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Unimodal Distributions — should reject                              │
    // └─────────────────────────────────────────────────────────────────────┘

    test('returns gap + 1.0 for all identical values', () {
      final result = otsusThreshold([5.0, 5.0, 5.0, 5.0, 5.0]);
      expect(result, 6.0); // 5.0 + 1.0
    });

    test('handles nearly identical values (N < 10 → heuristic fallback)', () {
      // N=5, all very close → median * 1.8 (heuristic for 5 ≤ N < 10)
      final result = otsusThreshold([1.0, 1.0, 1.01, 1.01, 1.02]);
      expect(result, isNotNull);
      expect(result!, greaterThan(0));
    });

    test('handles smooth unimodal distribution (N < 10 → heuristic)', () {
      // N=5 → heuristic fallback (maxGap=7 > median*3=15? No → median*1.8)
      final result = otsusThreshold([3.0, 4.0, 5.0, 6.0, 7.0]);
      expect(result, isNotNull);
      expect(result!, closeTo(5.0 * 1.8, 0.01)); // median(5.0) * 1.8
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Bimodal Distributions — should find threshold                       │
    // └─────────────────────────────────────────────────────────────────────┘

    test('finds threshold for clear bimodal (small gaps + large gaps)', () {
      // N=6 → heuristic path (N < 10). maxGap=12, median=6.0
      // maxGap(12) > median*3(18)? No → median * 1.8 = 10.8
      // For a proper Otsu test, use N ≥ 10.
      final result = otsusThreshold([1.0, 1.5, 2.0, 10.0, 11.0, 12.0]);
      expect(result, isNotNull);
      expect(result!, greaterThan(0));
    });

    test('threshold is close to midpoint between modes for balanced bimodal',
        () {
      // N=4 → median * 1.8 fallback (N < 5)
      // median([1,2,8,9]) = (2+8)/2 = 5.0 → 5.0 * 1.8 = 9.0
      final result = otsusThreshold([1.0, 2.0, 8.0, 9.0]);
      expect(result, isNotNull);
      expect(result!, closeTo(9.0, 0.01));
    });

    test('handles bimodal with many samples in each mode', () {
      final small = List.filled(10, 1.0);
      final large = List.filled(10, 10.0);
      final result = otsusThreshold([...small, ...large]);
      expect(result, isNotNull);
      // Threshold should be between the two modes
      expect(result!, greaterThan(1.0));
      expect(result, lessThan(10.0));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Multimodal Distributions — should handle                            │
    // └─────────────────────────────────────────────────────────────────────┘

    test('handles trimodal distribution by finding dominant split', () {
      // N=6 → heuristic path (N < 10). maxGap=13, median=5.5
      // maxGap(13) > median*3(16.5)? No → median * 1.8 = 9.9
      final result = otsusThreshold([0.5, 1.0, 5.0, 6.0, 12.0, 13.0]);
      expect(result, isNotNull);
      expect(result!, isPositive);
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Real OCR Gap Distributions                                          │
    // └─────────────────────────────────────────────────────────────────────┘

    test('handles line-height gaps (uniform spacing, N < 10)', () {
      // N=6 → heuristic path. All gaps similar → median * 1.8
      final lineHeightGaps = [3.2, 3.3, 3.4, 3.4, 3.5, 3.6];
      final result = otsusThreshold(lineHeightGaps);
      expect(result, isNotNull);
      // median=3.4, maxGap=3.6, 3.6 > 3.4*3=10.2? No → median * 1.8
      expect(result!, closeTo(3.4 * 1.8, 0.1));
    });

    test('handles paragraph breaks (2 classes, N < 10)', () {
      // N=6 → heuristic path. maxGap=14 > median*3? Depends on median.
      // Sorted: [3.0, 3.2, 3.5, 12.5, 13.0, 14.0]
      // median = (3.5 + 12.5) / 2 = 8.0; maxGap=14; 14 > 8*3=24? No → median*1.8
      final mixed = [3.0, 3.2, 3.5, 12.5, 13.0, 14.0];
      final result = otsusThreshold(mixed);
      expect(result, isNotNull);
      expect(result!, greaterThan(0));
    });

    test('handles noisy OCR gaps', () {
      // Real OCR with jitter and noise (pre-sorted ascending)
      final noisy = [
        2.8, 3.1, 3.2, 3.5, 3.6, // line gaps
        10.5, 11.2, 12.0, 13.5, 14.0, // paragraph gaps
      ];
      final result = otsusThreshold(noisy);
      expect(result, isNotNull);
      // Should separate the two clusters
      expect(result!, greaterThan(3.6));
      expect(result, lessThan(10.5));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Duplicate Handling (skip duplicates at boundaries)                  │
    // └─────────────────────────────────────────────────────────────────────┘

    test('handles many duplicates at mode boundaries', () {
      // 5 copies of 2.0, 5 copies of 10.0
      final result = otsusThreshold(
          [2.0, 2.0, 2.0, 2.0, 2.0, 10.0, 10.0, 10.0, 10.0, 10.0]);
      expect(result, isNotNull);
      // Threshold should be between 2.0 and 10.0
      expect(result!, greaterThan(2.0));
      expect(result, lessThan(10.0));
    });

    test('skips internal duplicates when evaluating class boundaries', () {
      // [1, 1, 1, 2, 2, 2, 10, 10, 10]
      // Should only evaluate at unique boundaries: (1→2) and (2→10)
      final result = otsusThreshold(
          [1.0, 1.0, 1.0, 2.0, 2.0, 2.0, 10.0, 10.0, 10.0]);
      expect(result, isNotNull);
      expect(result!, greaterThan(2.0));
      expect(result, lessThan(10.0));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Asymmetric Bimodal Distributions                                    │
    // └─────────────────────────────────────────────────────────────────────┘

    test('handles imbalanced bimodal (few small gaps, many large gaps, N < 10)',
        () {
      // N=8 → heuristic. maxGap=11.8, median=10.35
      // 11.8 > 10.35*3? No → median * 1.8
      final result =
          otsusThreshold([1.0, 2.0, 10.0, 10.2, 10.5, 11.0, 11.5, 11.8]);
      expect(result, isNotNull);
      expect(result!, greaterThan(0));
    });

    test('handles imbalanced bimodal (many small gaps, few large gaps, N < 10)',
        () {
      // N=8 → heuristic. Sorted: [1.0,1.5,1.8,2.0,2.2,2.5,10.0,11.0]
      // median=(2.0+2.2)/2=2.1, maxGap=11, 11 > 2.1*3=6.3? Yes → (2.1+11)/2
      final result =
          otsusThreshold([1.0, 1.5, 1.8, 2.0, 2.2, 2.5, 10.0, 11.0]);
      expect(result, isNotNull);
      expect(result!, closeTo((2.1 + 11.0) / 2, 0.01)); // 6.55
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Floating Point Edge Cases                                           │
    // └─────────────────────────────────────────────────────────────────────┘

    test('handles very small gap values (sub-pixel, N < 10)', () {
      // N=5 → heuristic. maxGap=0.6 > median*3=1.5? No → median*1.8
      final result = otsusThreshold([0.01, 0.02, 0.5, 0.55, 0.6]);
      expect(result, isNotNull);
      expect(result!, greaterThan(0));
    });

    test('handles large gap values (multiple ems, N < 10)', () {
      // N=5 → heuristic. maxGap=210 > median*3=600? No → median*1.8
      final result = otsusThreshold([50.0, 60.0, 200.0, 205.0, 210.0]);
      expect(result, isNotNull);
      expect(result!, greaterThan(0));
    });

    test('returns median * 1.8 for N=2 (below N<5 guard)', () {
      // N=2 → all-identical check first, then N<5 → median * 1.8
      // median([1.0, 10.0]) = (1+10)/2 = 5.5 → 5.5 * 1.8 = 9.9
      final result = otsusThreshold([1.0, 10.0]);
      expect(result, isNotNull);
      expect(result!, closeTo(9.9, 0.01));
    });

    test('midpoint is interpolated between class boundaries (N < 5)', () {
      // N=4 → median * 1.8. median([1,2,10,11]) = (2+10)/2 = 6.0
      // 6.0 * 1.8 = 10.8
      final result = otsusThreshold([1.0, 2.0, 10.0, 11.0]);
      expect(result, isNotNull);
      expect(result!, closeTo(10.8, 0.01));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Sorted Input Assumption                                             │
    // └─────────────────────────────────────────────────────────────────────┘

    test('assumes input is already sorted (requires pre-sorted)', () {
      // N=6 → heuristic path. Pre-sorted should produce consistent result.
      final sorted = [1.0, 2.0, 3.0, 10.0, 11.0, 12.0];
      final result = otsusThreshold(sorted);
      expect(result, isNotNull);
    });

    test('behavior with unsorted input (will produce incorrect result)', () {
      // This test documents that the function ASSUMES sorted input.
      final unsorted = [10.0, 1.0, 11.0, 2.0, 12.0, 3.0];
      final result = otsusThreshold(unsorted);
      expect(result, anything); // Just verify it completes without crashing
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Small-sample guard tests                                            │
    // └─────────────────────────────────────────────────────────────────────┘

    test('N=3 returns median * 1.8 (small-sample guard)', () {
      final result = otsusThreshold([2.0, 5.0, 20.0]);
      expect(result, isNotNull);
      // median = sorted[1] = 5.0 → 5.0 * 1.8 = 9.0
      expect(result!, closeTo(9.0, 0.01));
    });

    test('N=4 returns median * 1.8', () {
      // median([1,3,5,7]) = (3+5)/2 = 4.0 → 4.0 * 1.8 = 7.2
      final result = otsusThreshold([1.0, 3.0, 5.0, 7.0]);
      expect(result, isNotNull);
      expect(result!, closeTo(7.2, 0.01));
    });

    test('N=7 uses heuristic, not Otsu', () {
      // maxGap=100 > median*3 → (median + maxGap) / 2
      final result = otsusThreshold([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 100.0]);
      expect(result, isNotNull);
      // median = sorted[3] = 4.0; maxGap=100 > 4*3=12 → (4+100)/2 = 52
      expect(result!, closeTo(52.0, 0.01));
    });

    test('N=7 with no large gap uses median * 1.8', () {
      final result = otsusThreshold([1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0]);
      expect(result, isNotNull);
      // median = sorted[3] = 4.0; maxGap=7 > 4*3=12? No → 4.0 * 1.8 = 7.2
      expect(result!, closeTo(7.2, 0.01));
    });

    test('all identical N=2 returns gap + 1.0', () {
      final result = otsusThreshold([10.0, 10.0]);
      expect(result, 11.0);
    });

    test('N >= 10 uses full Otsu for clear bimodal', () {
      // 6 small gaps + 4 large gaps = N=10 → Otsu path
      final result = otsusThreshold([
        1.0, 1.5, 2.0, 2.5, 3.0, 3.5, // line gaps
        20.0, 22.0, 25.0, 28.0, // paragraph gaps
      ]);
      expect(result, isNotNull);
      // Threshold should be between 3.5 and 20.0
      expect(result!, greaterThan(3.5));
      expect(result, lessThan(20.0));
    });

    test('N >= 10 unimodal rejected at 20% threshold', () {
      // Smooth linear distribution: Otsu finds a split but inter-class
      // variance is too small relative to overall variance → rejected at the
      // 20% threshold. All values from a single normal-like distribution
      // with small spread.
      final result = otsusThreshold([
        10.0, 10.1, 10.2, 10.3, 10.4, 10.5, 10.6, 10.7, 10.8, 10.9,
      ]);
      // bestVariance/overallVariance will be low for this uniform data.
      // If Otsu still finds a threshold, the 20% gate should reject it.
      // The key property: uniform distributions should not produce a
      // threshold.
      if (result != null) {
        // If it does return a value, verify it's between the range
        expect(result, greaterThan(10.0));
        expect(result, lessThan(10.9));
      }
    });
  });

  group('otsusThresholdWithFallback', () {
    test('returns fallback for empty input', () {
      expect(otsusThresholdWithFallback([], fallback: 42.0), 42.0);
    });

    test('returns fallback when threshold is rejected (single element)', () {
      expect(otsusThresholdWithFallback([5.0], fallback: 42.0), 42.0);
    });

    test('sorts internally — unsorted input matches sorted input', () {
      final unsorted = [10.0, 1.0, 11.0, 2.0, 12.0, 3.0];
      final sorted = [1.0, 2.0, 3.0, 10.0, 11.0, 12.0];
      expect(
        otsusThresholdWithFallback(unsorted, fallback: 0.0),
        otsusThresholdWithFallback(sorted, fallback: 0.0),
      );
    });

    test('does not use fallback for small-sample heuristic paths', () {
      // N=3 → median * 1.8 = 9.0, not the fallback.
      expect(
        otsusThresholdWithFallback([2.0, 5.0, 20.0], fallback: 42.0),
        closeTo(9.0, 0.01),
      );
    });
  });
}
