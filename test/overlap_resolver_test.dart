// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

// ignore_for_file: unused_element_parameter

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// OVERLAP RESOLVER TESTS
// =============================================================================

/// Minimal test block for package-level OverlapResolver tests.
class _TestBlock implements TrackedBlock<Never> {
  @override
  final AbsoluteRect absoluteRect;
  @override
  final bool isViewportRelative;
  @override
  final bool isInnerScrollerChild;
  @override
  final double innerScrollerTop;
  @override
  final ContainerId? containerId;
  @override
  final bool isHorizontalScrollChild;
  @override
  Never get payload => throw UnsupportedError('_TestBlock has no payload');

  // Tier A identity/coordinate fields
  @override
  final String originalText;
  final double captureScrollY;
  final double captureScrollX;
  final int hzScrollerIndex;
  @override
  final bool isFromStickyElement;
  final double stickyFallbackScrollY;
  final double stickyFallbackScrollX;
  final bool stickyFallbackIsIc;
  final int stickyFallbackHzIndex;
  @override
  final PositionConfidence positionConfidence;
  @override
  final TextConfidence textConfidence;
  @override
  final int sourceQuality;

  _TestBlock({
    required this.absoluteRect,
    this.isViewportRelative = false,
    this.isInnerScrollerChild = false,
    this.innerScrollerTop = 0,
    this.containerId,
    this.isHorizontalScrollChild = false,
    this.originalText = '',
    this.captureScrollY = 0,
    this.captureScrollX = 0,
    this.hzScrollerIndex = -1,
    this.isFromStickyElement = false,
    this.stickyFallbackScrollY = 0,
    this.stickyFallbackScrollX = 0,
    this.stickyFallbackIsIc = false,
    this.stickyFallbackHzIndex = -1,
    this.positionConfidence = const PositionConfidence(0.5),
    this.textConfidence = const TextConfidence(0.5),
    this.sourceQuality = 0,
  });

  @override
  ScrollContext get scrollContext => ScrollContext(
        scrollY: captureScrollY,
        scrollX: captureScrollX,
        hzScrollerIndex: hzScrollerIndex,
      );

  @override
  StickyFallback get stickyFallback => StickyFallback(
        scrollY: stickyFallbackScrollY,
        scrollX: stickyFallbackScrollX,
        isIc: stickyFallbackIsIc,
        hzScrollerIndex: stickyFallbackHzIndex,
      );
}

_TestBlock _makeBlock({
  required double left,
  required double top,
  double width = 100,
  double height = 50,
  bool isViewportRelative = false,
  bool isInnerScrollerChild = false,
  double innerScrollerTop = 0,
  bool isHorizontalScrollChild = false,
  int hzScrollerIndex = -1,
  String originalText = '',
  double positionConfidence = 0.5,
  double textConfidence = 0.5,
}) {
  return _TestBlock(
    absoluteRect: AbsoluteRect.fromLTWH(left, top, width, height),
    isViewportRelative: isViewportRelative,
    isInnerScrollerChild: isInnerScrollerChild,
    innerScrollerTop: innerScrollerTop,
    isHorizontalScrollChild: isHorizontalScrollChild,
    hzScrollerIndex: hzScrollerIndex,
    originalText: originalText,
    positionConfidence: PositionConfidence(positionConfidence),
    textConfidence: TextConfidence(textConfidence),
  );
}

