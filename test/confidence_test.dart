import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  // ── computeFreshness ──

  group('computeFreshness', () {
    test('age < 200ms → 1.0', () {
      expect(computeFreshness(0), 1.0);
      expect(computeFreshness(100), 1.0);
      expect(computeFreshness(199), 1.0);
    });

    test('age > 2000ms → 0.3', () {
      expect(computeFreshness(2001), 0.3);
      expect(computeFreshness(5000), 0.3);
    });

    test('age 200ms → 1.0 (boundary)', () {
      expect(computeFreshness(200), closeTo(1.0, 0.001));
    });

    test('age 2000ms → 0.3 (boundary)', () {
      expect(computeFreshness(2000), closeTo(0.3, 0.001));
    });

    test('linear interpolation at midpoint (1100ms)', () {
      // midpoint of 200..2000 = 1100
      // expected: 1.0 - (1100-200)/(2000-200) * 0.7 = 1.0 - 0.5*0.7 = 0.65
      expect(computeFreshness(1100), closeTo(0.65, 0.01));
    });
  });

  // ── computeStability ──

  group('computeStability', () {
    test('null delta → 0.5 (no prior observation)', () {
      expect(computeStability(null), 0.5);
    });

    test('zero delta → 1.0 (perfectly stable)', () {
      expect(computeStability(0.0), 1.0);
    });

    test('delta below stable threshold → 1.0', () {
      expect(computeStability(5.0), 1.0);
    });

    test('delta above unstable threshold → 0.3', () {
      expect(computeStability(100.0), 0.3);
    });

    test('delta between thresholds → linear interpolation', () {
      // Default: stable=10, unstable=60
      // delta=35 → 1.0 - (35-10)/(60-10) * 0.7 = 1.0 - 0.5*0.7 = 0.65
      expect(computeStability(35.0), closeTo(0.65, 0.01));
    });

    test('with referenceHeight scales thresholds', () {
      // referenceHeight=100 → stable = (100*0.15).clamp(5,20) = 15
      //                      unstable = (100*1.0).clamp(30,120) = 100
      // delta=15 → 1.0 (at stable threshold)
      expect(
        computeStability(15.0, referenceHeight: 100.0),
        closeTo(1.0, 0.01),
      );
      // delta=100 → 0.3 (at unstable threshold)
      expect(
        computeStability(100.0, referenceHeight: 100.0),
        closeTo(0.3, 0.01),
      );
    });

    test('referenceHeight=0 falls back to fixed thresholds', () {
      expect(computeStability(5.0, referenceHeight: 0.0), 1.0);
    });
  });

  // ── computeTextConfidence ──

  group('computeTextConfidence', () {
    test('empty group → 0.3', () {
      expect(computeTextConfidence([]), 0.3);
    });

    test('group with native confidence uses weighted mean', () {
      final blocks = [
        OcrBlock(
          boundingBox: const Rect.fromLTRB(0, 0, 100, 30),
          text: 'abc',
          confidence: 0.9,
          lines: [],
        ),
        OcrBlock(
          boundingBox: const Rect.fromLTRB(0, 30, 100, 60),
          text: 'de',
          confidence: 0.6,
          lines: [],
        ),
      ];
      // weighted: (0.9*3 + 0.6*2) / 5 = (2.7+1.2)/5 = 0.78
      expect(computeTextConfidence(blocks), closeTo(0.78, 0.01));
    });

    test('group without native confidence falls back to heuristic', () {
      final blocks = [
        OcrBlock(
          boundingBox: const Rect.fromLTRB(0, 0, 100, 30),
          text: '测试文本',
          lines: [],
        ),
      ];
      final result = computeTextConfidence(blocks);
      // CJK text should score higher than random ASCII
      expect(result, greaterThan(0.5));
      expect(result, lessThanOrEqualTo(1.0));
    });

    test('mixed confidence (some null) falls back to heuristic', () {
      final blocks = [
        OcrBlock(
          boundingBox: const Rect.fromLTRB(0, 0, 100, 30),
          text: '测試',
          confidence: null,
          lines: [],
        ),
        OcrBlock(
          boundingBox: const Rect.fromLTRB(0, 30, 100, 60),
          text: '文本',
          confidence: null,
          lines: [],
        ),
      ];
      final result = computeTextConfidence(blocks);
      expect(result, greaterThan(0.3));
    });
  });

  // ── computeTextConfidenceRaw ──

  group('computeTextConfidenceRaw', () {
    test('empty text → 0.3', () {
      expect(computeTextConfidenceRaw(''), 0.3);
    });

    test('pure CJK text scores high', () {
      final score = computeTextConfidenceRaw('测试文本内容');
      // CJK ratio = 1.0 → cjkScore = 0.9
      expect(score, greaterThan(0.7));
    });

    test('pure ASCII text scores moderate', () {
      final score = computeTextConfidenceRaw('hello world test');
      // CJK ratio = 0.0 → cjkScore = 0.5
      expect(score, greaterThan(0.4));
      expect(score, lessThan(0.8));
    });

    test('very short text (≤2 runes) penalised', () {
      final short = computeTextConfidenceRaw('ab');
      final longer = computeTextConfidenceRaw('abcdefgh');
      expect(short, lessThan(longer));
    });

    test('repetitive text penalised', () {
      final repetitive = computeTextConfidenceRaw('IIIIIII');
      final diverse = computeTextConfidenceRaw('abcdefg');
      expect(repetitive, lessThan(diverse));
    });

    test('wide bounding box relative to chars penalised', () {
      // width=1000, height=30, 3 chars → expectedWidth=90, ratio=11.1 → aspect=0.6
      final withBbox = computeTextConfidenceRaw('测试文', [
        const Rect.fromLTRB(0, 0, 1000, 30),
      ]);
      final noBbox = computeTextConfidenceRaw('测试文');
      expect(withBbox, lessThan(noBbox));
    });
  });

  // ── isCjkIdeograph ──

  group('isCjkIdeograph', () {
    test('CJK unified ideograph returns true', () {
      expect(isCjkIdeograph(0x4e00), isTrue); // 一
      expect(isCjkIdeograph(0x9fff), isTrue);
    });

    test('CJK extension A returns true', () {
      expect(isCjkIdeograph(0x3400), isTrue);
    });

    test('CJK compatibility returns true', () {
      expect(isCjkIdeograph(0xf900), isTrue);
    });

    test('ASCII returns false', () {
      expect(isCjkIdeograph(0x41), isFalse); // 'A'
    });

    test('Latin returns false', () {
      expect(isCjkIdeograph(0x00e9), isFalse); // 'é'
    });
  });
}
