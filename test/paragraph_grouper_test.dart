// =============================================================================
// PARAGRAPH GROUPER UNIT TESTS
// =============================================================================
// Oracle tests for [ParagraphGrouper] — CJK-aware grouping of OCR text blocks
// into paragraph-level translation units. Ported from the originating app's
// production suite, where they pinned the same algorithm against real-device
// regressions (qidian-class CJK novel pages on a high-DPR phone).
// =============================================================================

import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

/// Helper to create an [OcrBlock] with minimal required fields.
OcrBlock _makeBlock(String text, Rect box) {
  return OcrBlock(
    text: text,
    lines: [
      OcrLine(
        text: text,
        elements: const [],
        boundingBox: box,
      ),
    ],
    boundingBox: box,
  );
}

/// Helper to create an [OcrBlock] with a configurable number of [OcrLine]s.
/// Each line gets an equal slice of the bounding box height and text.
OcrBlock _makeBlockWithLines(String text, Rect box, int lineCount) {
  assert(lineCount >= 1, 'lineCount must be >= 1');
  final lineHeight = box.height / lineCount;
  final charsPerLine = (text.length / lineCount).ceil();
  final lines = List.generate(lineCount, (i) {
    final start = (i * charsPerLine).clamp(0, text.length);
    final end = (start + charsPerLine).clamp(start, text.length);
    return OcrLine(
      text: start < end ? text.substring(start, end) : '',
      elements: const [],
      boundingBox: Rect.fromLTWH(
        box.left,
        box.top + lineHeight * i,
        box.width,
        lineHeight,
      ),
    );
  });
  return OcrBlock(
    text: text,
    lines: lines,
    boundingBox: box,
  );
}

