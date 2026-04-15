import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  group('ClassifiedGroup', () {
    test('stores group, absoluteRect, and meta', () {
      final blocks = [
        OcrBlock(
          boundingBox: const Rect.fromLTRB(0, 0, 100, 50),
          text: '测试',
          lines: const [],
        ),
      ];
      const rect = AbsoluteRect(Rect.fromLTRB(10, 20, 60, 45));
      const meta = BlockMeta(
        isViewportRelative: false,
        isInnerScrollerChild: false,
        innerScrollerTop: 0,
        captureContext: ScrollContext(scrollY: 100),
        positionConfidence: 0.8,
        textConfidence: 0.9,
      );

      final group = ClassifiedGroup(
        group: blocks,
        absoluteRect: rect,
        meta: meta,
      );

      expect(group.group, hasLength(1));
      expect(group.group[0].text, '测试');
      expect(group.absoluteRect, rect);
      expect(group.meta.captureScrollY, 100);
    });
  });

  group('ClassificationResult', () {
    test('empty result', () {
      const result = ClassificationResult(classified: [], cssPerImagePx: 0.5);
      expect(result.classified, isEmpty);
      expect(result.cssPerImagePx, 0.5);
      expect(result.droppedExclusion, 0);
      expect(result.droppedViewport, 0);
      expect(result.deferredAnimating, 0);
    });

    test('non-empty result with stats', () {
      final blocks = [
        OcrBlock(
          boundingBox: const Rect.fromLTRB(0, 0, 100, 50),
          text: 'abc',
          lines: const [],
        ),
      ];
      const meta = BlockMeta(
        isViewportRelative: false,
        isInnerScrollerChild: false,
        innerScrollerTop: 0,
        captureContext: ScrollContext(scrollY: 200),
        positionConfidence: 0.7,
        textConfidence: 0.8,
      );
      final group = ClassifiedGroup(
        group: blocks,
        absoluteRect: const AbsoluteRect(Rect.fromLTRB(0, 200, 50, 225)),
        meta: meta,
      );

      final result = ClassificationResult(
        classified: [group],
        cssPerImagePx: 0.25,
        droppedExclusion: 3,
        droppedViewport: 1,
        deferredAnimating: 2,
      );

      expect(result.classified, hasLength(1));
      expect(result.cssPerImagePx, 0.25);
      expect(result.droppedExclusion, 3);
      expect(result.droppedViewport, 1);
      expect(result.deferredAnimating, 2);
    });
  });
}
