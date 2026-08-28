import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// NESTED RE-OBSERVATION (#112 / 2.2.0)
// =============================================================================
// An OCR engine's grouping can flip between frames: the same paragraph comes
// back as one paragraph box in one capture and as one of its own lines in
// the next. The line's text is a fragment of the paragraph's, so the
// whole-string primary match fails (17 chars vs 33 scores under 0.70) and
// the line used to be admitted as a NEW block — the same text tracked twice
// at two grouping levels, drawn as a box inside a box until retention
// expired the paragraph (8 of the 23 residual overlap pairs in the 2.1.0
// ML Kit demo frames).
//
// The rule: a fresh block that sits inside an ESTABLISHED block and whose
// text is a fragment of that block's text is a re-observation of it —
// observation count up, geometry and text untouched (a fragment casts no
// text vote and pulls no position) — and is not admitted as a new block.
// One-directional on purpose: a fresh paragraph over an established line
// stays on the whole-string path.
// =============================================================================

StabilizationEngine<DefaultTrackedBlock<void>, void> _engine({
  int retention = 0,
}) {
  return StabilizationEngine<DefaultTrackedBlock<void>, void>(
    merger: (existing, fresh, merge) => existing.applyMerge(merge),
    missedFrameRetention: retention,
  );
}

DefaultTrackedBlock<void> _at(
  Rect r,
  String text, {
  bool viewportRelative = false,
}) =>
    DefaultTrackedBlock<void>(
      absoluteRect: AbsoluteRect(r),
      payload: null,
      originalText: text,
      isViewportRelative: viewportRelative,
    );

// Geometry from the committed ML Kit dwell stream: a two-line paragraph and
// its first line reported alone in a later frame.
const Rect kPara = Rect.fromLTWH(33, 754, 300, 52);
const Rect kLine = Rect.fromLTWH(33, 762, 280, 18);
const String kParaText =
    'The quick brown fox jumps over the lazy dog near the river bank';
const String kLineText = 'The quick brown fox jumps';

