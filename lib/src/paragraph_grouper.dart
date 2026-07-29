// =============================================================================
// PARAGRAPH GROUPER
// =============================================================================
// CJK-aware grouping of OCR text blocks into paragraph-level units.
//
// OCR engines (ML Kit, Tesseract, Vision) return text at block granularity
// that rarely matches visual paragraphs: wrapped lines of one paragraph come
// back as separate blocks, while unrelated UI elements (tag pills, toolbar
// items) sit close enough to merge under naive fixed-pixel gap heuristics.
// [ParagraphGrouper] reconstructs paragraph units using data-driven gap
// clustering plus a set of guards tuned on real CJK novel pages:
//
// - Otsu-thresholded gap clustering (data-driven paragraph separation)
// - Adaptive height-proportional gap threshold (DPR/font-size invariant)
// - CJK sentence-ending punctuation awareness (。！？…)
// - Tukey IQR height fences + aspect/density noise guards
// - Inline-peer detection (side-by-side elements never merge)
// =============================================================================

import 'dart:math' as math;

import 'internal/cjk_ideographs.dart';
import 'ocr_block.dart';
import 'otsu_threshold.dart';
import 'robust_stats.dart';
import 'types/geometry.dart';

/// Groups OCR text blocks into paragraph-level units for translation or
/// layout analysis.
///
/// The grouper is stateless across calls: each [groupIntoParagraphs] call
/// computes batch statistics (median character height, Tukey IQR height
/// fence, Otsu gap threshold) from that call's blocks only.
///
/// Configuration is immutable; construct a new instance to change knobs.
class ParagraphGrouper {
  /// Creates a [ParagraphGrouper].
  ///
  /// All parameters are validated at construction; invalid values throw
  /// [ArgumentError] (throwing rather than asserting so misconfiguration
  /// surfaces in release builds too).
  ParagraphGrouper({
    this.lineGapThreshold = 10.0,
    this.lineGapMultiplier = 0.75,
    this.maxParagraphBlocks = 3,
    this.maxParagraphRunes = 200,
  }) {
    if (!lineGapThreshold.isFinite || lineGapThreshold < 0) {
      throw ArgumentError.value(lineGapThreshold, 'lineGapThreshold',
          'must be finite and >= 0');
    }
    if (!lineGapMultiplier.isFinite || lineGapMultiplier <= 0) {
      throw ArgumentError.value(lineGapMultiplier, 'lineGapMultiplier',
          'must be finite and > 0');
    }
    if (maxParagraphBlocks < 1) {
      throw ArgumentError.value(
          maxParagraphBlocks, 'maxParagraphBlocks', 'must be >= 1');
    }
    if (maxParagraphRunes < 1) {
      throw ArgumentError.value(
          maxParagraphRunes, 'maxParagraphRunes', 'must be >= 1');
    }
  }

  /// Maximum allowed vertical gap (in image pixels) between text lines for
  /// them to be merged into the same paragraph. Acts as a floor for the
  /// adaptive threshold and as the horizontal tolerance floor for X-overlap
  /// checks (indentation, jitter).
  ///
  /// Cold-start fallback: 10.0 px matches a fixed paragraph gap on a 1x-DPR
  /// layout; the adaptive threshold takes over as soon as block heights are
  /// known.
  final double lineGapThreshold;

  /// Multiplier applied to average block height to compute the adaptive gap
  /// threshold. The effective threshold is:
  ///   `min(max(lineGapThreshold, avgHeight * lineGapMultiplier),
  ///        avgHeight * 2.0)`
  /// Default 0.75 captures standard CSS line-height (~1.5×) gaps.
  final double lineGapMultiplier;

  /// Maximum number of blocks that can be merged into one paragraph.
  /// Prevents aggressive merging on pages with many consecutive paragraphs
  /// that have small gaps. The default (3) allows wrapped 2-3 line sentences
  /// to merge while capping multi-paragraph mega-blocks.
  final int maxParagraphBlocks;

  /// Maximum total runes across all blocks in a merged paragraph.
  /// Prevents two full paragraphs from merging into one oversized unit.
  /// The default (200) ≈ 3 typical CJK sentences.
  final int maxParagraphRunes;

  /// Hard ceiling multiplier — gaps beyond 2× average block height are never
  /// merged, regardless of [lineGapMultiplier].
  static const double _kMaxGapMultiplier = 2.0;

