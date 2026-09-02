// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'block_meta.dart';
import 'ocr_block.dart';
import 'types/absolute_rect.dart';

/// A single OCR group after classification with its computed coordinates
/// and metadata.
class ClassifiedGroup {
  /// The original OCR blocks in this group.
  final List<OcrBlock> group;

  /// Absolute bounding rect in CSS pixels (world-space).
  final AbsoluteRect absoluteRect;

  /// Classification metadata (block type, scroll context, confidence).
  final BlockMeta meta;

  /// Creates a classified OCR group.
  ClassifiedGroup({
    required this.group,
    required this.absoluteRect,
    required this.meta,
  });
}

/// Result of classifying OCR text groups.
///
/// Contains all groups that passed classification (exclusion, viewport
/// guard, animation deferral). The consumer handles dedup and
/// translation-cache splitting.
class ClassificationResult {
  /// Groups that passed all classification filters.
  final List<ClassifiedGroup> classified;

  /// CSS pixels per screenshot pixel, for element-level rect conversion.
  final double cssPerImagePx;

  /// Number of groups dropped by exclusion zone overlap.
  final int droppedExclusion;

  /// Number of groups dropped by viewport height guard.
  final int droppedViewport;

  /// Number of groups deferred due to carousel animation.
  final int deferredAnimating;

  /// Creates a classification result with the given groups and counters.
  const ClassificationResult({
    required this.classified,
    required this.cssPerImagePx,
    this.droppedExclusion = 0,
    this.droppedViewport = 0,
    this.deferredAnimating = 0,
  });
}
