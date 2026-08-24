// =============================================================================
// PARAGRAPH GROUPER MERGE DIAGNOSTICS TESTS (#92)
// =============================================================================
// One test per rejection reason: each fixture is a minimal batch that fails
// on EXACTLY that guard, so the reported reason set is a singleton. This
// pins the diagnostic surface to the decision logic — a guard that stops
// reporting (or misreports) goes red here even while grouping output stays
// correct.
// =============================================================================

import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

OcrBlock _makeBlock(String text, Rect box) {
  return OcrBlock(
    text: text,
    lines: [
      OcrLine(text: text, elements: const [], boundingBox: box),
    ],
    boundingBox: box,
  );
}

OcrBlock _makeBlockWithLines(String text, Rect box, int lineCount) {
  final lineHeight = box.height / lineCount;
  final charsPerLine = (text.length / lineCount).ceil();
  final lines = List.generate(lineCount, (i) {
    final start = (i * charsPerLine).clamp(0, text.length);
    final end = (start + charsPerLine).clamp(start, text.length);
    return OcrLine(
      text: start < end ? text.substring(start, end) : '',
      elements: const [],
      boundingBox: Rect.fromLTWH(
          box.left, box.top + lineHeight * i, box.width, lineHeight),
    );
  });
  return OcrBlock(text: text, lines: lines, boundingBox: box);
}

void main() {
  group('MergeDecisionDiagnostic', () {
    late List<MergeDecisionDiagnostic> events;
    ParagraphGrouper grouper({int? maxBlocks, int? maxRunes}) {
      return ParagraphGrouper(
        maxParagraphBlocks: maxBlocks ?? 3,
        maxParagraphRunes: maxRunes ?? 200,
        onMergeDecision: events.add,
      );
    }

    setUp(() => events = []);

    test('accepted merge reports accepted with empty reasons and numbers',
        () {
      final result = grouper().groupIntoParagraphs([
        _makeBlock('第一行内容文字', Rect.fromLTWH(0, 0, 300, 20)),
        _makeBlock('第二行内容文字', Rect.fromLTWH(0, 25, 300, 20)),
      ]);
      expect(result, hasLength(1));
      expect(result.single, hasLength(2));
      // Exactly ONE decision: the second block vs the open paragraph. A
      // block that STARTS a paragraph is not a merge decision.
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.accepted, isTrue);
      expect(e.reasons, isEmpty);
      expect(e.gap, 5.0);
      expect(e.threshold, isNotNull);
      expect(e.xTolerance, isNotNull);
      expect(e.paragraphLength, 1);
    });

    test('gapExceedsThreshold', () {
      grouper().groupIntoParagraphs([
        _makeBlock('第一行文字内容', Rect.fromLTWH(0, 0, 300, 20)),
        _makeBlock('第二行文字内容', Rect.fromLTWH(0, 100, 300, 20)),
      ]);
      expect(events, hasLength(1));
      expect(events.single.accepted, isFalse);
      expect(events.single.reasons, {MergeRejectReason.gapExceedsThreshold});
      expect(events.single.gap, 80.0);
    });

    test('noXOverlap (vertically stacked, horizontally disjoint)', () {
      grouper().groupIntoParagraphs([
        _makeBlock('第一行文字内容', Rect.fromLTWH(0, 0, 200, 20)),
        _makeBlock('第二行文字内容', Rect.fromLTWH(500, 30, 200, 20)),
      ]);
      expect(events, hasLength(1));
      expect(events.single.reasons, {MergeRejectReason.noXOverlap});
    });

    test('heightRatio (candidate 3x taller with more lines)', () {
      grouper().groupIntoParagraphs([
        _makeBlock('短行文字', Rect.fromLTWH(0, 0, 300, 20)),
        _makeBlockWithLines(
            '这是一个很长的段落文字内容延续三行', Rect.fromLTWH(0, 30, 300, 70), 3),
      ]);
      expect(events, hasLength(1));
      expect(events.single.reasons, {MergeRejectReason.heightRatio});
    });

    test('reverseHeightRatio (current block 3x taller than candidate)', () {
      grouper().groupIntoParagraphs([
        _makeBlock('章节标题文字内容', Rect.fromLTWH(0, 0, 300, 90)),
        _makeBlock('正文短行文字', Rect.fromLTWH(0, 100, 300, 20)),
      ]);
      expect(events, hasLength(1));
      expect(events.single.reasons, {MergeRejectReason.reverseHeightRatio});
    });

    test('inlinePeer (same row, close enough to X-overlap)', () {
      grouper().groupIntoParagraphs([
        _makeBlock('左侧标签', Rect.fromLTWH(0, 0, 100, 20)),
        _makeBlock('右侧标签', Rect.fromLTWH(130, 0, 100, 20)),
      ]);
      expect(events, hasLength(1));
      expect(events.single.reasons, {MergeRejectReason.inlinePeer});
    });

    test('blockCountCap', () {
      grouper(maxBlocks: 1).groupIntoParagraphs([
        _makeBlock('第一行文字内容', Rect.fromLTWH(0, 0, 300, 20)),
        _makeBlock('第二行文字内容', Rect.fromLTWH(0, 30, 300, 20)),
      ]);
      expect(events, hasLength(1));
      expect(events.single.reasons, {MergeRejectReason.blockCountCap});
    });

    test('runeCap', () {
      grouper(maxRunes: 5).groupIntoParagraphs([
        _makeBlock('四个字啊', Rect.fromLTWH(0, 0, 300, 20)),
        _makeBlock('两字', Rect.fromLTWH(0, 30, 300, 20)),
      ]);
      expect(events, hasLength(1));
      expect(events.single.reasons, {MergeRejectReason.runeCap});
    });

    test('degenerateBox drop is reported', () {
      final result = grouper().groupIntoParagraphs([
        _makeBlock('文字', Rect.fromLTWH(0, 0, 100, 0)),
      ]);
      expect(result, isEmpty);
      expect(events, hasLength(1));
      final e = events.single;
      expect(e.accepted, isFalse);
      expect(e.reasons, {MergeRejectReason.degenerateBox});
      expect(e.gap, isNull);
      expect(e.threshold, isNull);
      expect(e.xTolerance, isNull);
    });

    test('noiseGuard drop is reported', () {
      final result = grouper().groupIntoParagraphs([
        _makeBlock('一', Rect.fromLTWH(0, 0, 3000, 10)),
      ]);
      expect(result, isEmpty);
      expect(events, hasLength(1));
      expect(events.single.reasons, {MergeRejectReason.noiseGuard});
    });

    test('null callback: grouping output is identical (zero-cost path)', () {
      final batch = [
        _makeBlock('第一行文字内容', Rect.fromLTWH(0, 0, 300, 20)),
        _makeBlock('第二行文字内容', Rect.fromLTWH(0, 25, 300, 20)),
        _makeBlock('新的段落开头', Rect.fromLTWH(0, 120, 300, 20)),
      ];
      final withCb = grouper().groupIntoParagraphs(batch);
      final without = ParagraphGrouper().groupIntoParagraphs(batch);
      expect(withCb.length, without.length);
      for (var i = 0; i < withCb.length; i++) {
        expect(withCb[i].map((b) => b.text), without[i].map((b) => b.text));
      }
    });
  });
}
