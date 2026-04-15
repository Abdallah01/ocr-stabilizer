import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  group('BlockMeta', () {
    test('required fields are stored correctly', () {
      final meta = BlockMeta(
        isViewportRelative: true,
        isInnerScrollerChild: false,
        innerScrollerTop: 0,
        captureContext: const ScrollContext(
          scrollY: 500.0,
          scrollX: 100.0,
          hzScrollerIndex: 2,
        ),
        positionConfidence: 0.85,
        textConfidence: 0.92,
      );
      expect(meta.isViewportRelative, isTrue);
      expect(meta.captureScrollY, 500.0);
      expect(meta.captureScrollX, 100.0);
      expect(meta.hzScrollerIndex, 2);
      expect(meta.positionConfidence, 0.85);
      expect(meta.textConfidence, 0.92);
    });

    test('optional fields have correct defaults', () {
      final meta = BlockMeta(
        isViewportRelative: false,
        isInnerScrollerChild: false,
        innerScrollerTop: 0,
        captureContext: ScrollContext.none,
        positionConfidence: 0.5,
        textConfidence: 0.5,
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
        isViewportRelative: false,
        isInnerScrollerChild: true,
        innerScrollerTop: 200.0,
        captureContext: const ScrollContext(scrollY: 100.0),
        positionConfidence: 0.7,
        textConfidence: 0.8,
        containerId: const ContainerId('sidebar_abc'),
      );
      expect(meta.containerId, const ContainerId('sidebar_abc'));
      expect(meta.isInnerScrollerChild, isTrue);
      expect(meta.innerScrollerTop, 200.0);
    });

    test('sticky fallback fields are stored via StickyFallback', () {
      final meta = BlockMeta(
        isViewportRelative: true,
        isInnerScrollerChild: false,
        innerScrollerTop: 0,
        captureContext: ScrollContext.none,
        isFromStickyElement: true,
        stickyFallback: const StickyFallback(
          scrollY: 300.0,
          scrollX: 50.0,
          isIc: true,
          hzScrollerIndex: 1,
        ),
        positionConfidence: 0.9,
        textConfidence: 0.95,
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
          isViewportRelative: false,
          isInnerScrollerChild: false,
          innerScrollerTop: 0,
          captureContext: const ScrollContext(hzScrollerIndex: 0),
          positionConfidence: 0.5,
          textConfidence: 0.5,
        );
        expect(meta.isHorizontalScrollChild, isTrue);
      },
    );

    test(
      'isHorizontalScrollChild is false when VR even with hzScrollerIndex >= 0',
      () {
        final meta = BlockMeta(
          isViewportRelative: true,
          isInnerScrollerChild: false,
          innerScrollerTop: 0,
          captureContext: const ScrollContext(hzScrollerIndex: 0),
          positionConfidence: 0.5,
          textConfidence: 0.5,
        );
        expect(meta.isHorizontalScrollChild, isFalse);
      },
    );
  });
}