void main() {
  late ParagraphGrouper grouper;

  setUp(() {
    grouper = ParagraphGrouper();
  });

  group('groupIntoParagraphs', () {
    test('groups vertically close blocks into one paragraph', () {
      final blocks = [
        _makeBlock('第一行', const Rect.fromLTWH(100, 100, 200, 20)),
        _makeBlock('第二行', const Rect.fromLTWH(100, 125, 200, 20)), // 5px gap
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(1));
      expect(paragraphs[0], hasLength(2));
    });

    test('separates blocks with large vertical gap', () {
      final blocks = [
        _makeBlock('段落一', const Rect.fromLTWH(100, 100, 200, 20)),
        _makeBlock('段落二', const Rect.fromLTWH(100, 200, 200, 20)), // 80px gap
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(2));
    });

    test('separates side-by-side blocks (no X overlap)', () {
      final blocks = [
        _makeBlock('左边', const Rect.fromLTWH(0, 100, 100, 20)),
        _makeBlock('右边', const Rect.fromLTWH(200, 100, 100, 20)),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(2),
          reason: 'side-by-side blocks should not merge');
    });

    test('sorts blocks by Y position', () {
      // Blocks given in reverse order but within lineGapThreshold
      final blocks = [
        _makeBlock('下面', const Rect.fromLTWH(100, 125, 200, 20)),
        _makeBlock('上面', const Rect.fromLTWH(100, 100, 200, 20)),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(1));
      expect(paragraphs[0][0].text, '上面');
      expect(paragraphs[0][1].text, '下面');
    });

    test('empty list returns empty', () {
      expect(grouper.groupIntoParagraphs([]), isEmpty);
    });

    // ── Adaptive threshold tests ──

    test('merges wrapped lines with height-proportional gap', () {
      // Simulates 3x DPR: 60px-tall blocks with 30px gap between lines.
      // Fixed 10px threshold would split these; adaptive threshold =
      // max(10, 60 * 0.75) = 45, so 30 < 45 → merges.
      final blocks = [
        _makeBlock('第一行', const Rect.fromLTWH(50, 100, 400, 60)),
        _makeBlock('第二行', const Rect.fromLTWH(50, 190, 400, 60)), // 30px gap
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(1),
          reason: 'wrapped lines should merge via adaptive threshold');
      expect(paragraphs[0], hasLength(2));
    });

    test('respects max gap ceiling (2x block height)', () {
      // 60px-tall blocks with 130px gap.
      // Adaptive = 60 * 0.75 = 45, ceiling = 60 * 2.0 = 120.
      // Effective = min(max(10, 45), 120) = 45.  130 > 45 → should NOT merge.
      final blocks = [
        _makeBlock('段落一', const Rect.fromLTWH(50, 100, 400, 60)),
        _makeBlock('段落二', const Rect.fromLTWH(50, 290, 400, 60)), // 130px gap
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(2),
          reason: 'large gap exceeds ceiling, should split');
    });

    test('lineGapThreshold acts as floor for small text', () {
      // 5px-tall blocks with 8px gap.
      // Adaptive = max(10, 5*0.75) = max(10, 3.75) = 10.
      // 8 < 10 → merges (floor kicks in).
      final blocks = [
        _makeBlock('小', const Rect.fromLTWH(100, 100, 50, 5)),
        _makeBlock('字', const Rect.fromLTWH(100, 113, 50, 5)), // 8px gap
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(1),
          reason: 'floor threshold should merge small text with small gap');
    });

    test('custom lineGapMultiplier is respected', () {
      // With multiplier=1.5: adaptive = max(10, 40*1.5) = 60.
      // 50px gap < 60 → merges.
      // With default 0.75: adaptive = max(10, 40*0.75) = 30. 50 > 30 → split.
      final custom = ParagraphGrouper(lineGapMultiplier: 1.5);
      final blocks = [
        _makeBlock('第一行', const Rect.fromLTWH(50, 100, 300, 40)),
        _makeBlock('第二行', const Rect.fromLTWH(50, 190, 300, 40)), // 50px gap
      ];

      final paragraphs = custom.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(1),
          reason: 'higher multiplier should merge larger gaps');
    });

    test(
        'height-ratio guard: single-line tag row not merged with multi-line '
        'paragraph', () {
      final blocks = [
        // Genre tag row: 1 line, 20px tall
        _makeBlockWithLines(
          '玄幻 修仙 历史 都市',
          const Rect.fromLTWH(30, 100, 300, 20),
          1,
        ),
        // Paragraph: 5 lines, 100px tall, 10px gap below tags
        _makeBlockWithLines(
          '此页面故意包含多种常见移动端坑位粘性标题与底栏内部滚动容器水平卡片滚动延迟加载内容可折叠段落等以便验证覆盖层在滚动',
          const Rect.fromLTWH(30, 130, 300, 100),
          5,
        ),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(2),
          reason: 'Tag row (1 line, 20px) should not merge with paragraph '
              '(5 lines, 100px) despite small gap');
    });

    test('height-ratio guard: wrapped lines with similar height still merge',
        () {
      final blocks = [
        _makeBlock('第一行文字', const Rect.fromLTWH(50, 100, 300, 20)),
        _makeBlock('第二行文字', const Rect.fromLTWH(50, 125, 300, 22)),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(1),
          reason: 'Similar-height single-line blocks should merge normally');
    });

    test(
        'height-ratio guard: does not apply when current paragraph has '
        'multiple blocks', () {
      final blocks = [
        // Two blocks that merge into current paragraph
        _makeBlock('行一', const Rect.fromLTWH(50, 100, 300, 20)),
        _makeBlock('行二', const Rect.fromLTWH(50, 125, 300, 20)),
        // Tall candidate — guard should NOT trigger (current has 2 blocks)
        _makeBlockWithLines(
          '这是一段很长的文字需要多行才能显示完整的内容',
          const Rect.fromLTWH(50, 150, 300, 80),
          4,
        ),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(1),
          reason: 'Guard only triggers for single-block paragraphs');
    });

    test('paragraph cap: 4+ consecutive blocks split into multiple groups',
        () {
      // 5 blocks with small gaps — all would merge without the cap
      final blocks = [
        _makeBlock('第一段', const Rect.fromLTWH(50, 100, 300, 20)),
        _makeBlock('第二段', const Rect.fromLTWH(50, 125, 300, 20)),
        _makeBlock('第三段', const Rect.fromLTWH(50, 150, 300, 20)),
        _makeBlock('第四段', const Rect.fromLTWH(50, 175, 300, 20)),
        _makeBlock('第五段', const Rect.fromLTWH(50, 200, 300, 20)),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs.length, greaterThan(1),
          reason: 'Max 3 blocks per paragraph — 5 blocks should split');
      expect(paragraphs.first.length, 3,
          reason: 'First group capped at 3 blocks');
    });

    test('paragraph cap: 2-3 block wraps still merge normally', () {
      final blocks = [
        _makeBlock('第一行', const Rect.fromLTWH(50, 100, 300, 20)),
        _makeBlock('第二行', const Rect.fromLTWH(50, 125, 300, 20)),
        _makeBlock('第三行', const Rect.fromLTWH(50, 150, 300, 20)),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(1),
          reason: '3 blocks within cap should merge into one paragraph');
    });

    test('paragraph cap: custom maxParagraphBlocks changes the split point',
        () {
      // Same 5-block layout as above, but cap lowered to 2.
      final custom = ParagraphGrouper(maxParagraphBlocks: 2);
      final blocks = [
        _makeBlock('第一段', const Rect.fromLTWH(50, 100, 300, 20)),
        _makeBlock('第二段', const Rect.fromLTWH(50, 125, 300, 20)),
        _makeBlock('第三段', const Rect.fromLTWH(50, 150, 300, 20)),
        _makeBlock('第四段', const Rect.fromLTWH(50, 175, 300, 20)),
        _makeBlock('第五段', const Rect.fromLTWH(50, 200, 300, 20)),
      ];

      final paragraphs = custom.groupIntoParagraphs(blocks);

      expect(paragraphs.first.length, 2,
          reason: 'First group capped at the custom maxParagraphBlocks');
    });

    test('punctuation-aware: sentence-ending 。 applies stricter threshold',
        () {
      // Block 1 ends with 。(sentence end) — strict threshold (0.6×)
      // Normal adaptive threshold for 20px blocks: max(10, 20*0.75) = 15px
      // Strict: 15 * 0.6 = 9px. Gap of 12px > 9px → should NOT merge.
      final blocks = [
        _makeBlock('第一句话。', const Rect.fromLTWH(50, 100, 300, 20)),
        _makeBlock('第二句话', const Rect.fromLTWH(50, 132, 300, 20)), // 12px
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(2),
          reason: 'Sentence-ending 。 should apply strict gap threshold');
    });

    test('punctuation-aware: mid-sentence ， uses neutral threshold', () {
      // Block 1 ends with ，(comma) — neutral threshold (1.0×, no boost).
      // Normal: max(10, 20*0.75) = 15px. Gap of 12px < 15px → merges.
      // The mid-sentence multiplier is 1.0 (identity) to prevent over-merging
      // CJK paragraphs where nearly every line ends with an ideograph.
      final blocks = [
        _makeBlock('第一行文字，', const Rect.fromLTWH(50, 100, 300, 20)),
        _makeBlock('第二行继续', const Rect.fromLTWH(50, 132, 300, 20)), // 12px
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(1),
          reason: 'Gap (12px) below adaptive threshold (15px) should merge');
    });

    test('density guard: OCR noise block (few runes, huge box) discarded', () {
      // Normal block followed by a huge box with 1 rune (OCR artifact)
      // Density = 1 / (500*500) = 0.000004 < 0.00005 threshold
      final blocks = [
        _makeBlock('正常段落文字', const Rect.fromLTWH(50, 100, 300, 20)),
        _makeBlock('I', const Rect.fromLTWH(50, 125, 500, 500)), // noise
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(1),
          reason: 'OCR noise block should be discarded, not included');
      expect(paragraphs[0].first.text, '正常段落文字');
    });

    test('density guard: h1 heading with body text is NOT filtered', () {
      // Heading "好" (1 rune) in a 340×60 box with body text at 30px.
      // - density = 1 / (340*60) = 0.0000490 < 0.00005 → lowDensity=true
      // - aspect = 340/60 = 5.67 → within [0.125, 8.0] → badAspect=false
      // - charH = 60, median = 30, ratio = 60/30 = 2.0×
      //   A 1.5× factor would filter it (60 > 45); the 2.5× factor keeps it
      //   (60 < 75), so real headings survive while 4-10× phantoms drop.
      final blocks = [
        _makeBlock('正常段落的文字内容', const Rect.fromLTWH(50, 100, 300, 30)),
        _makeBlock('第二行正常文字内容', const Rect.fromLTWH(50, 134, 300, 30)),
        _makeBlock('第三行正常文字内容', const Rect.fromLTWH(50, 168, 300, 30)),
        _makeBlock('好', const Rect.fromLTWH(50, 30, 340, 60)),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      final allTexts =
          paragraphs.expand((p) => p.map((b) => b.text)).toList();
      expect(allTexts, contains('好'),
          reason: 'Heading should not be filtered by density guard');
    });

    test('reverse height-ratio: tall title does not absorb short tags', () {
      // Title (60px tall) followed by genre tags (15px tall).
      // Ratio: 60/15 = 4.0 > 3.0 threshold → should NOT merge.
      final blocks = [
        _makeBlock('欢迎来到测试页', const Rect.fromLTWH(50, 100, 300, 60)),
        _makeBlock('玄幻', const Rect.fromLTWH(50, 170, 80, 15)),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(2),
          reason: 'Tall title should not absorb short genre tags');
    });

    test('paragraph rune cap: two long paragraphs stay separate', () {
      // Two blocks each with >100 runes. Sum > 200 → cap prevents merge.
      final longText = '这是一段很长的中文文本用于测试段落合并上限。' * 6; // ~120 runes each
      final blocks = [
        _makeBlock(longText, const Rect.fromLTWH(50, 100, 300, 40)),
        _makeBlock(longText, const Rect.fromLTWH(50, 142, 300, 40)), // 2px gap
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(2),
          reason: 'Two blocks exceeding 200 runes total should stay separate');
    });

    test('paragraph rune cap: custom maxParagraphRunes lifts the ceiling', () {
      // Same layout as above, but the cap raised to 500 → the two ~132-rune
      // blocks (sum ~264) now fit and merge into one paragraph.
      final custom = ParagraphGrouper(maxParagraphRunes: 500);
      final longText = '这是一段很长的中文文本用于测试段落合并上限。' * 6;
      final blocks = [
        _makeBlock(longText, const Rect.fromLTWH(50, 100, 300, 40)),
        _makeBlock(longText, const Rect.fromLTWH(50, 142, 300, 40)), // 2px gap
      ];

      final paragraphs = custom.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(1),
          reason: 'Raised rune cap should allow the merge');
    });

    test('explodes multi-line OcrBlock at sentence-ending punctuation', () {
      // OCR returns a single OcrBlock with 3 lines where line 1 and 2
      // end with 。 — should be split into 3 separate blocks.
      final lines = [
        const OcrLine(
          text: '第一段内容。',
          elements: [],
          boundingBox: Rect.fromLTWH(50, 100, 300, 20),
        ),
        const OcrLine(
          text: '第二段内容。',
          elements: [],
          boundingBox: Rect.fromLTWH(50, 120, 300, 20),
        ),
        const OcrLine(
          text: '第三段继续',
          elements: [],
          boundingBox: Rect.fromLTWH(50, 140, 300, 20),
        ),
      ];
      final multiLineBlock = OcrBlock(
        text: '第一段内容。第二段内容。第三段继续',
        lines: lines,
        boundingBox: const Rect.fromLTWH(50, 100, 300, 60),
      );

      final paragraphs = grouper.groupIntoParagraphs([multiLineBlock]);

      expect(paragraphs, hasLength(3),
          reason:
              'Lines ending with 。 in a 3-line block should produce 3 groups');
    });

    test('does not explode single-line or no-sentence-end blocks', () {
      final block =
          _makeBlock('没有句号的内容', const Rect.fromLTWH(50, 100, 300, 20));

      final paragraphs = grouper.groupIntoParagraphs([block]);

      expect(paragraphs, hasLength(1),
          reason: 'Single-line block without sentence end stays intact');
    });

    // ── Inline peer detection tests ──

    test('inline peer: genre tag pills on same row stay separate', () {
      // 4 genre tags on the same horizontal row, each ~60px wide with
      // ~20px horizontal gaps between them. Same height, same Y.
      final blocks = [
        _makeBlock('玄幻', const Rect.fromLTWH(30, 200, 60, 24)),
        _makeBlock('修仙', const Rect.fromLTWH(110, 200, 60, 24)),
        _makeBlock('历史', const Rect.fromLTWH(190, 200, 60, 24)),
        _makeBlock('都市', const Rect.fromLTWH(270, 200, 60, 24)),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(4),
          reason:
              'Genre tag pills side-by-side should each be a separate group');
    });

    test('inline peer: tags on two rows stay separate', () {
      // Row 1: 4 tags; Row 2: 2 tags. Small vertical gap between rows.
      final blocks = [
        _makeBlock('玄幻', const Rect.fromLTWH(30, 200, 60, 24)),
        _makeBlock('修仙', const Rect.fromLTWH(110, 200, 60, 24)),
        _makeBlock('历史', const Rect.fromLTWH(190, 200, 60, 24)),
        _makeBlock('都市', const Rect.fromLTWH(270, 200, 60, 24)),
        _makeBlock('科幻', const Rect.fromLTWH(30, 230, 60, 24)), // row 2
        _makeBlock('悬疑', const Rect.fromLTWH(110, 230, 60, 24)),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(6),
          reason: 'Each genre tag on both rows should be separate');
    });

    test('inline peer: vertically stacked lines still merge', () {
      // Normal paragraph: line 1 at y=100, line 2 at y=125 (below, not
      // beside). Both span the same horizontal range — NOT inline peers.
      final blocks = [
        _makeBlock('这是第一行的内容', const Rect.fromLTWH(50, 100, 300, 20)),
        _makeBlock('这是第二行的内容', const Rect.fromLTWH(50, 125, 300, 20)),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(1),
          reason: 'Vertically stacked lines should merge normally');
    });

    test('inline peer: toolbar items with tight spacing stay separate', () {
      // Bottom toolbar: "喜欢" [gap] "收藏" [gap] "下载"
      // Tight horizontal spacing (only 1em gap) at the same Y.
      final blocks = [
        _makeBlock('喜欢', const Rect.fromLTWH(30, 500, 50, 20)),
        _makeBlock('收藏', const Rect.fromLTWH(100, 500, 50, 20)),
        _makeBlock('下载', const Rect.fromLTWH(170, 500, 50, 20)),
      ];

      final paragraphs = grouper.groupIntoParagraphs(blocks);

      expect(paragraphs, hasLength(3),
          reason: 'Toolbar items on same row should stay separate');
    });
  });

  group('groupByLines', () {
    test('each block becomes its own group', () {
      final blocks = [
        _makeBlock('行一', const Rect.fromLTWH(0, 0, 100, 20)),
        _makeBlock('行二', const Rect.fromLTWH(0, 30, 100, 20)),
      ];

      final groups = grouper.groupByLines(blocks);

      expect(groups, hasLength(2));
      expect(groups[0], hasLength(1));
      expect(groups[1], hasLength(1));
    });
  });

  group('constructor validation', () {
    test('rejects maxParagraphBlocks < 1', () {
      expect(() => ParagraphGrouper(maxParagraphBlocks: 0),
          throwsA(isA<ArgumentError>()));
    });

    test('rejects maxParagraphRunes < 1', () {
      expect(() => ParagraphGrouper(maxParagraphRunes: 0),
          throwsA(isA<ArgumentError>()));
    });

    test('rejects negative lineGapThreshold', () {
      expect(() => ParagraphGrouper(lineGapThreshold: -1.0),
          throwsA(isA<ArgumentError>()));
    });

    test('rejects non-positive lineGapMultiplier', () {
      expect(() => ParagraphGrouper(lineGapMultiplier: 0.0),
          throwsA(isA<ArgumentError>()));
    });

    test('rejects non-finite lineGapThreshold', () {
      expect(() => ParagraphGrouper(lineGapThreshold: double.nan),
          throwsA(isA<ArgumentError>()));
    });
  });
}
