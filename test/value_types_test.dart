// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// ignore_for_file: unused_element_parameter

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// VALUE TYPE TESTS
// =============================================================================
// HierarchyWeightX / HierarchyTiers, ScrollContext, StickyFallback.
// =============================================================================

/// Minimal test block for package-level hierarchy weight tests.
class _TestBlock implements TrackedBlock<Never> {
  // 3.0 (#147): the engine reads the frame through this one getter; the
  // flat fields below stay as this fixture's construction convenience.
  @override
  CoordinateContext get coordinates => CoordinateContext.fromFlags(
        isViewportRelative: isViewportRelative,
        isInnerScrollerChild: isInnerScrollerChild,
        innerScrollerTop: innerScrollerTop,
        isHorizontalScrollChild: isHorizontalScrollChild,
        containerId: containerId,
        scrollContext: scrollContext,
        isFromStickyElement: isFromStickyElement,
        stickyFallback: stickyFallback,
      );
  @override
  final AbsoluteRect absoluteRect;
  final bool isViewportRelative;
  final bool isInnerScrollerChild;
  final double innerScrollerTop;
  final ContainerId? containerId;
  final bool isHorizontalScrollChild;
  @override
  Never get payload => throw UnsupportedError('_TestBlock has no payload');

  @override
  final String originalText;
  final double captureScrollY;
  final double captureScrollX;
  final int hzScrollerIndex;
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

  ScrollContext get scrollContext => ScrollContext(
        scrollY: captureScrollY,
        scrollX: captureScrollX,
        hzScrollerIndex: hzScrollerIndex,
      );

  StickyFallback get stickyFallback => StickyFallback(
        scrollY: stickyFallbackScrollY,
        scrollX: stickyFallbackScrollX,
        isIc: stickyFallbackIsIc,
        hzScrollerIndex: stickyFallbackHzIndex,
      );
}

_TestBlock _makeBlock({
  bool isViewportRelative = false,
  bool isInnerScrollerChild = false,
  bool isHorizontalScrollChild = false,
}) {
  return _TestBlock(
    absoluteRect: AbsoluteRect.fromLTWH(100, 100, 200, 20),
    isViewportRelative: isViewportRelative,
    isInnerScrollerChild: isInnerScrollerChild,
    isHorizontalScrollChild: isHorizontalScrollChild,
    hzScrollerIndex: isHorizontalScrollChild ? 0 : -1,
  );
}

