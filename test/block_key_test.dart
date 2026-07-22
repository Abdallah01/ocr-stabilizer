// ignore_for_file: unused_element_parameter

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// BLOCK KEY GENERATOR TESTS
// =============================================================================

/// Minimal test block for package-level BlockKeyGenerator tests.
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
  double left = 80,
  double top = 290,
  double width = 200,
  double height = 20,
  String text = 'Hello World',
  bool isViewportRelative = false,
  bool isInnerScrollerChild = false,
  double innerScrollerTop = 0,
  bool isHorizontalScrollChild = false,
  int hzScrollerIndex = -1,
}) {
  return _TestBlock(
    absoluteRect: AbsoluteRect.fromLTWH(left, top, width, height),
    originalText: text,
    isViewportRelative: isViewportRelative,
    isInnerScrollerChild: isInnerScrollerChild,
    innerScrollerTop: innerScrollerTop,
    isHorizontalScrollChild: isHorizontalScrollChild,
    hzScrollerIndex: hzScrollerIndex,
  );
}

/// Text hash exactly as BlockKeyGenerator computes it (String.hashCode is
/// runtime-dependent, so never hard-code it).
String _hash(String normalizedText) =>
    normalizedText.hashCode.toRadixString(36);

void main() {
  group('BlockKeyGenerator.keyFor — normal blocks', () {
    test('key format is kLeft:kTop:sBand:hash:head with empty prefix', () {
      // left 80 / 200 = 0.4 -> 0; top 290 / 200 = 1.45 -> 1; scale 1.0 -> s10.
      final block = _makeBlock(left: 80, top: 290, text: 'Hello World');
      expect(
        BlockKeyGenerator.keyFor(block),
        '0:1:s10:${_hash('Hello World')}:Hello World',
      );
    });

    test('kDefaultBucketSize is 200.0', () {
      expect(BlockKeyGenerator.kDefaultBucketSize, 200.0);
    });

    test('custom bucket sizes change the quantized position', () {
      // left 80 / 100 = 0.8 -> 1; top 290 / 50 = 5.8 -> 6.
      final block = _makeBlock(left: 80, top: 290, text: 'Hello World');
      expect(
        BlockKeyGenerator.keyFor(block, bucketWidth: 100, bucketHeight: 50),
        '1:6:s10:${_hash('Hello World')}:Hello World',
      );
    });

    test('scale is quantized to tenths in the sN band', () {
      final block = _makeBlock(left: 80, top: 290, text: 'Hello World');
      expect(
        BlockKeyGenerator.keyFor(block, scale: 1.5),
        '0:1:s15:${_hash('Hello World')}:Hello World',
      );
    });

    test('whitespace is normalized before hashing and head extraction', () {
      final messy = _makeBlock(text: '  Hello \n  World ');
      final clean = _makeBlock(text: 'Hello World');
      expect(
        BlockKeyGenerator.keyFor(messy),
        BlockKeyGenerator.keyFor(clean),
      );
    });

    test('head is truncated to 30 chars but hash covers full text', () {
      final text = 'abcdefghij' * 4; // 40 chars, no whitespace to normalize
      final block = _makeBlock(text: text);
      expect(
        BlockKeyGenerator.keyFor(block),
        '0:1:s10:${_hash(text)}:${text.substring(0, 30)}',
      );
    });

    test('IC block gets ic: prefix and scroller-relative Y', () {
      // dedupTop = 500 - 150 = 350; 350 / 200 = 1.75 -> 2.
      final block = _makeBlock(
        left: 80,
        top: 500,
        isInnerScrollerChild: true,
        innerScrollerTop: 150,
      );
      expect(
        BlockKeyGenerator.keyFor(block),
        'ic:0:2:s10:${_hash('Hello World')}:Hello World',
      );
    });

    test('carousel block gets hzN: prefix from scroll context index', () {
      final block = _makeBlock(
        isHorizontalScrollChild: true,
        hzScrollerIndex: 2,
      );
      expect(
        BlockKeyGenerator.keyFor(block),
        'hz2:0:1:s10:${_hash('Hello World')}:Hello World',
      );
    });

    test('nested IC + carousel block gets ic:hzN: compound prefix', () {
      final block = _makeBlock(
        left: 80,
        top: 500,
        isInnerScrollerChild: true,
        innerScrollerTop: 150,
        isHorizontalScrollChild: true,
        hzScrollerIndex: 2,
      );
      expect(
        BlockKeyGenerator.keyFor(block),
        'ic:hz2:0:2:s10:${_hash('Hello World')}:Hello World',
      );
    });
  });

  group('BlockKeyGenerator.keyFor — viewport-relative blocks', () {
    test('VR key is text-only with vr: prefix (no position)', () {
      final block = _makeBlock(text: 'Fixed banner', isViewportRelative: true);
      expect(BlockKeyGenerator.keyFor(block), 'vr:Fixed banner');
    });

    test('VR key ignores position, buckets, and scale', () {
      final a = _makeBlock(
        left: 0,
        top: 0,
        text: 'Fixed banner',
        isViewportRelative: true,
      );
      final b = _makeBlock(
        left: 900,
        top: 4200,
        text: 'Fixed banner',
        isViewportRelative: true,
      );
      expect(
        BlockKeyGenerator.keyFor(a),
        BlockKeyGenerator.keyFor(b, bucketWidth: 50, scale: 2.0),
      );
    });

    test('non-CJK VR text is whitespace-normalized and capped at 30', () {
      final block = _makeBlock(
        text: '  This  is a long viewport banner text  ',
        isViewportRelative: true,
      );
      const normalized = 'This is a long viewport banner text';
      expect(
        BlockKeyGenerator.keyFor(block),
        'vr:${normalized.substring(0, 30)}',
      );
    });

    test('VR text with >=3 CJK chars uses CJK-only head', () {
      final block = _makeBlock(
        text: 'Hello 你好世界 123',
        isViewportRelative: true,
      );
      expect(BlockKeyGenerator.keyFor(block), 'vr:你好世界');
    });

    test('CJK-only VR head is capped at 20 chars', () {
      const cjk = '一二三四五六七八九十甲乙丙丁戊己庚辛壬癸天地玄黄宇';
      final block = _makeBlock(text: cjk, isViewportRelative: true);
      expect(BlockKeyGenerator.keyFor(block), 'vr:${cjk.substring(0, 20)}');
    });

    test('fewer than 3 CJK chars falls back to normalized full text', () {
      final block = _makeBlock(text: '你好  shop', isViewportRelative: true);
      expect(BlockKeyGenerator.keyFor(block), 'vr:你好 shop');
    });
  });

  group('BlockKeyGenerator.neighborKeys', () {
    test('normal block yields the 8 surrounding cells, center excluded', () {
      // Center cell is (0, 1) — see keyFor test above.
      final block = _makeBlock(left: 80, top: 290, text: 'Hello World');
      final suffix = 's10:${_hash('Hello World')}:Hello World';

      final keys = BlockKeyGenerator.neighborKeys(block);

      expect(keys, hasLength(8));
      expect(keys, [
        '-1:0:$suffix',
        '-1:1:$suffix',
        '-1:2:$suffix',
        '0:0:$suffix',
        '0:2:$suffix',
        '1:0:$suffix',
        '1:1:$suffix',
        '1:2:$suffix',
      ]);
      expect(keys, isNot(contains(BlockKeyGenerator.keyFor(block))));
    });

    test('IC block neighbors carry ic: prefix and scroller-relative Y', () {
      // Center cell is (0, 2): dedupTop = 500 - 150 = 350 -> 1.75 -> 2.
      final block = _makeBlock(
        left: 80,
        top: 500,
        isInnerScrollerChild: true,
        innerScrollerTop: 150,
      );
      final suffix = 's10:${_hash('Hello World')}:Hello World';

      final keys = BlockKeyGenerator.neighborKeys(block);

      expect(keys, hasLength(8));
      expect(keys, contains('ic:-1:1:$suffix'));
      expect(keys, contains('ic:1:3:$suffix'));
      expect(keys, isNot(contains('ic:0:2:$suffix'))); // center excluded
      expect(keys.every((k) => k.startsWith('ic:')), isTrue);
    });

    test('VR block has no neighbors', () {
      final block = _makeBlock(text: 'Fixed banner', isViewportRelative: true);
      expect(BlockKeyGenerator.neighborKeys(block), isEmpty);
    });
  });

  group('BlockKeyGenerator.keyWithPrefix', () {
    test('overrides the classification prefix on a normal block', () {
      final block = _makeBlock(left: 80, top: 290, text: 'Hello World');
      expect(
        BlockKeyGenerator.keyWithPrefix(block, 'ic:'),
        'ic:0:1:s10:${_hash('Hello World')}:Hello World',
      );
    });

    test('empty prefix strips the prefix from an IC block', () {
      // dedupTop still uses the block's own IC flag: 500 - 150 -> cell 2.
      final block = _makeBlock(
        left: 80,
        top: 500,
        isInnerScrollerChild: true,
        innerScrollerTop: 150,
      );
      expect(
        BlockKeyGenerator.keyWithPrefix(block, ''),
        '0:2:s10:${_hash('Hello World')}:Hello World',
      );
    });

    test('matches keyFor when given the block\'s own prefix', () {
      final block = _makeBlock(
        isHorizontalScrollChild: true,
        hzScrollerIndex: 3,
      );
      expect(
        BlockKeyGenerator.keyWithPrefix(
          block,
          BlockKeyGenerator.prefixFor(block),
        ),
        BlockKeyGenerator.keyFor(block),
      );
    });

    test('documented quirk: prefix is ignored for VR blocks', () {
      final block = _makeBlock(text: 'Fixed banner', isViewportRelative: true);
      final key = BlockKeyGenerator.keyWithPrefix(block, 'ic:');
      expect(key, 'vr:Fixed banner');
      expect(key, BlockKeyGenerator.keyFor(block));
      expect(key, isNot(startsWith('ic:')));
    });
  });

  group('BlockKeyGenerator.prefixFor', () {
    test('normal block has empty prefix', () {
      expect(BlockKeyGenerator.prefixFor(_makeBlock()), '');
    });

    test('IC block -> ic:', () {
      final block = _makeBlock(isInnerScrollerChild: true);
      expect(BlockKeyGenerator.prefixFor(block), 'ic:');
    });

    test('carousel block -> hzN:', () {
      final block = _makeBlock(
        isHorizontalScrollChild: true,
        hzScrollerIndex: 5,
      );
      expect(BlockKeyGenerator.prefixFor(block), 'hz5:');
    });

    test('nested IC + carousel -> ic:hzN:', () {
      final block = _makeBlock(
        isInnerScrollerChild: true,
        isHorizontalScrollChild: true,
        hzScrollerIndex: 0,
      );
      expect(BlockKeyGenerator.prefixFor(block), 'ic:hz0:');
    });
  });
}
