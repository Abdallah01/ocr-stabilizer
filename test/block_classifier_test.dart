// ignore_for_file: unused_element_parameter

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// ── Helpers ──

OcrBlock _fakeBlock(Rect bbox, String text) {
  return OcrBlock(text: text, lines: const [], boundingBox: bbox);
}

/// Minimal ClassificationInput for testing.
class _TestInput implements ClassificationInput {
  @override
  final double scrollY;
  @override
  final double scrollX;
  @override
  final double imageToLayoutScale;
  @override
  final double viewportHeight;
  @override
  final double viewportPageTop;
  @override
  final bool hasInnerScroller;
  @override
  final double innerScrollerTop;
  @override
  final double innerScrollerHeight;
  @override
  final List<double>? innerScrollerTransform;
  @override
  final ContainerId? innerScrollerContainerId;
  @override
  final List<CarouselInput> carousels;
  @override
  final DateTime captureTime;

  _TestInput({
    this.scrollY = 100,
    this.scrollX = 0,
    this.imageToLayoutScale = 2.0,
    this.viewportHeight = 800,
    this.viewportPageTop = 100,
    this.hasInnerScroller = false,
    this.innerScrollerTop = 0,
    this.innerScrollerHeight = 0,
    this.innerScrollerTransform,
    this.innerScrollerContainerId,
    this.carousels = const [],
    DateTime? captureTime,
  }) : captureTime = captureTime ?? DateTime.now();
}

class _TestCarousel implements CarouselInput {
  @override
  final Rect rect;
  @override
  final double scrollLeft;
  @override
  final List<double>? transform;
  @override
  final bool isAnimating;

  _TestCarousel({
    required this.rect,
    this.scrollLeft = 0,
    this.transform,
    this.isAnimating = false,
  });
}