void main() {
  const resolver = OverlapResolver();

  group('OverlapResolver', () {
    // ┌─────────────────────────────────────────────────────────────────
    // Threshold constants
    // ┌─────────────────────────────────────────────────────────────────

    test('threshold constants have documented values', () {
      expect(OverlapResolver.kCjkOverlapThreshold, closeTo(0.35, 1e-9));
      expect(OverlapResolver.kShortLatinOverlapThreshold, closeTo(0.65, 1e-9));
      expect(OverlapResolver.kDefaultOverlapThreshold, closeTo(0.50, 1e-9));
      expect(OverlapResolver.kGiantAreaRatioFallback, closeTo(3.0, 1e-9));
    });

    // ┌─────────────────────────────────────────────────────────────────
    // overlapThresholdFor (language-aware selection)
    // ┌─────────────────────────────────────────────────────────────────

    group('overlapThresholdFor', () {
      test('pure CJK text gets the looser CJK threshold', () {
        final block = _makeBlock(left: 0, top: 0, originalText: '你好世界');
        expect(
          resolver.overlapThresholdFor(block),
          closeTo(OverlapResolver.kCjkOverlapThreshold, 1e-9),
        );
      });

      test('CJK fraction exactly 0.6 counts as CJK-dominant (>= boundary)', () {
        // 3 CJK runes out of 5 total → fraction exactly 0.6.
        final block = _makeBlock(left: 0, top: 0, originalText: '你好你ab');
        expect(
          resolver.overlapThresholdFor(block),
          closeTo(OverlapResolver.kCjkOverlapThreshold, 1e-9),
        );
      });

      test('short Latin text (<=8 runes) gets the stricter threshold', () {
        final block = _makeBlock(left: 0, top: 0, originalText: 'OK');
        expect(
          resolver.overlapThresholdFor(block),
          closeTo(OverlapResolver.kShortLatinOverlapThreshold, 1e-9),
        );
      });

      test('exactly 8 Latin runes is still "short" (<= boundary)', () {
        final block = _makeBlock(left: 0, top: 0, originalText: 'ABCDEFGH');
        expect(
          resolver.overlapThresholdFor(block),
          closeTo(OverlapResolver.kShortLatinOverlapThreshold, 1e-9),
        );
      });

      test('9 Latin runes falls back to the default threshold', () {
        final block = _makeBlock(left: 0, top: 0, originalText: 'ABCDEFGHI');
        expect(
          resolver.overlapThresholdFor(block),
          closeTo(OverlapResolver.kDefaultOverlapThreshold, 1e-9),
        );
      });

      test('longer Latin text gets the default threshold', () {
        final block =
            _makeBlock(left: 0, top: 0, originalText: 'Hello world overlap');
        expect(
          resolver.overlapThresholdFor(block),
          closeTo(OverlapResolver.kDefaultOverlapThreshold, 1e-9),
        );
      });

      test('mixed text (0.3 <= fraction < 0.6) gets default even when short',
          () {
        // 2 CJK runes out of 6 → fraction ~0.333: not CJK-dominant, and not
        // "short Latin" because fraction is not < 0.3, despite only 6 runes.
        final block = _makeBlock(left: 0, top: 0, originalText: '你好abcd');
        expect(
          resolver.overlapThresholdFor(block),
          closeTo(OverlapResolver.kDefaultOverlapThreshold, 1e-9),
        );
      });

      test('short text with CJK fraction just under 0.3 is "short Latin"', () {
        // 2 CJK runes out of 8 → fraction 0.25 < 0.3, 8 runes <= 8.
        final block = _makeBlock(left: 0, top: 0, originalText: '你好abcdef');
        expect(
          resolver.overlapThresholdFor(block),
          closeTo(OverlapResolver.kShortLatinOverlapThreshold, 1e-9),
        );
      });

      test('empty text is treated as short Latin (fraction 0.0, 0 runes)', () {
        final block = _makeBlock(left: 0, top: 0, originalText: '');
        expect(
          resolver.overlapThresholdFor(block),
          closeTo(OverlapResolver.kShortLatinOverlapThreshold, 1e-9),
        );
      });
    });

    // ┌─────────────────────────────────────────────────────────────────
    // overlapRatio
    // ┌─────────────────────────────────────────────────────────────────

    group('overlapRatio', () {
      test('identical rects give ratio 1.0', () {
        final a = _makeBlock(left: 0, top: 0, width: 100, height: 50);
        final b = _makeBlock(left: 0, top: 0, width: 100, height: 50);
        expect(resolver.overlapRatio(a, b, 0), closeTo(1.0, 1e-9));
      });

      test('disjoint rects give ratio 0.0', () {
        final a = _makeBlock(left: 0, top: 0, width: 100, height: 50);
        final b = _makeBlock(left: 500, top: 500, width: 100, height: 50);
        expect(resolver.overlapRatio(a, b, 0), closeTo(0.0, 1e-9));
      });

      test('half-overlapping equal rects give ratio 0.5', () {
        // a: x 0..100, b: x 50..150, both y 0..100.
        // Overlap = 50 × 100 = 5000; smaller area = 100 × 100 = 10000.
        final a = _makeBlock(left: 0, top: 0, width: 100, height: 100);
        final b = _makeBlock(left: 50, top: 0, width: 100, height: 100);
        expect(resolver.overlapRatio(a, b, 0), closeTo(0.5, 1e-9));
      });

      test('drift margin expands only the first block\'s rect', () {
        // Same geometry as above with dm=10:
        // oLeft = max(0-10, 50) = 50, oRight = min(100+10, 150) = 110 → 60
        // oTop = max(-10, 0) = 0, oBottom = min(110, 100) = 100 → 100
        // ratio = 6000 / 10000 = 0.6
        final a = _makeBlock(left: 0, top: 0, width: 100, height: 100);
        final b = _makeBlock(left: 50, top: 0, width: 100, height: 100);
        expect(resolver.overlapRatio(a, b, 10), closeTo(0.6, 1e-9));
      });

      test('ratio is clamped to 1.0 when margin inflates past smaller area',
          () {
        // Small block fully inside big block, dm=5:
        // overlap = 30 × 30 = 900, smaller area = 20 × 20 = 400 → raw 2.25.
        final a = _makeBlock(left: 10, top: 10, width: 20, height: 20);
        final b = _makeBlock(left: 0, top: 0, width: 100, height: 100);
        expect(resolver.overlapRatio(a, b, 5), closeTo(1.0, 1e-9));
      });

      test('zero-area block gives ratio 0.0 even with margin-created overlap',
          () {
        // dm=5 creates a nonzero intersection strip, but the smaller block
        // area is 0 × 50 = 0, so the ratio is defined as 0.0.
        final a = _makeBlock(left: 50, top: 0, width: 0, height: 50);
        final b = _makeBlock(left: 0, top: 0, width: 100, height: 50);
        expect(resolver.overlapRatio(a, b, 5), closeTo(0.0, 1e-9));
      });

      test('IC blocks compare in scroller-relative Y', () {
        // Absolute rects are 200px apart vertically, but both blocks sit at
        // relative top 0 inside their scrollers → full overlap.
        final a = _makeBlock(
          left: 0,
          top: 100,
          isInnerScrollerChild: true,
          innerScrollerTop: 100,
        );
        final b = _makeBlock(
          left: 0,
          top: 300,
          isInnerScrollerChild: true,
          innerScrollerTop: 300,
        );
        expect(resolver.overlapRatio(a, b, 0), closeTo(1.0, 1e-9));
      });

      test('mixed IC / non-IC pair compares in absolute Y', () {
        // Only one block is an inner-scroller child, so absolute tops
        // (100 vs 300) are used and the rects do not intersect.
        final a = _makeBlock(
          left: 0,
          top: 100,
          isInnerScrollerChild: true,
          innerScrollerTop: 100,
        );
        final b = _makeBlock(left: 0, top: 300);
        expect(resolver.overlapRatio(a, b, 0), closeTo(0.0, 1e-9));
      });
    });

    // ┌─────────────────────────────────────────────────────────────────
    // checkOverlap
    // ┌─────────────────────────────────────────────────────────────────

    group('checkOverlap', () {
      test('identical rects match at default threshold', () {
        final n = _makeBlock(left: 0, top: 0);
        final e = _makeBlock(left: 0, top: 0);
        final match = resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 0);
        expect(match, same(e));
      });

      test('far-apart rects return null', () {
        final n = _makeBlock(left: 0, top: 0);
        final e = _makeBlock(left: 1000, top: 1000);
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 0), isNull);
      });

      test('overlap ratio exactly at threshold matches (>= comparison)', () {
        // Overlap ratio is exactly 0.5 (see overlapRatio test above).
        final n = _makeBlock(left: 0, top: 0, width: 100, height: 100);
        final e = _makeBlock(left: 50, top: 0, width: 100, height: 100);
        expect(
          resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 0),
          same(e),
        );
      });

      test('overlap ratio just below threshold returns null', () {
        final n = _makeBlock(left: 0, top: 0, width: 100, height: 100);
        final e = _makeBlock(left: 50, top: 0, width: 100, height: 100);
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.51, 0), isNull);
      });

      test('VR existing never matches non-VR incoming (coordinate contracts)',
          () {
        final n = _makeBlock(left: 0, top: 0);
        final e = _makeBlock(left: 0, top: 0, isViewportRelative: true);
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 0), isNull);
      });

      test('VR incoming never matches non-VR existing (coordinate contracts)',
          () {
        final n = _makeBlock(left: 0, top: 0, isViewportRelative: true);
        final e = _makeBlock(left: 0, top: 0);
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 0), isNull);
      });

      test('two VR blocks can match each other', () {
        final n = _makeBlock(left: 0, top: 0, isViewportRelative: true);
        final e = _makeBlock(left: 0, top: 0, isViewportRelative: true);
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 0), same(e));
      });

      test('blocks in different carousels never match', () {
        final n = _makeBlock(
          left: 0,
          top: 0,
          isHorizontalScrollChild: true,
          hzScrollerIndex: 0,
        );
        final e = _makeBlock(
          left: 0,
          top: 0,
          isHorizontalScrollChild: true,
          hzScrollerIndex: 1,
        );
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 0), isNull);
      });

      test('blocks in the same carousel can match', () {
        final n = _makeBlock(
          left: 0,
          top: 0,
          isHorizontalScrollChild: true,
          hzScrollerIndex: 0,
        );
        final e = _makeBlock(
          left: 0,
          top: 0,
          isHorizontalScrollChild: true,
          hzScrollerIndex: 0,
        );
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 0), same(e));
      });

      test('carousel gate only applies when BOTH blocks are carousel children',
          () {
        // Only the existing block is a carousel child → the carousel check
        // is skipped and the identical rects match.
        final n = _makeBlock(left: 0, top: 0);
        final e = _makeBlock(
          left: 0,
          top: 0,
          isHorizontalScrollChild: true,
          hzScrollerIndex: 3,
        );
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 0), same(e));
      });

      test('edge-touching rects with zero drift margin do not match', () {
        // Center distance dx = 100 equals (w1+w2)/2 + dm = 100 → rejected
        // by the >= center pre-check.
        final n = _makeBlock(left: 0, top: 0, width: 100, height: 100);
        final e = _makeBlock(left: 100, top: 0, width: 100, height: 100);
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 0), isNull);
      });

      test('drift margin bridges edge-touching rects (ratio 0.1 at dm=10)', () {
        // dm=10: intersection strip = 10 × 100 = 1000, smaller = 10000
        // → ratio exactly 0.1, matched at threshold 0.1.
        final n = _makeBlock(left: 0, top: 0, width: 100, height: 100);
        final e = _makeBlock(left: 100, top: 0, width: 100, height: 100);
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.1, 10), same(e));
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 10), isNull);
      });

      test('IC blocks match via scroller-relative Y despite absolute gap', () {
        final n = _makeBlock(
          left: 0,
          top: 100,
          isInnerScrollerChild: true,
          innerScrollerTop: 100,
        );
        final e = _makeBlock(
          left: 0,
          top: 300,
          isInnerScrollerChild: true,
          innerScrollerTop: 300,
        );
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 0), same(e));
      });

      test('IC vs non-IC pair falls back to absolute Y and misses', () {
        final n = _makeBlock(
          left: 0,
          top: 100,
          isInnerScrollerChild: true,
          innerScrollerTop: 100,
        );
        final e = _makeBlock(left: 0, top: 300);
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.5, 0), isNull);
      });

      test('zero-area new block never matches (smaller area guard)', () {
        // dm=5 produces a nonzero intersection, but smallerArea is 0.
        final n = _makeBlock(left: 50, top: 0, width: 0, height: 50);
        final e = _makeBlock(left: 0, top: 0, width: 100, height: 50);
        expect(resolver.checkOverlap(n, n.absoluteRect, e, 0.1, 5), isNull);
      });
    });

    // ┌─────────────────────────────────────────────────────────────────
    // qualityScore
    // ┌─────────────────────────────────────────────────────────────────

    group('qualityScore', () {
      test('both confidences at 0.0 boundary give 0.0', () {
        final block = _makeBlock(
          left: 0,
          top: 0,
          positionConfidence: 0.0,
          textConfidence: 0.0,
        );
        expect(OverlapResolver.qualityScore(block), closeTo(0.0, 1e-9));
      });

      test('both confidences at 1.0 boundary give 1.0', () {
        final block = _makeBlock(
          left: 0,
          top: 0,
          positionConfidence: 1.0,
          textConfidence: 1.0,
        );
        expect(OverlapResolver.qualityScore(block), closeTo(1.0, 1e-9));
      });

      test('position confidence is weighted 0.4', () {
        final block = _makeBlock(
          left: 0,
          top: 0,
          positionConfidence: 1.0,
          textConfidence: 0.0,
        );
        expect(OverlapResolver.qualityScore(block), closeTo(0.4, 1e-9));
      });

      test('text confidence is weighted 0.6 (higher than position)', () {
        final block = _makeBlock(
          left: 0,
          top: 0,
          positionConfidence: 0.0,
          textConfidence: 1.0,
        );
        expect(OverlapResolver.qualityScore(block), closeTo(0.6, 1e-9));
      });

      test('mixed confidences combine linearly: 0.25/0.75 → 0.55', () {
        // 0.25 * 0.4 + 0.75 * 0.6 = 0.1 + 0.45 = 0.55
        final block = _makeBlock(
          left: 0,
          top: 0,
          positionConfidence: 0.25,
          textConfidence: 0.75,
        );
        expect(OverlapResolver.qualityScore(block), closeTo(0.55, 1e-9));
      });
    });

    // ┌─────────────────────────────────────────────────────────────────
    // resolveOverlap — A. hierarchy weight
    // ┌─────────────────────────────────────────────────────────────────

    group('resolveOverlap: hierarchy weight', () {
      test('higher-weight incoming (VR 40 vs normal 10) evicts instantly', () {
        final incoming = _makeBlock(left: 0, top: 0, isViewportRelative: true);
        final existing = _makeBlock(left: 0, top: 0);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.1,
          ),
          OverlapResult.evict,
        );
      });

      test('lower-weight incoming (normal 10 vs VR 40) is dropped', () {
        final incoming = _makeBlock(left: 0, top: 0);
        final existing = _makeBlock(left: 0, top: 0, isViewportRelative: true);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.1,
          ),
          OverlapResult.drop,
        );
      });

      test('constrained incoming (IC 20) evicts normal existing (10)', () {
        final incoming = _makeBlock(
          left: 0,
          top: 0,
          isInnerScrollerChild: true,
        );
        final existing = _makeBlock(left: 0, top: 0);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.1,
          ),
          OverlapResult.evict,
        );
      });
    });

    // ┌─────────────────────────────────────────────────────────────────
    // resolveOverlap — B. David and Goliath
    // ┌─────────────────────────────────────────────────────────────────

    group('resolveOverlap: David and Goliath', () {
      test('giantAreaFence: existing above fence is evicted at equal quality',
          () {
        // Equal weight, equal quality (0.5 each), low overlap ratio (0.4)
        // so strategy C alone would keep. Fence 4000 < existing area 5000
        // → giant → evict.
        final incoming = _makeBlock(left: 0, top: 0, width: 100, height: 50);
        final existing = _makeBlock(left: 60, top: 0, width: 100, height: 50);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.1,
            giantAreaFence: 4000,
          ),
          OverlapResult.evict,
        );
      });

      test('same geometry without fence is kept (not giant, C keeps)', () {
        // existing area 5000 is not > 3 × incoming area (15000), and in
        // strategy C the overlap ratio is 2000/5000 = 0.4 < 0.70, so the
        // confidenceMad margin applies: 0.5 >= 0.5 + 0.1 is false → keep.
        final incoming = _makeBlock(left: 0, top: 0, width: 100, height: 50);
        final existing = _makeBlock(left: 60, top: 0, width: 100, height: 50);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.1,
          ),
          OverlapResult.keep,
        );
      });

      test('area-ratio fallback: existing > 3x incoming area is evicted', () {
        // incoming area 2500; existing area 20000 > 3 × 2500 = 7500.
        // Overlap ratio = (10 × 50) / 2500 = 0.2 < 0.70, so strategy C
        // alone would keep (0.5 >= 0.5 + 0.1 false) — eviction proves the
        // giant fallback fired.
        final incoming = _makeBlock(left: 0, top: 0, width: 50, height: 50);
        final existing = _makeBlock(left: 40, top: 0, width: 200, height: 100);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.1,
          ),
          OverlapResult.evict,
        );
      });

      test('giant is NOT evicted by a lower-quality incoming', () {
        // Same fence geometry as the first test but incoming quality
        // 0.4 < existing 0.5 → B requires incoming >= existing → skipped;
        // C: 0.4 >= 0.5 + 0.1 is false → keep.
        final incoming = _makeBlock(
          left: 0,
          top: 0,
          width: 100,
          height: 50,
          positionConfidence: 0.4,
          textConfidence: 0.4,
        );
        final existing = _makeBlock(left: 60, top: 0, width: 100, height: 50);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.1,
            giantAreaFence: 4000,
          ),
          OverlapResult.keep,
        );
      });
    });

    // ┌─────────────────────────────────────────────────────────────────
    // resolveOverlap — C. quality + overlap ratio
    // ┌─────────────────────────────────────────────────────────────────

    group('resolveOverlap: quality + overlap ratio', () {
      test('high overlap (>= 0.70): equal quality evicts (zero margin)', () {
        // Identical rects → ratio 1.0 → qualityMargin 0.0 even though
        // confidenceMad is large; 0.5 >= 0.5 + 0.0 → evict.
        final incoming = _makeBlock(left: 0, top: 0);
        final existing = _makeBlock(left: 0, top: 0);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.5,
          ),
          OverlapResult.evict,
        );
      });

      test('high overlap: lower-quality incoming is kept', () {
        final incoming = _makeBlock(
          left: 0,
          top: 0,
          positionConfidence: 0.4,
          textConfidence: 0.4,
        );
        final existing = _makeBlock(left: 0, top: 0);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.1,
          ),
          OverlapResult.keep,
        );
      });

      test('overlap ratio exactly 0.70 uses zero margin (>= boundary)', () {
        // x overlap 30..100 = 70 → ratio 7000/10000 = 0.70 exactly.
        // Equal areas → no giant; equal quality with mad 0.3 would keep if
        // the margin applied — eviction proves margin collapsed to 0.
        final incoming = _makeBlock(left: 0, top: 0, width: 100, height: 100);
        final existing = _makeBlock(left: 30, top: 0, width: 100, height: 100);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.3,
          ),
          OverlapResult.evict,
        );
      });

      test('low overlap: incoming must beat existing + confidenceMad', () {
        // ratio 0.4 < 0.70 → margin = 0.1. Incoming quality 1.0 >= 0.5 + 0.1
        // → evict. (Areas equal, so the giant path cannot fire.)
        final incoming = _makeBlock(
          left: 0,
          top: 0,
          width: 100,
          height: 50,
          positionConfidence: 1.0,
          textConfidence: 1.0,
        );
        final existing = _makeBlock(left: 60, top: 0, width: 100, height: 50);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.1,
          ),
          OverlapResult.evict,
        );
      });

      test('low overlap with zero confidenceMad: equal quality evicts', () {
        final incoming = _makeBlock(left: 0, top: 0, width: 100, height: 50);
        final existing = _makeBlock(left: 60, top: 0, width: 100, height: 50);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.0,
          ),
          OverlapResult.evict,
        );
      });

      test('stability bias: existing wins ties under a nonzero margin', () {
        // Low overlap, equal quality, mad > 0 → keep (existing retained).
        final incoming = _makeBlock(left: 0, top: 0, width: 100, height: 50);
        final existing = _makeBlock(left: 60, top: 0, width: 100, height: 50);
        expect(
          resolver.resolveOverlap(
            incoming: incoming,
            existing: existing,
            driftMargin: 0,
            confidenceMad: 0.2,
          ),
          OverlapResult.keep,
        );
      });
    });
  });
}