  /// Height-ratio threshold for tag-row / paragraph split guard.
  /// When the current paragraph has exactly one block and the candidate
  /// block is at least this many times taller (with more text lines),
  /// the merge is rejected — the blocks are treated as distinct visual
  /// elements (e.g., an inline tag row followed by a paragraph).
  static const double _kHeightRatioSplitThreshold = 3.0;

  /// CJK sentence-ending punctuation runes. When the last rune of the
  /// current paragraph is one of these, apply a stricter gap threshold
  /// (the sentence is likely complete).
  static const Set<int> _kSentenceEndRunes = {
    0x3002, // 。 (CJK full stop)
    0xFF01, // ！ (fullwidth exclamation)
    0xFF1F, // ？ (fullwidth question mark)
    0x2026, // … (ellipsis)
  };

  /// Multiplier for gap threshold when the last rune is sentence-ending
  /// punctuation (paragraph likely complete → stricter threshold).
  static const double _kSentenceEndMultiplier = 0.6;

  /// Multiplier for gap threshold when the last rune is mid-sentence
  /// (comma, enumeration, or CJK ideograph).
  ///
  /// Currently 1.0 — an identity, deliberately. A boost here over-merges
  /// CJK paragraphs where nearly every line ends with an ideograph. The
  /// branch is retained as the seam where a mid-sentence boost would go
  /// if a future corpus justifies one; it is intentionally not exposed
  /// as configuration.
  static const double _kMidSentenceMultiplier = 1.0;

  /// Minimum rune density (runes per image px² area) below which a block
  /// is considered OCR noise / artifact and rejected from merging.
  /// Computed in the same image-coordinate space as [OcrBlock.boundingBox].
  /// A 200×200px box with 1 rune → density 0.000025 (below threshold).
  /// A 400×60px box with 3 runes → density 0.000125 (above threshold).
  static const double _kMinRuneDensity = 0.00005;

  /// Fallback fraction of paragraph width used as X-overlap tolerance.
  /// Used alongside the font-size-based 2.5-em tolerance — the larger of
  /// the two is applied.
  static const double _kXOverlapWidthFraction = 0.15;

  /// ICDAR baseline aspect ratio bounds for valid text regions (1:8 to 8:1).
  static const double _kMinAspectRatio = 0.125;
  static const double _kMaxAspectRatio = 8.0;

  /// Maximum character height relative to batch median (variance guard).
  /// 2.5× accommodates h1/h2 headings (typically 2–2.5× body text) while
  /// still catching OCR phantom blocks (4–10× the median).
  static const double _kMaxCharHeightFactor = 2.5;

  /// Otsu-method gap threshold from inter-block gap distribution.
  ///
  /// Finds the natural break between intra-paragraph (line spacing) and
  /// inter-paragraph (paragraph spacing) gaps using Otsu's method, which
  /// maximizes inter-class variance. Returns `null` if fewer than 3 gaps
  /// or the distribution is unimodal.
  ///
  /// Requires ≥3 gaps for OCR robustness (Otsu's method needs ≥2, but 3
  /// provides safety margin against noise).
  static double? _docstrumGapThreshold(List<double> gaps) {
    if (gaps.length < 3) return null;
    final sorted = List<double>.from(gaps)..sort();
    return otsusThreshold(sorted);
  }

  /// Compute the adaptive gap threshold for merging [candidate] into
  /// [paragraph]. Returns:
  ///   `min(max(lineGapThreshold, avgHeight * lineGapMultiplier),
  ///        avgHeight * _kMaxGapMultiplier)`
  ///
  /// This scales with font size / DPR automatically — large text on a
  /// high-DPR device produces taller blocks and therefore a larger
  /// threshold.
  double _effectiveGapThreshold(
      List<OcrBlock> paragraph, OcrBlock candidate) {
    final avgHeight = _avgBlockHeight(paragraph, candidate);
    final adaptive = avgHeight * lineGapMultiplier;
    final ceiling = avgHeight * _kMaxGapMultiplier;
    return math.min(math.max(lineGapThreshold, adaptive), ceiling);
  }

  /// Mean bounding-box height of [paragraph] blocks and [candidate].
  static double _avgBlockHeight(
      List<OcrBlock> paragraph, OcrBlock candidate) {
    double total = candidate.boundingBox.height;
    for (final b in paragraph) {
      total += b.boundingBox.height;
    }
    return total / (paragraph.length + 1);
  }