void main() {
  group('HierarchyTiers', () {
    test('tier constants are 40 / 30 / 20 / 10', () {
      expect(HierarchyTiers.viewport, 40);
      expect(HierarchyTiers.nested, 30);
      expect(HierarchyTiers.constrained, 20);
      expect(HierarchyTiers.normal, 10);
    });
  });

  group('HierarchyWeightX.hierarchyWeight', () {
    test('normal block -> 10', () {
      expect(_makeBlock().hierarchyWeight, 10);
      expect(_makeBlock().hierarchyWeight, HierarchyTiers.normal);
    });

    test('viewport-relative block -> 40', () {
      final block = _makeBlock(isViewportRelative: true);
      expect(block.hierarchyWeight, 40);
      expect(block.hierarchyWeight, HierarchyTiers.viewport);
    });

    test('inner-scroller child only -> 20', () {
      final block = _makeBlock(isInnerScrollerChild: true);
      expect(block.hierarchyWeight, 20);
      expect(block.hierarchyWeight, HierarchyTiers.constrained);
    });

    test('carousel child only -> 20', () {
      final block = _makeBlock(isHorizontalScrollChild: true);
      expect(block.hierarchyWeight, 20);
      expect(block.hierarchyWeight, HierarchyTiers.constrained);
    });

    test('nested inner-scroller + carousel -> 30', () {
      final block = _makeBlock(
        isInnerScrollerChild: true,
        isHorizontalScrollChild: true,
      );
      expect(block.hierarchyWeight, 30);
      expect(block.hierarchyWeight, HierarchyTiers.nested);
    });

    test('viewport-relative -> 40', () {
      // 3.0 (#147): viewport + inner-scroller/carousel is unrepresentable,
      // so "wins over all other flags" is no longer a reachable case.
      final block = _makeBlock(isViewportRelative: true);
      expect(block.hierarchyWeight, HierarchyTiers.viewport);
    });
  });

  group('ScrollContext', () {
    test('defaults represent no scroll, no carousel', () {
      const ctx = ScrollContext();
      expect(ctx.scrollY, 0);
      expect(ctx.scrollX, 0);
      expect(ctx.hzScrollerIndex, -1);
    });

    test('none sentinel equals a default-constructed context', () {
      expect(ScrollContext.none, const ScrollContext());
    });

    test('equal field values compare equal with equal hashCodes', () {
      const a = ScrollContext(scrollY: 10, scrollX: 5, hzScrollerIndex: 2);
      const b = ScrollContext(scrollY: 10, scrollX: 5, hzScrollerIndex: 2);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('non-const instances with equal values are equal', () {
      // ignore: prefer_const_constructors
      final a = ScrollContext(scrollY: 1, scrollX: 2, hzScrollerIndex: 3);
      // ignore: prefer_const_constructors
      final b = ScrollContext(scrollY: 1, scrollX: 2, hzScrollerIndex: 3);
      expect(identical(a, b), isFalse);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('differing scrollY is unequal', () {
      const a = ScrollContext(scrollY: 10);
      const b = ScrollContext(scrollY: 11);
      expect(a, isNot(equals(b)));
    });

    test('differing scrollX is unequal', () {
      const a = ScrollContext(scrollX: 10);
      const b = ScrollContext(scrollX: 11);
      expect(a, isNot(equals(b)));
    });

    test('differing hzScrollerIndex is unequal', () {
      const a = ScrollContext(hzScrollerIndex: 1);
      const b = ScrollContext(hzScrollerIndex: 2);
      expect(a, isNot(equals(b)));
    });

    test('is not equal to an unrelated object', () {
      expect(const ScrollContext(), isNot(equals(Object())));
    });
  });

  group('StickyFallback', () {
    test('defaults represent no fallback context', () {
      const fb = StickyFallback();
      expect(fb.scrollY, 0);
      expect(fb.scrollX, 0);
      expect(fb.isIc, isFalse);
      expect(fb.hzScrollerIndex, -1);
    });

    test('none sentinel equals a default-constructed fallback', () {
      expect(StickyFallback.none, const StickyFallback());
    });

    test('equal field values compare equal with equal hashCodes', () {
      const a = StickyFallback(
        scrollY: 100,
        scrollX: 50,
        isIc: true,
        hzScrollerIndex: 1,
      );
      const b = StickyFallback(
        scrollY: 100,
        scrollX: 50,
        isIc: true,
        hzScrollerIndex: 1,
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('non-const instances with equal values are equal', () {
      // ignore: prefer_const_constructors
      final a = StickyFallback(scrollY: 1, scrollX: 2, isIc: true);
      // ignore: prefer_const_constructors
      final b = StickyFallback(scrollY: 1, scrollX: 2, isIc: true);
      expect(identical(a, b), isFalse);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('differing scrollY is unequal', () {
      const a = StickyFallback(scrollY: 1);
      const b = StickyFallback(scrollY: 2);
      expect(a, isNot(equals(b)));
    });

    test('differing scrollX is unequal', () {
      const a = StickyFallback(scrollX: 1);
      const b = StickyFallback(scrollX: 2);
      expect(a, isNot(equals(b)));
    });

    test('differing isIc is unequal', () {
      const a = StickyFallback(isIc: true);
      const b = StickyFallback(isIc: false);
      expect(a, isNot(equals(b)));
    });

    test('differing hzScrollerIndex is unequal', () {
      const a = StickyFallback(hzScrollerIndex: 0);
      const b = StickyFallback(hzScrollerIndex: 1);
      expect(a, isNot(equals(b)));
    });

    test('is not equal to an unrelated object', () {
      expect(const StickyFallback(), isNot(equals(Object())));
    });
  });
}