void main() {
  late BlockClassifierService classifier;

  setUp(() {
    classifier = BlockClassifierService();
  });

  // ── 1. Empty input ──

  group('classifyGroups', () {
    test('empty textGroups returns empty result', () {
      final result = classifier.classifyGroups(
        textGroups: [],
        input: _TestInput(),
        fixedStickyRects: [],
      );
      expect(result.classified, isEmpty);
      expect(result.droppedExclusion, 0);
      expect(result.droppedViewport, 0);
      expect(result.deferredAnimating, 0);
    });

    // ── 2. Normal group classification ──

    test('single normal group classified with correct scroll offsets', () {
      // Block at image coords (100,100)-(200,150) with scale=2.0
      // → CSS coords (50,50)-(100,75)
      // Normal block: captureScrollY = vvPageTop = 200
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '测试');

      final result = classifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(viewportPageTop: 200),
        fixedStickyRects: [],
      );

      expect(result.classified, hasLength(1));
      final cg = result.classified[0];
      expect(cg.meta.isViewportRelative, isFalse);
      expect(cg.meta.captureScrollY, 200.0);
      expect(cg.meta.captureScrollX, 0.0);
    });

    test('multiple groups each classified independently', () {
      final block1 = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '测试一');
      final block2 = _fakeBlock(const Rect.fromLTRB(100, 300, 200, 350), '测试二');

      final result = classifier.classifyGroups(
        textGroups: [
          [block1],
          [block2],
        ],
        input: _TestInput(viewportPageTop: 200),
        fixedStickyRects: [],
      );

      expect(result.classified, hasLength(2));
      expect(result.classified[0].meta.captureScrollY, 200.0);
      expect(result.classified[1].meta.captureScrollY, 200.0);
    });

    // ── 3. Fixed/sticky classification ──

    test('group inside fixed rect is viewport-relative', () {
      // Block CSS coords: (50,50)-(100,75), center = (75, 62.5)
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '测试');
      // Fixed rect covering (0,0)-(200,200) in CSS px
      final fixedRect = const Rect.fromLTRB(0, 0, 200, 200);

      final result = classifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(),
        fixedStickyRects: [fixedRect],
      );

      expect(result.classified, hasLength(1));
      expect(result.classified[0].meta.isViewportRelative, isTrue);
      expect(result.classified[0].meta.captureScrollY, 0.0);
      expect(result.classified[0].meta.captureScrollX, 0.0);
    });

    test('sticky element sets isFromStickyElement', () {
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '测试');
      final stickyRect = const Rect.fromLTRB(0, 0, 200, 200);

      final result = classifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(),
        fixedStickyRects: [stickyRect],
        // false = sticky (not fixed)
        fixedStickyIsFixed: [false],
      );

      expect(result.classified[0].meta.isFromStickyElement, isTrue);
    });

    // ── 4. Exclusion zones ──

    test('block ≥50% inside exclusion rect is dropped', () {
      // Block CSS = (50,50)-(150,100), 100×50 = 5000 area
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 300, 200), '测试代码');
      // Exclusion covers right 60%: (90,0)-(200,200)
      // intersection = (90,50)-(150,100) = 60×50 = 3000, overlap = 60%
      final exclusionRect = const Rect.fromLTRB(90, 0, 200, 200);

      final result = classifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(),
        fixedStickyRects: [],
        exclusionRects: [exclusionRect],
      );

      expect(result.classified, isEmpty);
      expect(result.droppedExclusion, 1);
    });

    test('block <50% inside exclusion rect passes', () {
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 300, 200), '测试内容');
      // Exclusion covers left 40%: (0,0)-(90,200)
      final exclusionRect = const Rect.fromLTRB(0, 0, 90, 200);

      final result = classifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(),
        fixedStickyRects: [],
        exclusionRects: [exclusionRect],
      );

      expect(result.classified, hasLength(1));
    });

    // ── 5. Custom exclusion threshold ──

    test('custom exclusionOverlapThreshold changes exclusion boundary', () {
      final strictClassifier = BlockClassifierService(
        exclusionOverlapThreshold: 0.7,
      );
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 300, 200), '测试代码');
      // 60% overlap — would be dropped at default 0.5 but passes at 0.7
      final exclusionRect = const Rect.fromLTRB(90, 0, 200, 200);

      final result = strictClassifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(),
        fixedStickyRects: [],
        exclusionRects: [exclusionRect],
      );

      expect(
        result.classified,
        hasLength(1),
        reason: '60% overlap < 0.7 threshold → should pass',
      );
    });

    // ── 6. Carousel detection ──

    test('group inside carousel is horizontal-scroll child', () {
      // Block CSS center = (75, 62.5) — inside carousel rect
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '滑动内容');
      final carousel = _TestCarousel(rect: const Rect.fromLTRB(0, 0, 200, 200));

      final result = classifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(carousels: [carousel]),
        fixedStickyRects: [],
      );

      expect(result.classified, hasLength(1));
      expect(result.classified[0].meta.isHorizontalScrollChild, isTrue);
      expect(result.classified[0].meta.hzScrollerIndex, 0);
    });

    // ── 7. Carousel animation deferral ──

    test('block in animating carousel is deferred', () {
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '动画中');
      final carousel = _TestCarousel(
        rect: const Rect.fromLTRB(0, 0, 200, 200),
        isAnimating: true,
      );

      final result = classifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(carousels: [carousel]),
        fixedStickyRects: [],
      );

      expect(result.classified, isEmpty);
      expect(result.deferredAnimating, 1);
    });

    test('block in non-animating carousel classified normally', () {
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '滑动内容');
      final carousel = _TestCarousel(
        rect: const Rect.fromLTRB(0, 0, 200, 200),
        isAnimating: false,
      );

      final result = classifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(carousels: [carousel]),
        fixedStickyRects: [],
      );

      expect(result.classified, hasLength(1));
      expect(result.classified[0].meta.isHorizontalScrollChild, isTrue);
    });

    // ── 8. Inner-scroller detection ──

    test('group inside inner-scroller is IC child with containerId', () {
      // Block CSS center = (75, 62.5)
      // IC viewport: icRectTop - vvPageTop = 0 - 100 = -100
      //   → icBottom = -100 + 600 = 500 → cy=62.5 is inside
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '内容');

      final result = classifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(
          hasInnerScroller: true,
          innerScrollerTop: 0,
          innerScrollerHeight: 600,
          innerScrollerContainerId: const ContainerId('sidebar_abc'),
        ),
        fixedStickyRects: [],
      );

      expect(result.classified, hasLength(1));
      final meta = result.classified[0].meta;
      expect(meta.isInnerScrollerChild, isTrue);
      expect(meta.containerId, const ContainerId('sidebar_abc'));
    });

    // ── 9. Viewport guard ──

    test('oversized phantom block is dropped by viewport guard', () {
      // Block that spans 70% of viewport height
      // viewportHeight=800, scale=2.0 → CSS height = 1200/2 = 600
      // 600 > 800*0.6=480 → dropped
      final block = _fakeBlock(const Rect.fromLTRB(0, 0, 200, 1200), '巨大幻影块');

      final result = classifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(viewportHeight: 800),
        fixedStickyRects: [],
      );

      expect(result.classified, isEmpty);
      expect(result.droppedViewport, 1);
    });

    // ── 10. Confidence with positionLookup ──

    test('positionLookup provides stability for confidence scoring', () {
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '测试');

      // Known prior position close to where the block will be
      final result = classifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(),
        fixedStickyRects: [],
        positionLookup: (text) =>
            const Offset(150, 175), // near expected position
      );

      expect(result.classified, hasLength(1));
      final conf = result.classified[0].meta.positionConfidence;
      // With a close prior position, stability should be high
      expect(conf, greaterThan(0.5));
    });

    // ── 11. positionLookup null → valid result ──

    test(
      'positionLookup null produces valid result with neutral stability',
      () {
        final block = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '测试');

        final result = classifier.classifyGroups(
          textGroups: [
            [block],
          ],
          input: _TestInput(),
          fixedStickyRects: [],
          positionLookup: null,
        );

        expect(result.classified, hasLength(1));
        // stability=0.5 (null delta) → posConf = freshness*0.5 + 0.5*0.5
        final conf = result.classified[0].meta.positionConfidence;
        expect(conf, greaterThanOrEqualTo(0.0));
        expect(conf, lessThanOrEqualTo(1.0));
      },
    );

    // ── Empty group guard (#5) ──

    test('empty group in textGroups is skipped without crashing', () {
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '正常');

      final result = classifier.classifyGroups(
        textGroups: [
          [],
          [block],
        ],
        input: _TestInput(),
        fixedStickyRects: [],
      );

      // Empty group skipped, normal group classified
      expect(result.classified, hasLength(1));
      expect(result.classified[0].group[0].text, '正常');
    });

    // ── Zero-area group edge case (#11) ──

    test(
      'zero-width group inside fixed rect classified as VR via short-circuit',
      () {
        // Block with zero width: (100,100)-(100,150) → CSS (50,50)-(50,75)
        // center = (50, 62.5)
        final block = _fakeBlock(const Rect.fromLTRB(100, 100, 100, 150), '幻影');
        // Fixed rect covers center
        final fixedRect = const Rect.fromLTRB(0, 0, 200, 200);

        final result = classifier.classifyGroups(
          textGroups: [
            [block],
          ],
          input: _TestInput(),
          fixedStickyRects: [fixedRect],
        );

        expect(result.classified, hasLength(1));
        // groupArea=0 causes short-circuit → insideFixedSticky=true
        expect(result.classified[0].meta.isViewportRelative, isTrue);
      },
    );

    // ── positionLookup exception safety (#4) ──

    test('positionLookup that throws does not abort classification', () {
      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '测试');

      final result = classifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(),
        fixedStickyRects: [],
        positionLookup: (_) => throw StateError('cache corrupted'),
      );

      // Block should still be classified despite callback failure
      expect(result.classified, hasLength(1));
      // Stability defaults to 0.5 (null delta)
      final conf = result.classified[0].meta.positionConfidence;
      expect(conf, greaterThanOrEqualTo(0.0));
      expect(conf, lessThanOrEqualTo(1.0));
    });

    // ── Injected clock (#3) ──

    test('injected clock controls freshness scoring', () {
      final captureTime = DateTime(2025, 1, 1, 12, 0, 0);
      // Clock returns 500ms after capture → mid-range freshness
      final fixedNow = captureTime.add(const Duration(milliseconds: 500));
      final clockClassifier = BlockClassifierService(clock: () => fixedNow);

      final block = _fakeBlock(const Rect.fromLTRB(100, 100, 200, 150), '测试');

      final result = clockClassifier.classifyGroups(
        textGroups: [
          [block],
        ],
        input: _TestInput(captureTime: captureTime),
        fixedStickyRects: [],
      );

      expect(result.classified, hasLength(1));
      // With 500ms age: freshness = 1.0 - (500-200)/(2000-200)*0.7 ≈ 0.883
      // posConf = freshness*0.5 + stability(0.5)*0.5 ≈ 0.69
      final conf = result.classified[0].meta.positionConfidence;
      expect(conf, closeTo(0.69, 0.05));
    });
  });

  // ── Static helpers ──

  group('applyInverseTransform', () {
    test('pure translation shifts rect by -tx, -ty', () {
      final rect = const Rect.fromLTWH(10, 20, 100, 50);
      final result = BlockClassifierService.applyInverseTransform(rect, [
        1.0,
        0.0,
        0.0,
        1.0,
        5.0,
        10.0,
      ]);
      expect(result.left, closeTo(5.0, 0.01));
      expect(result.top, closeTo(10.0, 0.01));
      expect(result.width, closeTo(100.0, 0.01));
      expect(result.height, closeTo(50.0, 0.01));
    });

    test('short matrix returns rect unchanged', () {
      final rect = const Rect.fromLTWH(10, 20, 100, 50);
      final result = BlockClassifierService.applyInverseTransform(rect, [
        1.0,
        0.0,
      ]);
      expect(result, rect);
    });

    test('degenerate matrix returns rect unchanged', () {
      final rect = const Rect.fromLTWH(10, 20, 100, 50);
      final result = BlockClassifierService.applyInverseTransform(rect, [
        0.0,
        0.0,
        0.0,
        0.0,
        5.0,
        10.0,
      ]);
      expect(result, rect);
    });

    test('2x scale transform produces correct inverse', () {
      final rect = const Rect.fromLTWH(20, 40, 100, 60);
      final result = BlockClassifierService.applyInverseTransform(rect, [
        2.0,
        0.0,
        0.0,
        2.0,
        0.0,
        0.0,
      ]);
      expect(result.left, closeTo(10.0, 0.01));
      expect(result.top, closeTo(20.0, 0.01));
      expect(result.width, closeTo(50.0, 0.01));
      expect(result.height, closeTo(30.0, 0.01));
    });
  });

  group('computeGroupSignature', () {
    test('single block returns 0', () {
      final block = _fakeBlock(const Rect.fromLTWH(0, 0, 100, 20), 'hello');
      expect(BlockClassifierService.computeGroupSignature([block]), 0);
    });

    test('multi-block returns non-zero hash', () {
      final blocks = [
        _fakeBlock(const Rect.fromLTWH(0, 0, 100, 20), 'hello'),
        _fakeBlock(const Rect.fromLTWH(0, 20, 100, 20), 'world'),
      ];
      expect(BlockClassifierService.computeGroupSignature(blocks), isNot(0));
    });

    test('signature is order-independent', () {
      final a = _fakeBlock(const Rect.fromLTWH(0, 0, 100, 20), 'alpha');
      final b = _fakeBlock(const Rect.fromLTWH(0, 20, 100, 20), 'beta');
      expect(
        BlockClassifierService.computeGroupSignature([a, b]),
        BlockClassifierService.computeGroupSignature([b, a]),
      );
    });
  });
}