void main() {
  group('nested re-observation (#112)', () {
    // Establish the paragraph (observationCount 2) in two frames.
    StabilizationEngine<DefaultTrackedBlock<void>, void> established(
        {int retention = 0}) {
      final engine = _engine(retention: retention);
      engine.stabilize([_at(kPara, kParaText)]);
      final r = engine.stabilize([_at(kPara, kParaText)]);
      expect(r.stableBlocks.single.observationCount, 2,
          reason: 'fixture: the paragraph must be established');
      return engine;
    }

    test('a line inside an established paragraph with fragment text merges '
        'into it — count up, geometry and text unchanged', () {
      final engine = established();
      final r = engine.stabilize([_at(kLine, kLineText)]);
      final b = r.stableBlocks.single;
      expect(b.originalText, kParaText, reason: 'the fragment is absorbed');
      expect(b.absoluteRect.raw, kPara,
          reason: 'a fragment pulls no position');
      expect(b.observationCount, 3, reason: 'it counts as a re-observation');
      expect(engine.spatialIndex.allBlocks, hasLength(1),
          reason: 'no second block for the same text');
    });

    test('retention 0 is on the path: the paragraph survives the flip frame',
        () {
      // Before #112 the flip frame replaced the paragraph with the line at
      // retention 0 (unmatched blocks are dropped); now the paragraph is
      // the matched block and carries on.
      final engine = established(retention: 0);
      engine.stabilize([_at(kLine, kLineText)]);
      final back = engine.stabilize([_at(kPara, kParaText)]);
      expect(back.stableBlocks.single.observationCount, 4,
          reason: 'identity kept across the flip frame');
    });

    test('a nested box with unrelated text is still a new block', () {
      final engine = established();
      final r = engine.stabilize([
        _at(kLine, 'completely different words here'),
      ]);
      expect(r.stableBlocks.single.originalText,
          'completely different words here');
      expect(r.stableBlocks.single.observationCount, 1,
          reason: 'the substring condition is the guard');
    });

    test('a paragraph seen only ONCE already absorbs its line (measured: '
        'flip-every-frame streams never let a host reach two observations)',
        () {
      final engine = _engine();
      engine.stabilize([_at(kPara, kParaText)]);
      final r = engine.stabilize([_at(kLine, kLineText)]);
      expect(r.stableBlocks.single.originalText, kParaText);
      expect(r.stableBlocks.single.observationCount, 2);
    });

    test('a provisional host is frozen and never absorbs a fragment', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
        merger: (existing, fresh, merge) => existing.applyMerge(merge),
      );
      engine.stabilize([
        DefaultTrackedBlock<void>(
          absoluteRect: const AbsoluteRect(kPara),
          payload: null,
          originalText: kParaText,
          isProvisional: true,
          provisionalCapturesRemaining: 3,
        ),
      ]);
      final r = engine.stabilize([_at(kLine, kLineText)]);
      expect(r.stableBlocks.single.originalText, kLineText,
          reason: 'provisional blocks accrue no evidence (#57)');
    });

    test('OCR noise inside the fragment still merges (windowed Levenshtein '
        '>= 0.70, the primary floor)', () {
      final engine = established();
      final r = engine.stabilize([_at(kLine, 'The quick brawn fox jumps')]);
      expect(r.stableBlocks.single.originalText, kParaText);
      expect(r.stableBlocks.single.observationCount, 3);
    });

    test('a fragment shorter than four significant characters never merges',
        () {
      final engine = established();
      final r = engine.stabilize([
        _at(const Rect.fromLTWH(33, 762, 40, 18), 'The'),
      ]);
      expect(r.stableBlocks.single.originalText, 'The',
          reason: 'three characters match inside almost anything');
    });

    test('a fresh box only partly inside the paragraph is a new block', () {
      final engine = established();
      // 40 px tall, straddling the paragraph bottom (806): 16/40 inside.
      final r = engine.stabilize([
        _at(const Rect.fromLTWH(33, 790, 280, 40), kLineText),
      ]);
      expect(r.stableBlocks.single.originalText, kLineText);
      expect(r.stableBlocks.single.observationCount, 1);
    });

    test('a line hanging a few px below the paragraph box still nests '
        '(measured: 14 of 17 px inside on the on-device stream)', () {
      final engine = established();
      // Second line of the paragraph, 17 px tall, bottom 3 px past 806.
      final r = engine.stabilize([
        _at(const Rect.fromLTWH(33, 792, 250, 17),
            'over the lazy dog near the river bank'),
      ]);
      expect(r.stableBlocks.single.originalText, kParaText);
      expect(r.stableBlocks.single.observationCount, 3);
    });

    test('the reverse direction — a fresh paragraph over an established '
        'line — stays on the whole-string path (one-directional rule)', () {
      final engine = _engine();
      engine.stabilize([_at(kLine, kLineText)]);
      engine.stabilize([_at(kLine, kLineText)]);
      final r = engine.stabilize([_at(kPara, kParaText)]);
      expect(r.stableBlocks.single.originalText, kParaText);
      expect(r.stableBlocks.single.observationCount, 1,
          reason: 'documented as a separate case; not merged by this rule');
    });

    test('repeated flips never promote the fragment text and never move '
        'the box', () {
      // Under normal vote accumulation three line observations would
      // outscore the paragraph text; a fragment casts no vote.
      final engine = established();
      for (var i = 0; i < 3; i++) {
        engine.stabilize([_at(kLine, kLineText)]);
      }
      final b = engine.spatialIndex.allBlocks.single;
      expect(b.originalText, kParaText);
      expect(b.absoluteRect.raw, kPara);
      expect(b.observationCount, 5);
    });

    test('under retention the absorbed line leaves no ghost in the index',
        () {
      final engine = established(retention: 2);
      engine.stabilize([_at(kLine, kLineText)]);
      expect(engine.spatialIndex.allBlocks, hasLength(1));
      expect(engine.spatialIndex.allBlocks.single.originalText, kParaText);
    });

    test('viewport-relative and page-absolute blocks never nest', () {
      final engine = _engine();
      engine.stabilize([_at(kPara, kParaText, viewportRelative: true)]);
      engine.stabilize([_at(kPara, kParaText, viewportRelative: true)]);
      final r = engine.stabilize([_at(kLine, kLineText)]);
      expect(r.stableBlocks.single.originalText, kLineText);
      expect(r.stableBlocks.single.observationCount, 1);
    });

    test('paragraph AND its line in the SAME frame: one merged block, never '
        'two copies (measured: three identical tracked boxes before the fix)',
        () {
      for (final lineFirst in [false, true]) {
        final engine = established();
        final batch = lineFirst
            ? [_at(kLine, kLineText), _at(kPara, kParaText)]
            : [_at(kPara, kParaText), _at(kLine, kLineText)];
        final r = engine.stabilize(batch);
        expect(r.stableBlocks, hasLength(1),
            reason: 'order ${lineFirst ? "line,para" : "para,line"}: the '
                'fragment is redundant next to a full observation');
        expect(r.stableBlocks.single.originalText, kParaText);
        expect(r.stableBlocks.single.observationCount, 3,
            reason: 'one confirmation, not two');
        expect(engine.spatialIndex.allBlocks, hasLength(1));
      }
    });

    test('two lines of a missed paragraph in one frame confirm it once', () {
      final engine = established();
      final r = engine.stabilize([
        _at(kLine, kLineText),
        _at(const Rect.fromLTWH(33, 786, 250, 18),
            'over the lazy dog near the river bank'),
      ]);
      expect(r.stableBlocks, hasLength(1));
      expect(r.stableBlocks.single.originalText, kParaText);
      expect(r.stableBlocks.single.observationCount, 3);
    });

    test('the tightest host wins when a fragment sits inside two established '
        'blocks', () {
      // A page-wide block whose text happens to contain the same words,
      // and the paragraph itself: the smaller (paragraph) absorbs the line.
      final engine = _engine();
      const wide = Rect.fromLTWH(0, 700, 400, 200);
      const wideText = 'Header The quick brown fox jumps over the lazy dog '
          'near the river bank and a footer';
      for (var i = 0; i < 2; i++) {
        engine.stabilize([_at(wide, wideText), _at(kPara, kParaText)]);
      }
      final r = engine.stabilize([_at(kLine, kLineText)]);
      final para = r.stableBlocks.singleWhere((b) => b.originalText == kParaText);
      expect(para.observationCount, 3);
    });
  });

  group('TextDedupUtils.bestWindowSimilarity (#112)', () {
    test('exact fragment scores 1.0; equal-length uses whole-string', () {
      expect(TextDedupUtils.bestWindowSimilarity(kLineText, kParaText), 1.0);
      expect(TextDedupUtils.bestWindowSimilarity(kParaText, kParaText), 1.0);
    });

    test('a fragment longer than the whole scores 0.0', () {
      expect(TextDedupUtils.bestWindowSimilarity(kParaText, kLineText), 0.0);
    });

    test('below the minimum significant length scores 0.0', () {
      expect(
          TextDedupUtils.bestWindowSimilarity('The', kParaText,
              minFragmentChars: 4),
          0.0);
      expect(TextDedupUtils.bestWindowSimilarity('', kParaText), 0.0);
    });

    test('punctuation and whitespace do not count (significant chars only)',
        () {
      expect(
          TextDedupUtils.bestWindowSimilarity(
              '  quick, brown — fox!  ', kParaText),
          1.0);
    });

    test('CJK: a line of a paragraph scores 1.0, unrelated text scores low',
        () {
      const para = '他站在窗前看着远处的山峰慢慢被云雾遮住了';
      expect(TextDedupUtils.bestWindowSimilarity('远处的山峰慢慢', para), 1.0);
      expect(TextDedupUtils.bestWindowSimilarity('完全不同的句子', para),
          lessThan(0.5));
    });
  });
}
