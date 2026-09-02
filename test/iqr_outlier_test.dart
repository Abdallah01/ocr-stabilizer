// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  // ── fences ──

  group('IqrOutlier.fences', () {
    test('fewer than minSamples (default 4) → null', () {
      expect(IqrOutlier.fences([]), isNull);
      expect(IqrOutlier.fences([1.0, 2.0, 3.0]), isNull);
    });

    test('all identical values → null (no spread, no outliers)', () {
      expect(IqrOutlier.fences([7.0, 7.0, 7.0, 7.0]), isNull);
    });

    test('small sample uses adaptive k = 2.2', () {
      // [1,2,3,4,100]: lower half [1,2] → Q1 = 1.5
      // upper half [4,100] → Q3 = 52; IQR = 50.5
      // N = 5 < 15 → k = 2.2; 2.2 × 50.5 = 111.1
      // lower = 1.5 - 111.1 = -109.6; upper = 52 + 111.1 = 163.1
      final f = IqrOutlier.fences([1.0, 2.0, 3.0, 4.0, 100.0])!;
      expect(f.lower, closeTo(-109.6, 1e-9));
      expect(f.upper, closeTo(163.1, 1e-9));
    });

    test('explicit k overrides the adaptive multiplier', () {
      // Same quartiles as above; k = 1.5 → 1.5 × 50.5 = 75.75
      // lower = 1.5 - 75.75 = -74.25; upper = 52 + 75.75 = 127.75
      final f = IqrOutlier.fences([1.0, 2.0, 3.0, 4.0, 100.0], k: 1.5)!;
      expect(f.lower, closeTo(-74.25, 1e-9));
      expect(f.upper, closeTo(127.75, 1e-9));
    });

    test('N = 14 (just below 15) still uses k = 2.2', () {
      // [1..14]: lower half [1..7] → Q1 = 4; upper half [8..14] → Q3 = 11
      // IQR = 7; k = 2.2 → 2.2 × 7 = 15.4
      // lower = 4 - 15.4 = -11.4; upper = 11 + 15.4 = 26.4
      final values = [for (var i = 1; i <= 14; i++) i.toDouble()];
      final f = IqrOutlier.fences(values)!;
      expect(f.lower, closeTo(-11.4, 1e-9));
      expect(f.upper, closeTo(26.4, 1e-9));
    });

    test('N = 15 (boundary) switches to standard k = 1.5', () {
      // [1..15]: lower half [1..7] → Q1 = 4; upper half [9..15] → Q3 = 12
      // IQR = 8; k = 1.5 → 1.5 × 8 = 12
      // lower = 4 - 12 = -8; upper = 12 + 12 = 24
      final values = [for (var i = 1; i <= 15; i++) i.toDouble()];
      final f = IqrOutlier.fences(values)!;
      expect(f.lower, closeTo(-8.0, 1e-9));
      expect(f.upper, closeTo(24.0, 1e-9));
    });

    test('N = 16 (even split) with k = 1.5', () {
      // [1..16]: lower half [1..8] → Q1 = 4.5; upper half [9..16] → Q3 = 12.5
      // IQR = 8; k = 1.5 → lower = 4.5 - 12 = -7.5; upper = 12.5 + 12 = 24.5
      final values = [for (var i = 1; i <= 16; i++) i.toDouble()];
      final f = IqrOutlier.fences(values)!;
      expect(f.lower, closeTo(-7.5, 1e-9));
      expect(f.upper, closeTo(24.5, 1e-9));
    });

    test('IQR = 0 falls back to synthetic spread (range / 4)', () {
      // [1,5,5,5,5,9]: lower half [1,5,5] → Q1 = 5
      // upper half [5,5,9] → Q3 = 5; IQR = 0
      // synthetic spread = (9 - 1) / 4 = 2; N = 6 < 15 → k = 2.2
      // 2.2 × 2 = 4.4; lower = 5 - 4.4 = 0.6; upper = 5 + 4.4 = 9.4
      final f = IqrOutlier.fences([1.0, 5.0, 5.0, 5.0, 5.0, 9.0])!;
      expect(f.lower, closeTo(0.6, 1e-9));
      expect(f.upper, closeTo(9.4, 1e-9));
    });

    test('minSamples can be raised', () {
      expect(IqrOutlier.fences([1.0, 2.0, 3.0, 4.0], minSamples: 5), isNull);
    });

    test('minSamples can be lowered, but is floored at 2', () {
      // minSamples: 1 is clamped to 2 → a single value still returns null.
      expect(IqrOutlier.fences([1.0], minSamples: 1), isNull);
      // Two values pass: [1,3] → lower [1] Q1 = 1; upper [3] Q3 = 3
      // IQR = 2; k = 2.2 → lower = 1 - 4.4 = -3.4; upper = 3 + 4.4 = 7.4
      final f = IqrOutlier.fences([1.0, 3.0], minSamples: 1)!;
      expect(f.lower, closeTo(-3.4, 1e-9));
      expect(f.upper, closeTo(7.4, 1e-9));
    });

    test('minSamples = 2 on a 3-element list (odd exclusive split)', () {
      // [1,2,9]: lower [1] → Q1 = 1; upper [9] → Q3 = 9 (median excluded)
      // IQR = 8; k = 2.2 → 17.6; lower = -16.6; upper = 26.6
      final f = IqrOutlier.fences([1.0, 2.0, 9.0], minSamples: 2)!;
      expect(f.lower, closeTo(-16.6, 1e-9));
      expect(f.upper, closeTo(26.6, 1e-9));
    });
  });

  // ── upperFence ──

  group('IqrOutlier.upperFence', () {
    test('returns the upper fence from fences()', () {
      // Same computation as the fences test: upper = 163.1
      expect(
        IqrOutlier.upperFence([1.0, 2.0, 3.0, 4.0, 100.0]),
        closeTo(163.1, 1e-9),
      );
    });

    test('fewer than minSamples → null', () {
      expect(IqrOutlier.upperFence([1.0, 2.0, 3.0]), isNull);
    });

    test('all identical values → null', () {
      expect(IqrOutlier.upperFence([5.0, 5.0, 5.0, 5.0]), isNull);
    });
  });

  // ── isOutlier ──

  group('IqrOutlier.isOutlier', () {
    final heights = [100.0, 102.0, 105.0, 108.0, 110.0, 112.0, 115.0, 1000.0];
    // Fence for heights (N = 8, k adaptive = 2.2):
    // sorted lower half [100,102,105,108] → Q1 = (102 + 105) / 2 = 103.5
    // sorted upper half [110,112,115,1000] → Q3 = (112 + 115) / 2 = 113.5
    // IQR = 10; upper fence = 113.5 + 2.2 × 10 = 135.5

    test('extreme value above the fence → true', () {
      expect(IqrOutlier.isOutlier(1000.0, heights), isTrue);
    });

    test('typical value below the fence → false', () {
      expect(IqrOutlier.isOutlier(110.0, heights), isFalse);
    });

    test('value exactly at the fence is not an outlier (strict >)', () {
      // With explicit k = 1.5 the fence is exact in doubles:
      // upper = 113.5 + 1.5 × 10 = 128.5
      expect(IqrOutlier.isOutlier(128.5, heights, k: 1.5), isFalse);
      expect(IqrOutlier.isOutlier(128.6, heights, k: 1.5), isTrue);
    });

    test('only the upper fence is checked — low values never flagged', () {
      // -1000 is far below the lower fence, yet isOutlier only compares
      // against the upper fence, so it returns false by design.
      expect(
          IqrOutlier.isOutlier(-1000.0, [1.0, 2.0, 3.0, 4.0, 100.0]), isFalse);
    });

    test('insufficient samples → false rather than throwing', () {
      expect(IqrOutlier.isOutlier(1000.0, [1.0, 2.0, 3.0]), isFalse);
    });

    test('all-identical distribution → false (no fence computable)', () {
      expect(IqrOutlier.isOutlier(10.0, [5.0, 5.0, 5.0, 5.0]), isFalse);
    });
  });
}
