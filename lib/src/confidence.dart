// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'types/geometry.dart' show Rect;

import 'internal/cjk_ideographs.dart';
import 'ocr_block.dart';

// =============================================================================
// CONFIDENCE SCORING FUNCTIONS
// =============================================================================
// Pure functions for OCR block confidence estimation.
// Extracted from OcrService to enable reuse across platforms.
// =============================================================================

/// Compute a freshness score (0.0–1.0) from the age of the vitals snapshot.
///
/// - Age < 200 ms → 1.0 (vitals are effectively live).
/// - Age > 2000 ms → 0.3 (vitals are stale).
/// - Between 200–2000 ms → linear interpolation.
double computeFreshness(int vitalsAgeMs) {
  if (vitalsAgeMs < 200) return 1.0;
  if (vitalsAgeMs > 2000) return 0.3;
  return 1.0 - (vitalsAgeMs - 200) / (2000 - 200) * (1.0 - 0.3);
}

/// Compute a geometry-stability score (0.0–1.0) from the position delta
/// between the new block and the nearest prior block with matching text.
///
/// When [referenceHeight] is provided (average block height in CSS px),
/// thresholds scale proportionally:
/// - Stable:   `(referenceHeight × 0.15).clamp(5, 20)` px
/// - Unstable: `(referenceHeight × 1.0).clamp(30, 120)` px
///
/// Without [referenceHeight], falls back to fixed 10 / 60 px thresholds.
double computeStability(double? delta, {double? referenceHeight}) {
  if (delta == null) return 0.5;
  final double stableThreshold;
  final double unstableThreshold;
  if (referenceHeight != null && referenceHeight > 0) {
    stableThreshold = (referenceHeight * 0.15).clamp(5.0, 20.0);
    unstableThreshold = (referenceHeight * 1.0).clamp(30.0, 120.0);
  } else {
    stableThreshold = 10.0;
    unstableThreshold = 60.0;
  }
  if (delta < stableThreshold) return 1.0;
  if (delta > unstableThreshold) return 0.3;
  return 1.0 -
      (delta - stableThreshold) /
          (unstableThreshold - stableThreshold) *
          (1.0 - 0.3);
}

/// Compute text confidence for a group of OCR blocks.
///
/// When native per-block confidence is available (e.g. PaddleOCR),
/// uses weighted mean by character count. When confidence is null
/// (ML Kit), falls back to the CJK/entropy/aspect proxy heuristic.
double computeTextConfidence(List<OcrBlock> group) {
  if (group.isEmpty) return 0.3;

  double weightedSum = 0;
  int weightedChars = 0;
  for (final b in group) {
    if (b.confidence != null && b.confidence!.isFinite) {
      final chars = b.text.runes.length;
      weightedSum += b.confidence! * chars;
      weightedChars += chars;
    }
  }
  if (weightedChars > 0) {
    return (weightedSum / weightedChars).clamp(0.0, 1.0);
  }

  final fullText = group.map((b) => b.text).join('');
  final boundingBoxes = group.map((b) {
    final r = b.boundingBox;
    return Rect.fromLTRB(
      r.left.toDouble(),
      r.top.toDouble(),
      r.right.toDouble(),
      r.bottom.toDouble(),
    );
  }).toList();
  return computeTextConfidenceRaw(fullText, boundingBoxes);
}

/// Pure implementation of the text-confidence heuristic.
///
/// Accepts plain [text] and optional [boundingBoxes] (from OCR bounds) so
/// this can be called from unit tests without OCR dependencies.
///
/// Combines three signals:
/// - CJK character ratio (50% weight)
/// - Text entropy / length heuristic (30% weight)
/// - Aspect ratio vs expected character width (20% weight)
double computeTextConfidenceRaw(
  String text, [
  List<Rect> boundingBoxes = const [],
]) {
  if (text.isEmpty) return 0.3;

  // ── 1. CJK character ratio ──
  int cjkCount = 0;
  int totalRunes = 0;
  for (final r in text.runes) {
    totalRunes++;
    if (isCjkIdeograph(r)) cjkCount++;
  }
  final cjkRatio = totalRunes > 0 ? cjkCount / totalRunes : 0.0;
  // Map: pure CJK (1.0) → 0.9, no CJK (0.0) → 0.5
  final cjkScore = 0.5 + cjkRatio * 0.4;

  // ── 2. Text entropy / length heuristic ──
  double entropyScore = 1.0;
  if (totalRunes <= 2) {
    entropyScore = 0.5;
  } else {
    final charCounts = <int, int>{};
    for (final r in text.runes) {
      charCounts[r] = (charCounts[r] ?? 0) + 1;
    }
    final maxFreq = charCounts.values.reduce((a, b) => a > b ? a : b);
    final dominanceRatio = maxFreq / totalRunes;
    if (dominanceRatio > 0.6) {
      entropyScore = 0.5 + (1.0 - dominanceRatio) * 0.5;
    }
  }

  // ── 3. Aspect ratio ──
  double aspectScore = 1.0;
  if (boundingBoxes.isNotEmpty) {
    double minLeft = double.infinity, minTop = double.infinity;
    double maxRight = double.negativeInfinity,
        maxBottom = double.negativeInfinity;
    for (final r in boundingBoxes) {
      if (r.left < minLeft) minLeft = r.left;
      if (r.top < minTop) minTop = r.top;
      if (r.right > maxRight) maxRight = r.right;
      if (r.bottom > maxBottom) maxBottom = r.bottom;
    }
    final width = maxRight - minLeft;
    final height = maxBottom - minTop;
    if (height > 0 && totalRunes > 0) {
      final expectedWidth = height * totalRunes;
      final widthRatio = expectedWidth > 0 ? width / expectedWidth : 1.0;
      if (widthRatio > 3.0) {
        aspectScore = 0.6;
      } else if (widthRatio > 2.0) {
        aspectScore = 0.8;
      }
    }
  }

  final combined = cjkScore * 0.5 + entropyScore * 0.3 + aspectScore * 0.2;
  return combined.clamp(0.0, 1.0);
}

/// Whether [rune] is a CJK Unified Ideograph.
///
/// Covers:
/// - CJK Unified Ideographs (U+4E00–U+9FFF)
/// - CJK Extension A (U+3400–U+4DBF)
/// - CJK Compatibility Ideographs (U+F900–U+FAFF)
/// - CJK Extension B (U+20000–U+2A6DF)
///
/// Delegates to the shared internal predicate also used by
/// `TextDedupUtils`, so confidence scoring and dedup agree on what
/// counts as CJK.
bool isCjkIdeograph(int rune) => isCjkIdeographRune(rune);
