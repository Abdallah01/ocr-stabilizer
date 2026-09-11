// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  group('BlockMeta', () {
    test('required fields are stored correctly', () {
      final meta = BlockMeta(
        positionConfidence: PositionConfidence.from(0.85),
        textConfidence: TextConfidence.from(0.92),
        coordinates: const CoordinateContext.page(
          scroll: ScrollContext(scrollY: 500, scrollX: 100, hzScrollerIndex: 2),
        ),
      );
      expect(meta.isViewportRelative, isFalse);
      expect(meta.isHorizontalScrollChild, isTrue);
      expect(meta.captureScrollY, 500.0);
      expect(meta.captureScrollX, 100.0);
      expect(meta.hzScrollerIndex, 2);
      expect(meta.positionConfidence.raw, 0.85);
      expect(meta.textConfidence.raw, 0.92);
    });

    test('optional fields have correct defaults', () {
      final meta = BlockMeta(
        positionConfidence: PositionConfidence.from(0.5),
        textConfidence: TextConfidence.from(0.5),
        coordinates: CoordinateContext.page(scroll: ScrollContext.none),
      );
      expect(meta.isFromStickyElement, isFalse);
      expect(meta.stickyFallbackScrollY, 0.0);
      expect(meta.stickyFallbackIsIc, isFalse);
      expect(meta.stickyFallbackScrollX, 0.0);
      expect(meta.stickyFallbackHzIndex, -1);
      expect(meta.containerId, isNull);
      expect(meta.isHorizontalScrollChild, isFalse);
    });

    test('containerId is threaded through', () {
      final meta = BlockMeta(
        positionConfidence: PositionConfidence.from(0.7),
        textConfidence: TextConfidence.from(0.8),
        coordinates: CoordinateContext.innerScroller(
            top: 200.0,
            containerId: const ContainerId('sidebar_abc'),
            scroll: const ScrollContext(scrollY: 100.0)),
      );
      expect(meta.containerId, const ContainerId('sidebar_abc'));
      expect(meta.isInnerScrollerChild, isTrue);
      expect(meta.innerScrollerTop, 200.0);
    });

    test('sticky fallback fields are stored via StickyFallback', () {
      final meta = BlockMeta(
        positionConfidence: PositionConfidence.from(0.9),
        textConfidence: TextConfidence.from(0.95),
        coordinates: CoordinateContext.viewport(
            stickyFallback: const StickyFallback(
          scrollY: 300.0,
          scrollX: 50.0,
          isIc: true,
          hzScrollerIndex: 1,
        )),
      );
      expect(meta.isFromStickyElement, isTrue);
      expect(meta.stickyFallbackScrollY, 300.0);
      expect(meta.stickyFallbackIsIc, isTrue);
      expect(meta.stickyFallbackScrollX, 50.0);
      expect(meta.stickyFallbackHzIndex, 1);
    });

    test(
      'isHorizontalScrollChild is true when hzScrollerIndex >= 0 and not VR',
      () {
        final meta = BlockMeta(
          positionConfidence: PositionConfidence.from(0.5),
          textConfidence: TextConfidence.from(0.5),
          coordinates: CoordinateContext.page(
              scroll: const ScrollContext(hzScrollerIndex: 0)),
        );
        expect(meta.isHorizontalScrollChild, isTrue);
      },
    );

    test(
      'isHorizontalScrollChild is false when VR even with hzScrollerIndex >= 0',
      () {
        final meta = BlockMeta(
          positionConfidence: PositionConfidence.from(0.5),
          textConfidence: TextConfidence.from(0.5),
          coordinates: const CoordinateContext.viewport(),
        );
        expect(meta.isHorizontalScrollChild, isFalse);
      },
    );
  });
}
