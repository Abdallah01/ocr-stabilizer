import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  // ── median ──

  group('RobustStats.median', () {
    test('empty list → null', () {
      expect(RobustStats.median([]), isNull);
    });

    test('single element → that element', () {
      expect(RobustStats.median([7.0]), 7.0);
    });

    test('odd length → middle element of sorted list', () {
      // sorted: [1, 3, 5] → middle = 3
      expect(RobustStats.median([5.0, 1.0, 3.0]), 3.0);
    });

    test('even length → mean of two middle elements', () {
      // sorted: [1, 2, 3, 4] → (2 + 3) / 2 = 2.5
      expect(RobustStats.median([4.0, 1.0, 3.0, 2.0]), 2.5);
    });

    test('does not mutate the input list', () {
      final values = [3.0, 1.0, 2.0];
      RobustStats.median(values);
      expect(values, [3.0, 1.0, 2.0]);
    });
  });

  // ── medianOfSorted ──

  group('RobustStats.medianOfSorted', () {
    test('empty list → null', () {
      expect(RobustStats.medianOfSorted([]), isNull);
    });

    test('odd-length sorted list → middle element', () {
      expect(RobustStats.medianOfSorted([1.0, 2.0, 3.0, 4.0, 5.0]), 3.0);
    });

    test('even-length sorted list → mean of middle pair', () {
      // (2 + 3) / 2 = 2.5
      expect(RobustStats.medianOfSorted([1.0, 2.0, 3.0, 4.0]), 2.5);
    });
  });

  // ── mad ──

  group('RobustStats.mad', () {
    test('empty list → null', () {
      expect(RobustStats.mad([]), isNull);
    });

    test('single element → 0.0', () {
      expect(RobustStats.mad([42.0]), 0.0);
    });

    test('all identical values → 0.0', () {
      expect(RobustStats.mad([5.0, 5.0, 5.0]), 0.0);
    });

    test('odd length: scaled median of absolute deviations', () {
      // [1,2,3,4,5]: median = 3
      // deviations = [2,1,0,1,2] → sorted [0,1,1,2,2] → median = 1
      // MAD = 1.4826 × 1 = 1.4826
      expect(RobustStats.mad([1.0, 2.0, 3.0, 4.0, 5.0]), closeTo(1.4826, 1e-9));
    });

    test('even length: scaled median of absolute deviations', () {
      // [1,2,4,8]: median = (2 + 4) / 2 = 3
      // deviations = [2,1,1,5] → sorted [1,1,2,5] → median = (1+2)/2 = 1.5
      // MAD = 1.4826 × 1.5 = 2.2239
      expect(RobustStats.mad([1.0, 2.0, 4.0, 8.0]), closeTo(2.2239, 1e-9));
    });

    test('resists a single extreme outlier', () {
      // [1,2,3,4,100]: median = 3
      // deviations = [2,1,0,1,97] → sorted [0,1,1,2,97] → median = 1
      // MAD = 1.4826 — identical to the outlier-free case above.
      expect(
        RobustStats.mad([1.0, 2.0, 3.0, 4.0, 100.0]),
        closeTo(1.4826, 1e-9),
      );
    });
  });

  // ── iqr ──

  group('RobustStats.iqr', () {
    test('fewer than 4 samples → null', () {
      expect(RobustStats.iqr([]), isNull);
      expect(RobustStats.iqr([1.0]), isNull);
      expect(RobustStats.iqr([1.0, 2.0, 3.0]), isNull);
    });

    test('even length uses median-of-halves', () {
      // [1,2,3,4]: lower = [1,2] → Q1 = 1.5; upper = [3,4] → Q3 = 3.5
      // IQR = 3.5 - 1.5 = 2.0
      expect(RobustStats.iqr([1.0, 2.0, 3.0, 4.0]), closeTo(2.0, 1e-9));
    });

    test('odd length excludes the median element from both halves', () {
      // [1,2,3,4,5]: lower = [1,2] → Q1 = 1.5; upper = [4,5] → Q3 = 4.5
      // IQR = 4.5 - 1.5 = 3.0
      expect(RobustStats.iqr([1.0, 2.0, 3.0, 4.0, 5.0]), closeTo(3.0, 1e-9));
    });

    test('outlier inflates IQR less than it would σ, but still shifts Q3', () {
      // [1,2,3,4,100]: lower = [1,2] → Q1 = 1.5
      // upper = [4,100] → Q3 = (4 + 100) / 2 = 52
      // IQR = 52 - 1.5 = 50.5
      expect(
        RobustStats.iqr([1.0, 2.0, 3.0, 4.0, 100.0]),
        closeTo(50.5, 1e-9),
      );
    });

    test('all identical values → 0.0', () {
      expect(RobustStats.iqr([5.0, 5.0, 5.0, 5.0]), 0.0);
    });
  });

  // ── madOrFallback ──

  group('RobustStats.madOrFallback', () {
    test('arm 1: MAD > 0 → returns MAD', () {
      // Same data as the mad() test: MAD = 1.4826
      expect(
        RobustStats.madOrFallback([1.0, 2.0, 3.0, 4.0, 5.0]),
        closeTo(1.4826, 1e-9),
      );
    });

    test('arm 2: MAD = 0 but IQR > 0 → IQR / 1.35', () {
      // [1,5,5,5,9]: median = 5
      // deviations = [4,0,0,0,4] → sorted [0,0,0,4,4] → median = 0 → MAD = 0
      // IQR: lower = [1,5] → Q1 = 3; upper = [5,9] → Q3 = 7; IQR = 4
      // fallback = 4 / 1.35 = 2.962962...
      expect(
        RobustStats.madOrFallback([1.0, 5.0, 5.0, 5.0, 9.0]),
        closeTo(4.0 / 1.35, 1e-9),
      );
    });

    test('arm 3: MAD = 0 and IQR = 0 → 0.1 × |median| when above minSpread',
        () {
      // [50,50,50,50]: MAD = 0, IQR = 0, median = 50
      // 0.1 × 50 = 5.0, clamp(1.0, ∞) → 5.0
      expect(
        RobustStats.madOrFallback([50.0, 50.0, 50.0, 50.0]),
        closeTo(5.0, 1e-9),
      );
    });

    test('arm 3: negative median uses absolute value', () {
      // [-50,-50,-50,-50]: median = -50 → 0.1 × 50 = 5.0
      expect(
        RobustStats.madOrFallback([-50.0, -50.0, -50.0, -50.0]),
        closeTo(5.0, 1e-9),
      );
    });

    test('arm 3: median fraction below minSpread clamps up to minSpread', () {
      // [5,5,5]: MAD = 0; IQR null (N < 4); 0.1 × 5 = 0.5 < 1.0 → 1.0
      expect(RobustStats.madOrFallback([5.0, 5.0, 5.0]), 1.0);
    });

    test('arm 3: custom minSpread below the fraction is not applied', () {
      // [5,5,5] with minSpread 0.2: 0.1 × 5 = 0.5, clamp(0.2, ∞) → 0.5
      expect(
        RobustStats.madOrFallback([5.0, 5.0, 5.0], minSpread: 0.2),
        closeTo(0.5, 1e-9),
      );
    });

    test('all zeros → minSpread (median magnitude is zero)', () {
      expect(RobustStats.madOrFallback([0.0, 0.0, 0.0, 0.0]), 1.0);
    });

    test('arm 4: fewer than 3 samples → minSpread, even with real spread', () {
      expect(RobustStats.madOrFallback([]), 1.0);
      expect(RobustStats.madOrFallback([1.0, 100.0]), 1.0);
      expect(RobustStats.madOrFallback([1.0, 100.0], minSpread: 2.5), 2.5);
    });

    // #72 — zero-sentinel defect class (same as the #70 agreement-scale fix):
    // `> 0` gates arm adoption, so a tiny-positive numeric residue passes the
    // sentinel and returns UNFLOORED. This is divisor-poisoning class — the
    // docstring's "every fallback arm bottoms out at [minSpread]" must hold
    // on every arm, not just arm 3.
    test('#72 arm 1: near-zero MAD residue is floored at minSpread', () {
      // Median 100, deviations [0, 1e-9, 1e-9] → MAD = 1e-9: positive, so
      // the MAD arm adopts it — and must clamp to minSpread.
      expect(
        RobustStats.madOrFallback([100.0, 100.0 + 1e-9, 100.0 - 1e-9]),
        1.0,
      );
    });

    test('#72 arm 2: near-zero IQR residue is floored at minSpread', () {
      // MAD = 0 (median deviation 0) → IQR arm: q1 = 100, q3 = 100 + 1e-9
      // → IQR/1.35 = tiny positive: adopted — and must clamp to minSpread.
      expect(
        RobustStats.madOrFallback(
            [100.0, 100.0, 100.0, 100.0 + 1e-9, 100.0 + 1e-9]),
        1.0,
      );
    });

    test('#72 genuine spread above minSpread is returned unclamped', () {
      // Raw MAD of [10,20,30,40,50] = 10, σ-scaled ×1.4826 = 14.826 — the
      // floor must not distort real spread (guard on the clamp direction).
      expect(
        RobustStats.madOrFallback([10.0, 20.0, 30.0, 40.0, 50.0]),
        closeTo(14.826, 1e-9),
      );
    });
  });
}
