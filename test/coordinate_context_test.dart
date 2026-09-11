// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #147 (3.0) — `CoordinateContext` replaces the eight coordinate getters
// (`isViewportRelative`, `isInnerScrollerChild`, `innerScrollerTop`,
// `isHorizontalScrollChild`, `containerId`, `scrollContext`,
// `isFromStickyElement`, `stickyFallback`) on `Observation`. Pins:
//   (a) each variant derives the eight legacy views exactly as the
//       classifier used to populate them;
//   (b) the combinations the old flags allowed but the engine never
//       expected are unrepresentable, and `fromFlags` (the adapter for a
//       flat-flag consumer) rejects them;
//   (c) the engine reads through the views: a block type that implements
//       only `coordinates` is indexed, keyed and matched as before.

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  group('#147 CoordinateContext views', () {
    test('page: nothing set', () {
      const c = CoordinateContext.page();
      expect(c, isA<PageCoordinates>());
      expect(c.isViewportRelative, isFalse);
      expect(c.isInnerScrollerChild, isFalse);
      expect(c.innerScrollerTop, 0);
      expect(c.isHorizontalScrollChild, isFalse);
      expect(c.containerId, isNull);
      expect(c.scrollContext, ScrollContext.none);
      expect(c.isFromStickyElement, isFalse);
      expect(c.stickyFallback, StickyFallback.none);
    });

    test('page inside a carousel: the scroll context carries the index', () {
      const c = CoordinateContext.page(
          scroll: ScrollContext(scrollY: 40, scrollX: 120, hzScrollerIndex: 2));
      expect(c.isHorizontalScrollChild, isTrue);
      expect(c.scrollContext.hzScrollerIndex, 2);
      expect(c.scrollContext.scrollX, 120);
      expect(c.isInnerScrollerChild, isFalse);
    });

    test('innerScroller: top + container id, optionally a carousel', () {
      const c = CoordinateContext.innerScroller(
        top: 300,
        containerId: ContainerId('sidebar'),
        scroll: ScrollContext(scrollY: 10, hzScrollerIndex: 1),
      );
      expect(c, isA<InnerScrollerCoordinates>());
      expect(c.isInnerScrollerChild, isTrue);
      expect(c.innerScrollerTop, 300);
      expect(c.containerId, const ContainerId('sidebar'));
      expect(c.isHorizontalScrollChild, isTrue);
      expect(c.isViewportRelative, isFalse);
      expect(const CoordinateContext.innerScroller(top: 5).containerId, isNull,
          reason: 'an inner scroller without a stable id is still valid '
              '(the drift tracker files it under SpaceKey.unknown)');
    });

    test('viewport: fixed or sticky; never a carousel child', () {
      const fixed = CoordinateContext.viewport();
      expect(fixed, isA<ViewportCoordinates>());
      expect(fixed.isViewportRelative, isTrue);
      expect(fixed.isFromStickyElement, isFalse);
      expect(fixed.stickyFallback, StickyFallback.none);
      expect(fixed.isHorizontalScrollChild, isFalse);
      expect(fixed.scrollContext, ScrollContext.none,
          reason: 'a viewport-relative rect has no scroll baked in');
      const sticky = CoordinateContext.viewport(
          stickyFallback: StickyFallback(scrollY: 300, isIc: true));
      expect(sticky.isFromStickyElement, isTrue);
      expect(sticky.stickyFallback.scrollY, 300);
      expect(sticky.stickyFallback.isIc, isTrue);
    });

    test('value equality per variant', () {
      expect(const CoordinateContext.page(), const CoordinateContext.page());
      expect(const CoordinateContext.innerScroller(top: 1),
          const CoordinateContext.innerScroller(top: 1));
      expect(const CoordinateContext.innerScroller(top: 1),
          isNot(const CoordinateContext.innerScroller(top: 2)));
      expect(const CoordinateContext.viewport(),
          isNot(const CoordinateContext.page()));
      expect(const CoordinateContext.page().hashCode,
          const CoordinateContext.page().hashCode);
    });
  });

  group('#147 fromFlags (flat-flag adapter)', () {
    test("maps the classifier's three shapes", () {
      expect(CoordinateContext.fromFlags(), const CoordinateContext.page());
      expect(
        CoordinateContext.fromFlags(
          isInnerScrollerChild: true,
          innerScrollerTop: 150,
          containerId: const ContainerId('c1'),
          scrollContext: const ScrollContext(scrollY: 9),
        ),
        const CoordinateContext.innerScroller(
            top: 150,
            containerId: ContainerId('c1'),
            scroll: ScrollContext(scrollY: 9)),
      );
      expect(
        CoordinateContext.fromFlags(
          isViewportRelative: true,
          isFromStickyElement: true,
          stickyFallback: const StickyFallback(scrollY: 3),
          // hz index on a viewport block: dropped, never a carousel child
          scrollContext: const ScrollContext(hzScrollerIndex: 4),
        ),
        const CoordinateContext.viewport(
            stickyFallback: StickyFallback(scrollY: 3)),
      );
    });

    test('rejects the combinations the sealed type cannot express', () {
      // containerId without an inner scroller (the old Observation invariant)
      expect(
        () => CoordinateContext.fromFlags(containerId: const ContainerId('x')),
        throwsArgumentError,
      );
      // inner scroller + viewport at once
      expect(
        () => CoordinateContext.fromFlags(
            isViewportRelative: true, isInnerScrollerChild: true),
        throwsArgumentError,
      );
      // carousel child without a carousel index
      expect(
        () => CoordinateContext.fromFlags(isHorizontalScrollChild: true),
        throwsArgumentError,
      );
      // carousel index without the flag (a page block)
      expect(
        () => CoordinateContext.fromFlags(
            scrollContext: const ScrollContext(hzScrollerIndex: 0)),
        throwsArgumentError,
      );
      // sticky origin without a viewport frame
      expect(
        () => CoordinateContext.fromFlags(isFromStickyElement: true),
        throwsArgumentError,
      );
      // an inner-scroller top on a page block
      expect(
        () => CoordinateContext.fromFlags(innerScrollerTop: 20),
        throwsArgumentError,
      );
    });
  });

  group('#147 engine reads through the views', () {
    DefaultTrackedBlock<void> block(String text, CoordinateContext c,
            {double top = 0}) =>
        DefaultTrackedBlock<void>(
          absoluteRect: AbsoluteRect.fromLTWH(0, top, 200, 30),
          payload: null,
          originalText: text,
          coordinates: c,
        );

    test('DefaultTrackedBlock defaults to page coordinates', () {
      expect(block('hello world', const CoordinateContext.page()).coordinates,
          const CoordinateContext.page());
      expect(
          DefaultTrackedBlock<void>(
            absoluteRect: AbsoluteRect.fromLTWH(0, 0, 1, 1),
            payload: null,
          ).coordinates,
          const CoordinateContext.page());
    });

    test('a viewport block never matches a page block of the same text', () {
      final e = StabilizationEngine<DefaultTrackedBlock<void>, void>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
      );
      e.stabilize([block('hello world', const CoordinateContext.viewport())]);
      final r =
          e.stabilize([block('hello world', const CoordinateContext.page())]);
      expect(r.stableBlocks.single.observationCount, 1,
          reason: 'different frames = different identities');
      expect(r.stableBlocks.single.isViewportRelative, isFalse);
    });

    test('inner-scroller blocks are indexed in their ic: cell too', () {
      final idx = SpatialBlockIndex<DefaultTrackedBlock<void>>();
      final b = block(
          'hello world',
          const CoordinateContext.innerScroller(
              top: 400, containerId: ContainerId('c1')),
          top: 410);
      idx.add(b);
      expect(idx.icRelativeCellKey(b), startsWith('ic:'));
      expect(idx.candidates(b).toList(), [b]);
      expect(BlockKeyGenerator.prefixFor(b), 'ic:');
    });

    test('the legacy views are readable on any Observation', () {
      final b = block(
          'x',
          const CoordinateContext.page(
              scroll: ScrollContext(hzScrollerIndex: 3)));
      expect(b.isHorizontalScrollChild, isTrue);
      expect(b.scrollContext.hzScrollerIndex, 3);
      expect(BlockKeyGenerator.prefixFor(b), 'hz3:');
    });
  });
}
