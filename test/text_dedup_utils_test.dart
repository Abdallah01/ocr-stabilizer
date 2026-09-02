// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// TEXT DEDUP UTILS TESTS
// =============================================================================
// First dedicated coverage for the dedup math (v0.5.1), plus regression
// tests for the CJK Extension B unification: before 0.5.1 the dedup
// utilities omitted Ext B (U+20000–U+2A6DF) while the confidence heuristic
// included it, so Ext-B-only text could never text-dedup.
// =============================================================================

void main() {
  group('TextDedupUtils core metrics', () {
    test('normalizedLevenshtein: identical texts score 1.0', () {
      expect(TextDedupUtils.normalizedLevenshtein('hello', 'hello'), 1.0);
      expect(TextDedupUtils.normalizedLevenshtein('第10段', '第10段'), 1.0);
    });

    test('normalizedLevenshtein: disjoint texts score 0.0', () {
      expect(TextDedupUtils.normalizedLevenshtein('abc', 'xyz'), 0.0);
    });

    test('normalizedLevenshtein ignores punctuation and whitespace', () {
      expect(
        TextDedupUtils.normalizedLevenshtein('a, b, c!', 'a b c'),
        1.0,
      );
    });

    test('jaccardSimilarity: reordered characters score 1.0', () {
      expect(TextDedupUtils.jaccardSimilarity('ab', 'ba'), 1.0);
      expect(TextDedupUtils.jaccardSimilarity('北京', '京北'), 1.0);
    });

    test('isTextSimilar rejects punctuation-only strings', () {
      expect(TextDedupUtils.isTextSimilar('...', '!!!'), isFalse);
      expect(TextDedupUtils.isTextSimilar('...', '...'), isFalse);
    });

    test('isTextSimilarWithScores agrees with isTextSimilar', () {
      final scores = TextDedupUtils.isTextSimilarWithScores('abcd', 'abcx');
      expect(scores.match, TextDedupUtils.isTextSimilar('abcd', 'abcx'));
      expect(scores.levenshtein, closeTo(0.75, 1e-9));
    });

    test('containmentRatio: full containment scores 1.0', () {
      expect(TextDedupUtils.containmentRatio('bcd', 'abcde'), 1.0);
    });

    test('containmentRatio: partial containment uses true LCS length', () {
      // LCS('abcd', 'abxy') = 'ab' (2) → 2/4 = 0.5. Exercises the DP
      // recurrence (match and mismatch arms) across multiple rows —
      // the trivial full-containment case cannot distinguish max from
      // min in the mismatch arm (mutation survivor, post-0.6.0 sweep).
      expect(TextDedupUtils.containmentRatio('abcd', 'abxy'), 0.5);
      // LCS('axbyc', 'abc') = 3, inner has 5 runes → 0.6.
      expect(
        TextDedupUtils.containmentRatio('axbyc', 'abc'),
        closeTo(0.6, 1e-9),
      );
    });

    test('containmentRatio: inputs beyond 5000 runes are truncated', () {
      // 5001 identical runes: the LCS core truncates both sides to
      // 5000, but the ratio divides by the UNtruncated inner length —
      // 5000/5001, not 1.0. Pins the documented OOM guard.
      final long = 'a' * 5001;
      expect(
        TextDedupUtils.containmentRatio(long, long),
        closeTo(5000 / 5001, 1e-12),
      );
    });

    test('containmentRatio: empty inputs score 0.0', () {
      expect(TextDedupUtils.containmentRatio('', 'abc'), 0.0);
      expect(TextDedupUtils.containmentRatio('abc', ''), 0.0);
    });

    test('normalizedLevenshtein normalizes by the LONGER length', () {
      // 'abcd' vs 'ab': distance 2, max length 4 → 1 - 2/4 = 0.5.
      // Normalizing by the shorter length would give 0.0 (mutation
      // survivor: max → min in the maxLen computation).
      expect(TextDedupUtils.normalizedLevenshtein('abcd', 'ab'), 0.5);
    });

    test('shortHead truncates and passes short strings through', () {
      expect(TextDedupUtils.shortHead('abcdef', 3), 'abc');
      expect(TextDedupUtils.shortHead('ab', 3), 'ab');
      expect(TextDedupUtils.shortHead('abc', 3), 'abc');
    });
  });

  group('CJK Extension B unification (v0.5.1)', () {
    // U+20000 and U+20001 — CJK Extension B ideographs (outside the BMP).
    const extB1 = '\u{20000}';
    const extB2 = '\u{20001}';

    test('cjkOnly keeps Extension B ideographs', () {
      expect(TextDedupUtils.cjkOnly('a$extB1 b$extB2!'), '$extB1$extB2');
    });

    test('cjkOnly still keeps BMP ideographs and strips the rest', () {
      expect(TextDedupUtils.cjkOnly('北x京 123'), '北京');
    });

    test('cjkFraction counts Extension B ideographs', () {
      // Two runes, both Ext B.
      expect(TextDedupUtils.cjkFraction('$extB1$extB2'), 1.0);
    });

    test('significantCharList includes Extension B runes', () {
      expect(
        TextDedupUtils.significantCharList(extB1),
        [0x20000],
      );
    });

    test('identical Extension-B-only texts are similar', () {
      // Pre-0.5.1: both sides produced empty significant-char lists, so
      // the punctuation-only guard rejected the pair unconditionally.
      expect(
        TextDedupUtils.isTextSimilar('$extB1$extB2', '$extB1$extB2'),
        isTrue,
      );
    });

    test('dedup and confidence agree on what counts as CJK', () {
      for (final rune in [0x4e00, 0x3400, 0xf900, 0x20000, 0x2a6df]) {
        expect(isCjkIdeograph(rune), isTrue,
            reason: '0x${rune.toRadixString(16)}');
        expect(
          TextDedupUtils.cjkFraction(String.fromCharCode(rune)),
          1.0,
          reason: '0x${rune.toRadixString(16)}',
        );
      }
      expect(isCjkIdeograph(0x61), isFalse); // 'a'
      expect(TextDedupUtils.cjkFraction('a'), 0.0);
    });
  });
}
