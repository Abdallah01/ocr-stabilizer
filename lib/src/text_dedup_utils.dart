// ============================================================================
// TEXT DEDUPLICATION UTILITIES
// ============================================================================
// Pure static text-processing functions used by the overlay dedup pipeline.
// Extracted from OverlayCacheService for independent testability.
// ============================================================================

import 'dart:math' show min, max;

/// Pure text utilities for the block deduplication pipeline.
///
/// All methods are static and side-effect-free.
class TextDedupUtils {
  TextDedupUtils._();

  /// Collapse runs of whitespace to single space, trim ends.
  static String normalizeWhitespace(String s) {
    return s.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  /// Return at most [max] leading characters of [s].
  static String shortHead(String s, int max) {
    if (s.length <= max) return s;
    return s.substring(0, max);
  }

  /// Extract only CJK Unified Ideograph characters, stripping punctuation,
  /// Latin letters, digits, and whitespace.
  static String cjkOnly(String s) {
    return s.replaceAll(
      RegExp(r'[^\u4e00-\u9fff\u3400-\u4dbf\uf900-\ufaff]'),
      '',
    );
  }

  /// Fraction of [s]'s runes that are CJK Unified Ideographs (0.0–1.0).
  static double cjkFraction(String s) {
    if (s.isEmpty) return 0.0;
    final runes = s.runes;
    final cjkCount = runes.where(_isCjk).length;
    return cjkCount / runes.length;
  }

  /// Check if a rune is a CJK Unified Ideograph.
  static bool _isCjk(int c) {
    return (c >= 0x4e00 && c <= 0x9fff) || // CJK Unified Ideographs
        (c >= 0x3400 && c <= 0x4dbf) || // CJK Unified Ideographs Extension A
        (c >= 0xf900 && c <= 0xfaff); // CJK Compatibility Ideographs
  }

  /// Significant characters as an ordered list (preserves sequence and
  /// duplicates). Same filter as [significantChars] but order-sensitive
  /// for Levenshtein computation.
  ///
  /// Includes CJK ideographs, ASCII digits, and ASCII letters so template
  /// paragraphs differing only by number ("第10段" vs "第11段") produce
  /// distinct sequences.
  static List<int> significantCharList(String s) {
    final result = <int>[];
    for (final c in s.runes) {
      if (_isSignificantChar(c)) {
        result.add(c);
      }
    }
    return result;
  }

  /// Extract unique CJK + alphanumeric code points from [s].
  ///
  /// Strips whitespace and punctuation. Uses [significantCharList] internally
  /// and converts to a set for O(1) membership tests.
  static Set<int> significantChars(String s) => significantCharList(s).toSet();

  /// Check if a rune is CJK, digit, or ASCII letter.
  static bool _isSignificantChar(int c) {
    return (c >= 0x4e00 && c <= 0x9fff) || // CJK Unified Ideographs
        (c >= 0x3400 && c <= 0x4dbf) || // CJK Unified Ideographs Extension A
        (c >= 0xf900 && c <= 0xfaff) || // CJK Compatibility Ideographs
        (c >= 0x30 && c <= 0x39) || // 0-9
        (c >= 0x41 && c <= 0x5a) || // A-Z
        (c >= 0x61 && c <= 0x7a); // a-z
  }

  /// Normalized Levenshtein similarity on significant characters.
  ///
  /// Returns 1.0 for identical texts, 0.0 for completely different.
  /// Strips punctuation/whitespace before comparison via [significantCharList].
  /// Uses O(min(m,n)) space with single-row DP optimization.
  static double normalizedLevenshtein(String a, String b) {
    final seqA = significantCharList(a);
    final seqB = significantCharList(b);

    if (seqA.isEmpty && seqB.isEmpty) return 1.0;
    if (seqA.isEmpty || seqB.isEmpty) return 0.0;

    final m = seqA.length;
    final n = seqB.length;

    // Ensure short is the shorter sequence for O(min(m,n)) space.
    final short = m <= n ? seqA : seqB;
    final long = m <= n ? seqB : seqA;
    final sLen = short.length;
    final lLen = long.length;

    // Two-row DP with swap: avoids allocating a new list per iteration.
    var prev = List<int>.generate(sLen + 1, (j) => j);
    var curr = List<int>.filled(sLen + 1, 0);

    for (var i = 1; i <= lLen; i++) {
      curr[0] = i;
      for (var j = 1; j <= sLen; j++) {
        final cost = long[i - 1] == short[j - 1] ? 0 : 1;
        curr[j] = min(min(curr[j - 1] + 1, prev[j] + 1), prev[j - 1] + cost);
      }
      final temp = prev;
      prev = curr;
      curr = temp;
    }

    final maxLen = max(sLen, lLen);
    return 1.0 - prev[sLen] / maxLen;
  }

  /// Jaccard similarity on significant character sets (order-insensitive).
  ///
  /// Returns 1.0 for identical character sets, 0.0 for no overlap.
  /// Both empty → 1.0 (vacuously similar).
  static double jaccardSimilarity(String a, String b) {
    final setA = significantChars(a);
    final setB = significantChars(b);
    if (setA.isEmpty && setB.isEmpty) return 1.0;
    if (setA.isEmpty || setB.isEmpty) return 0.0;
    final intersection = setA.intersection(setB).length;
    final union = setA.union(setB).length;
    return union > 0 ? intersection / union : 0.0;
  }

  /// Compute both text similarity metrics for efficient scoring.
  ///
  /// Returns `({levenshtein, jaccard})` — normalized Levenshtein (order-sensitive)
  /// and Jaccard similarity (order-insensitive).
  ///
  /// Useful when you need both scores for decision-making or logging.
  /// If you only need a pass/fail result, use [isTextSimilar] instead.
  static ({double levenshtein, double jaccard}) computeTextSimilarity(
    String a,
    String b,
  ) {
    final lev = normalizedLevenshtein(a, b);
    final jac = jaccardSimilarity(a, b);
    return (levenshtein: lev, jaccard: jac);
  }

  /// Unified text similarity check: Levenshtein primary, Jaccard fallback.
  ///
  /// Returns `true` if either:
  /// 1. Normalized Levenshtein ≥ [levenshteinThreshold] (order-sensitive)
  /// 2. Jaccard similarity ≥ [jaccardThreshold] (catches character reordering)
  ///
  /// Used by gate 3 (spatial overlap band) for consistent text comparison
  /// across all block types.
  static bool isTextSimilar(
    String a,
    String b, {
    double levenshteinThreshold = 0.70,
    double jaccardThreshold = 0.80,
  }) {
    // Reject if either string has no significant characters (punctuation-only).
    // Without this guard, two different punctuation-only strings would produce
    // empty sig char lists → normalizedLevenshtein returns 1.0 → false match.
    if (significantCharList(a).isEmpty || significantCharList(b).isEmpty) {
      return false;
    }
    if (normalizedLevenshtein(a, b) >= levenshteinThreshold) return true;
    if (jaccardSimilarity(a, b) >= jaccardThreshold) return true;
    return false;
  }

  /// Check text similarity and capture computed scores in one call.
  ///
  /// Returns `({match, levenshtein, jaccard})` where [match] is the boolean
  /// result and scores are the computed metrics.
  ///
  /// Useful when you need both the decision and the metrics for logging
  /// without recomputation.
  static ({bool match, double levenshtein, double jaccard})
  isTextSimilarWithScores(
    String a,
    String b, {
    double levenshteinThreshold = 0.70,
    double jaccardThreshold = 0.80,
  }) {
    // Reject punctuation-only strings (empty sig char lists → false 1.0 match).
    if (significantCharList(a).isEmpty || significantCharList(b).isEmpty) {
      return (match: false, levenshtein: 0.0, jaccard: 0.0);
    }
    final scores = computeTextSimilarity(a, b);
    final match =
        scores.levenshtein >= levenshteinThreshold ||
        scores.jaccard >= jaccardThreshold;
    return (
      match: match,
      levenshtein: scores.levenshtein,
      jaccard: scores.jaccard,
    );
  }

  /// Measures how much of [inner]'s text appears in [outer] in order.
  ///
  /// Uses longest common subsequence (LCS) — the right metric for subset
  /// detection. Levenshtein measures edit distance (how different), while
  /// LCS measures containment (how much of A appears in B in order).
  ///
  /// Returns `lcsLength / inner.runes.length` (0.0–1.0).
  /// A ratio ≥ 0.80 indicates a subset relationship.
  ///
  /// O(n×m) but only called during provisional cluster expiry on 2–3
  /// blocks with 50–200 character strings. Negligible cost.
  static double containmentRatio(String inner, String outer) {
    if (inner.isEmpty || outer.isEmpty) return 0.0;
    final a = inner.runes.toList();
    final b = outer.runes.toList();
    final lcsLen = _longestCommonSubsequence(a, b);
    return lcsLen / a.length;
  }

  /// Standard LCS length computation using space-optimized DP.
  ///
  /// Two-row rolling array: O(min(n,m)) space instead of O(n×m).
  /// Inputs beyond 5000 runes are truncated to prevent OOM on
  /// corrupted OCR text — containmentRatio is approximate at that scale.
  static int _longestCommonSubsequence(List<int> a, List<int> b) {
    const maxLen = 5000;
    if (a.length > maxLen) a = a.sublist(0, maxLen);
    if (b.length > maxLen) b = b.sublist(0, maxLen);
    // Ensure b is the shorter list for space optimization.
    if (a.length < b.length) {
      final tmp = a;
      a = b;
      b = tmp;
    }
    final m = b.length;
    var prev = List<int>.filled(m + 1, 0);
    var curr = List<int>.filled(m + 1, 0);
    for (var i = 1; i <= a.length; i++) {
      for (var j = 1; j <= m; j++) {
        if (a[i - 1] == b[j - 1]) {
          curr[j] = prev[j - 1] + 1;
        } else {
          curr[j] = max(curr[j - 1], prev[j]);
        }
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
      curr.fillRange(0, m + 1, 0);
    }
    return prev[m];
  }
}