  /// Group text blocks into paragraphs based on vertical AND horizontal
  /// proximity.
  ///
  /// Blocks are merged when:
  /// 1. Their vertical gap is less than the **adaptive threshold** (based on
  ///    average block height, floored by [lineGapThreshold], capped at 2×
  ///    block height), AND
  /// 2. Their X ranges overlap (with a tolerance of 15 % of the current
  ///    paragraph width, floored by [lineGapThreshold]).
  ///
  /// The adaptive threshold scales with font size and DPR, so wrapped lines
  /// of Chinese text on high-DPR devices merge correctly without requiring
  /// manual threshold tuning.
  ///
  /// The horizontal overlap check prevents side-by-side elements (carousel
  /// cards, inline genre links) from being merged into one wide unit.
  /// The width-proportional tolerance (15 % of paragraph width) accommodates
  /// standard Chinese 2 em paragraph indentation without merging elements
  /// in genuinely separate columns.
  List<List<OcrBlock>> groupIntoParagraphs(List<OcrBlock> blocks) {
    // ── Pre-grouping: explode multi-line OcrBlocks at sentence boundaries ──
    // The OCR engine sometimes merges distinct paragraphs into one OcrBlock
    // with multiple lines. Split these at lines ending with sentence-ending
    // punctuation (。！？…) so the grouper can treat them independently.
    // Exploded sub-blocks have zero gap (contiguous lines from the same
    // original block), so we emit them as separate groups directly rather
    // than feeding them back into the gap-based grouper.
    final preGrouped = <List<OcrBlock>>[]; // groups from explosion
    final remaining = <OcrBlock>[]; // blocks for normal grouping
    for (final block in blocks) {
      if (block.lines.length <= 1) {
        remaining.add(block);
        continue;
      }
      final splitIndices = <int>[];
      for (int i = 0; i < block.lines.length - 1; i++) {
        final lineText = block.lines[i].text;
        if (lineText.isNotEmpty &&
            _kSentenceEndRunes.contains(lineText.runes.last)) {
          splitIndices.add(i);
        }
      }
      if (splitIndices.isEmpty) {
        remaining.add(block);
        continue;
      }
      // Create separate OcrBlocks for each sentence group
      int lineStart = 0;
      for (final splitAfter in [...splitIndices, block.lines.length - 1]) {
        final subLines = block.lines.sublist(lineStart, splitAfter + 1);
        if (subLines.isEmpty) continue;
        // Single-pass bounding box from sub-lines
        Rect subBox = subLines.first.boundingBox;
        for (int j = 1; j < subLines.length; j++) {
          subBox = subBox.expandToInclude(subLines[j].boundingBox);
        }
        // Each sub-block becomes its own group (skips gap-based grouping)
        preGrouped.add([
          OcrBlock(
            text: subLines.map((l) => l.text).join(' '),
            lines: subLines,
            boundingBox: subBox,
          ),
        ]);
        lineStart = splitAfter + 1;
      }
    }

    final sortedBlocks = [...remaining]
      ..sort((a, b) => a.boundingBox.top.compareTo(b.boundingBox.top));

    // ── Batch statistics for data-driven guards ──
    // Compute median character height and IQR upper fence for height
    // outliers.
    final charHeights = sortedBlocks
        .map((b) => b.boundingBox.height / math.max(1, b.lines.length))
        .toList()
      ..sort();
    // True median: averages the two middle elements for even-length input
    // rather than picking the upper-middle. The latter biases the
    // height-ratio / inline-peer guards slightly upward on every batch
    // with an even number of blocks.
    final medianCharHeight =
        RobustStats.medianOfSorted(charHeights) ?? 0.0;
    // Height-ratio: IQR upper fence for block heights (Tukey's fence).
    final blockHeights = sortedBlocks.map((b) => b.boundingBox.height).toList()
      ..sort();
    double? heightUpperFence;
    if (blockHeights.length >= 8) {
      final q1 = blockHeights[blockHeights.length ~/ 4];
      final q3 = blockHeights[(3 * blockHeights.length) ~/ 4];
      final iqr = q3 - q1;
      heightUpperFence = q3 + 1.5 * iqr;
    }

    // ── Docstrum gap threshold (data-driven paragraph separation) ──
    // Pre-compute inter-block vertical gaps, skipping noise blocks so
    // they don't pollute the gap distribution.
    final allGaps = <double>[];
    OcrBlock? prevValid;
    for (final block in sortedBlocks) {
      final area = block.boundingBox.width * block.boundingBox.height;
      if (area <= 0 || block.text.runes.length / area < _kMinRuneDensity) {
        continue;
      }
      if (prevValid != null) {
        final gap = block.boundingBox.top - prevValid.boundingBox.bottom;
        if (gap > 0) allGaps.add(gap);
      }
      prevValid = block;
    }
    final docstrumThreshold = _docstrumGapThreshold(allGaps);

    final List<List<OcrBlock>> paragraphs = [];
    List<OcrBlock> currentParagraph = [];
    double lastBottom = -1e9;
    double paragraphLeft = 0;
    double paragraphRight = 0;

    // Local helper to flush currentParagraph and start a new one.
    void startNewParagraph(OcrBlock block) {
      if (currentParagraph.isNotEmpty) {
        paragraphs.add(currentParagraph);
      }
      currentParagraph = [block];
      lastBottom = block.boundingBox.bottom;
      paragraphLeft = block.boundingBox.left;
      paragraphRight = block.boundingBox.right;
    }

    for (final block in sortedBlocks) {
      final gap = block.boundingBox.top - lastBottom;

      // ── Heuristic 3: Data-driven noise guard ──
      // Primary: aspect ratio (ICDAR baseline: valid text regions 1:8 to
      // 8:1) + character height variance (< 2.5× median from batch).
      // Secondary: legacy density check as fallback.
      final blockArea = block.boundingBox.width * block.boundingBox.height;
      if (blockArea <= 0) continue;
      final aspectRatio = block.boundingBox.width / block.boundingBox.height;
      final badAspect =
          aspectRatio < _kMinAspectRatio || aspectRatio > _kMaxAspectRatio;
      final charH = block.boundingBox.height / math.max(1, block.lines.length);
      final badCharHeight = medianCharHeight > 0 &&
          charH > medianCharHeight * _kMaxCharHeightFactor;
      final lowDensity =
          block.text.runes.length / blockArea < _kMinRuneDensity;
      // Discard if density is low AND aspect or char-height is abnormal.
      if (lowDensity && (badAspect || badCharHeight)) {
        continue;
      }

      // ── Heuristic 1: Dynamic 2.5-character indentation tolerance ──
      // Use approximate font size from block height / line count to compute
      // a CJK-aware indent tolerance (2.5 characters wide) instead of a
      // fixed percentage of paragraph width. The width-based tolerance
      // (paragraphWidth × 15%) still changes as blocks widen the paragraph,
      // but the font-size component is fixed from the first block.
      bool xOverlaps = true;
      if (currentParagraph.isNotEmpty) {
        // Use the FIRST block to establish baseline font size so the
        // font-based tolerance doesn't shift as blocks with different
        // heights are added.
        final baseBlock = currentParagraph.first;
        final lineCount = baseBlock.lines.isEmpty ? 1 : baseBlock.lines.length;
        final approxFontSize = baseBlock.boundingBox.height / lineCount;
        final emBasedTolerance = approxFontSize * 2.5;
        final paragraphWidth = paragraphRight - paragraphLeft;
        final widthBasedTolerance = paragraphWidth * _kXOverlapWidthFraction;
        final xTolerance = math.max(
            lineGapThreshold, math.max(emBasedTolerance, widthBasedTolerance));
        xOverlaps = block.boundingBox.left < paragraphRight + xTolerance &&
            block.boundingBox.right > paragraphLeft - xTolerance;
      }

      // ── Heuristic 2: Punctuation-aware gap threshold ──
      // If the last rune of the current paragraph is sentence-ending
      // punctuation (。！？…), apply a stricter gap threshold since the
      // paragraph is likely complete. If it's mid-sentence (，、or a
      // CJK ideograph), the multiplier is currently an identity (see
      // [_kMidSentenceMultiplier]).
      // Use Docstrum threshold if available (data-driven from gap
      // distribution), else fall back to adaptive height-based threshold.
      double threshold;
      if (currentParagraph.isEmpty) {
        threshold = docstrumThreshold ?? lineGapThreshold;
      } else {
        threshold =
            docstrumThreshold ?? _effectiveGapThreshold(currentParagraph, block);
        // Punctuation multipliers still apply on top of Docstrum threshold
        // for fine-tuning sentence-boundary decisions.
        final lastText = currentParagraph.last.text;
        if (lastText.isNotEmpty) {
          final lastRune = lastText.runes.last;
          if (_kSentenceEndRunes.contains(lastRune)) {
            threshold *= _kSentenceEndMultiplier;
          } else if (lastRune == 0xFF0C || // ，
              lastRune == 0x3001 || // 、
              isCjkIdeographRune(lastRune)) {
            threshold *= _kMidSentenceMultiplier;
          }
        }
      }

      // Height-ratio guard: refuse to merge blocks with very different
      // heights. Uses IQR upper fence (Tukey's fence) when the batch is
      // large enough (≥8 blocks), else a fixed 3× ratio.
      final bool heightRatioReject;
      if (currentParagraph.length == 1) {
        final currentBlock = currentParagraph.first;
        if (heightUpperFence != null) {
          // Data-driven: reject if either block is an outlier
          heightRatioReject = block.boundingBox.height > heightUpperFence ||
              currentBlock.boundingBox.height > heightUpperFence;
        } else {
          // Fallback: fixed 3× ratio
          heightRatioReject = currentBlock.boundingBox.height > 0 &&
              block.boundingBox.height >=
                  currentBlock.boundingBox.height *
                      _kHeightRatioSplitThreshold &&
              block.lines.length > currentBlock.lines.length;
        }
      } else {
        heightRatioReject = false;
      }

      // Reverse height-ratio guard: refuse to merge a much shorter candidate
      // (e.g., genre tag pills) into a tall single block (e.g., a title).
      final bool reverseHeightRatioReject;
      if (currentParagraph.length == 1) {
        final currentBlock = currentParagraph.first;
        reverseHeightRatioReject = block.boundingBox.height > 0 &&
            currentBlock.boundingBox.height >=
                block.boundingBox.height * _kHeightRatioSplitThreshold;
      } else {
        reverseHeightRatioReject = false;
      }

      // ── Heuristic 4: Inline peer detection ──
      // If the candidate sits beside (not below) ANY block in the paragraph
      // — i.e. they overlap vertically but are separated horizontally by
      // ≥ 0.5 em — they are inline peers (genre tag pills, toolbar items)
      // and must NOT merge. Checks all paragraph blocks (not just .last)
      // so the result is deterministic regardless of sort order for blocks
      // at the same Y position.
      bool inlinePeerReject = false;
      if (currentParagraph.isNotEmpty) {
        final blockRect = block.boundingBox;

        for (final paragraphBlock in currentParagraph) {
          final pRect = paragraphBlock.boundingBox;

          final overlapTop = math.max(pRect.top, blockRect.top);
          final overlapBottom = math.min(pRect.bottom, blockRect.bottom);
          final verticalOverlap = overlapBottom - overlapTop;
          final shorterHeight = math.min(pRect.height, blockRect.height);

          if (shorterHeight > 0 && verticalOverlap > shorterHeight * 0.5) {
            final lineCount =
                paragraphBlock.lines.isEmpty ? 1 : paragraphBlock.lines.length;
            final approxFont = pRect.height / lineCount;
            if (blockRect.left > pRect.right + approxFont * 0.5) {
              inlinePeerReject = true;
              break;
            }
          }
        }
      }

      final currentRunes = currentParagraph.fold<int>(
          0, (sum, b) => sum + b.text.runes.length);

      if (currentParagraph.isEmpty ||
          (currentParagraph.length < maxParagraphBlocks &&
              gap < threshold &&
              xOverlaps &&
              !heightRatioReject &&
              !reverseHeightRatioReject &&
              !inlinePeerReject &&
              currentRunes + block.text.runes.length <= maxParagraphRunes)) {
        currentParagraph.add(block);
        lastBottom = math.max(lastBottom, block.boundingBox.bottom);
        if (currentParagraph.length == 1) {
          paragraphLeft = block.boundingBox.left;
          paragraphRight = block.boundingBox.right;
        } else {
          paragraphLeft = math.min(paragraphLeft, block.boundingBox.left);
          paragraphRight = math.max(paragraphRight, block.boundingBox.right);
        }
      } else {
        startNewParagraph(block);
      }
    }

    if (currentParagraph.isNotEmpty) {
      paragraphs.add(currentParagraph);
    }

    // Merge pre-grouped (exploded) blocks with normally grouped blocks,
    // sorted by Y position so downstream consumers see document order.
    final all = [...preGrouped, ...paragraphs];
    all.sort((a, b) {
      final aTop = a.first.boundingBox.top;
      final bTop = b.first.boundingBox.top;
      return aTop.compareTo(bTop);
    });
    return all;
  }

  /// Group each text block as an individual line (granular mode).
  ///
  /// The trivial counterpart to [groupIntoParagraphs] for callers that want
  /// per-block units behind the same `List<List<OcrBlock>>` interface.
  List<List<OcrBlock>> groupByLines(List<OcrBlock> blocks) {
    return blocks.map((block) => [block]).toList();
  }
}
