// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// =============================================================================
// MERGE DECISION DIAGNOSTICS
// =============================================================================
// Optional observability for [ParagraphGrouper]: WHY a candidate block did
// or did not merge into the open paragraph, and why a block was dropped
// outright. Off by default — the grouper allocates nothing on this path
// unless a callback is installed.
// =============================================================================

import 'ocr_block.dart';

/// Why [ParagraphGrouper] refused a merge — or dropped a block outright.
///
/// The first seven values are merge-decision guards evaluated against the
/// open paragraph; the reported set contains EVERY guard that fired, not
/// just the first (the decision itself is a conjunction, so any single
/// reason is sufficient to split). The last two are block-drop reasons:
/// the block never entered grouping at all.
enum MergeRejectReason {
  /// The vertical gap to the open paragraph is at or beyond the effective
  /// threshold (Otsu/Docstrum when available, else the adaptive
  /// height-based threshold, punctuation multipliers applied).
  gapExceedsThreshold,

  /// The candidate's X range does not overlap the open paragraph's within
  /// the em/width-proportional tolerance.
  noXOverlap,

  /// Single-block paragraph and the candidate is an outlier-tall block
  /// (IQR fence when the batch is large enough, else the fixed 3x ratio
  /// with more lines).
  heightRatio,

  /// Single-block paragraph that is itself 3x taller than the candidate
  /// (e.g. a title followed by tag pills).
  reverseHeightRatio,

  /// The candidate sits BESIDE a paragraph block (vertical overlap with
  /// horizontal separation) — an inline peer, never a wrapped line.
  inlinePeer,

  /// The open paragraph already holds `maxParagraphBlocks` blocks.
  blockCountCap,

  /// Merging would push the paragraph past `maxParagraphRunes` runes.
  runeCap,

  /// Block drop: zero-area bounding box — unpositionable downstream.
  degenerateBox,

  /// Block drop: rune density below the noise floor combined with an
  /// abnormal aspect ratio or character height (OCR artifact).
  noiseGuard,
}

/// One grouping decision, reported through
/// [ParagraphGrouper.onMergeDecision].
///
/// Two shapes share this class:
///
/// - **Merge decisions** ([paragraphLength] >= 1): the candidate was
///   evaluated against an open paragraph. [gap], [threshold], and
///   [xTolerance] carry the numbers the guards compared.
/// - **Block drops** ([paragraphLength] == 0, reasons
///   [MergeRejectReason.degenerateBox] or [MergeRejectReason.noiseGuard]):
///   the block was rejected before any merge evaluation; the numeric
///   fields are null.
///
/// A block that STARTS a paragraph is not a decision and is not reported.
/// Sub-blocks produced by the sentence-end explosion pre-pass bypass
/// grouping entirely and are likewise not reported.
class MergeDecisionDiagnostic {
  /// Creates a diagnostic. Constructed by the grouper; consumers only read.
  const MergeDecisionDiagnostic({
    required this.accepted,
    required this.reasons,
    required this.candidate,
    required this.paragraphLength,
    this.gap,
    this.threshold,
    this.xTolerance,
  });

  /// Whether the candidate merged into the open paragraph.
  final bool accepted;

  /// Every guard that fired — empty exactly when [accepted] is true.
  final Set<MergeRejectReason> reasons;

  /// The block being decided on.
  final OcrBlock candidate;

  /// Blocks in the open paragraph at decision time (0 for block drops).
  final int paragraphLength;

  /// Vertical gap (px) from the paragraph's bottom to the candidate's top.
  /// Negative when the candidate overlaps or sits beside the paragraph.
  /// Null for block drops.
  final double? gap;

  /// The effective merge threshold the gap was compared against, with
  /// punctuation multipliers applied. Null for block drops.
  final double? threshold;

  /// The X-overlap tolerance in effect (the largest of the 2.5-em indent
  /// allowance, 15% of paragraph width, and the `lineGapThreshold` floor).
  /// Null for block drops.
  final double? xTolerance;
}

/// Signature for [ParagraphGrouper.onMergeDecision].
typedef MergeDecisionCallback = void Function(MergeDecisionDiagnostic decision);
