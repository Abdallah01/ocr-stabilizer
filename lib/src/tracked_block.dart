// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'types/absolute_rect.dart';
import 'types/confidence_types.dart';
import 'types/container_id.dart';
import 'types/scroll_context.dart';
import 'types/sticky_fallback.dart';

/// A block the stabilization engine is tracking across captures.
///
/// Consumers implement this interface with their domain-specific block type.
/// The generic [T] carries an opaque payload the engine passes through without
/// reading — use it for translation data, styling, or any app-specific fields.
///
/// **Coordinate-space invariant:** If [containerId] is non-null, then
/// [isInnerScrollerChild] must be `true`. Violations cause [DriftTracker] to
/// misclassify blocks into wrong coordinate spaces, producing incorrect drift
/// corrections. Implementations should enforce this at construction time.
abstract interface class TrackedBlock<T> {
  /// World-space bounding box in absolute coordinates.
  AbsoluteRect get absoluteRect;

  /// Stable container identifier when the host can compute one.
  /// May be `null` even for inner-scroller children if no stable ID is
  /// available — the engine handles this by assigning [SpaceKey.unknown].
  ///
  /// **Invariant:** If non-null, [isInnerScrollerChild] must be `true`.
  ContainerId? get containerId;

  /// Whether this block uses viewport-relative coordinates (fixed/sticky).
  bool get isViewportRelative;

  /// Whether this block is inside a vertical inner-scroller container.
  bool get isInnerScrollerChild;

  /// Page-absolute top of the inner-scroller element at capture time.
  double get innerScrollerTop;

  /// Whether this block is inside a horizontal scroll container (carousel).
  bool get isHorizontalScrollChild;

  /// Opaque payload — the engine carries it without reading.
  T get payload;

  // ── Textual (identity) ──

  /// Original OCR text (source language) for deduplication and similarity.
  String get originalText;

  // ── Scroll context ──

  /// Scroll offsets and carousel identity at capture time.
  ScrollContext get scrollContext;

  // ── Sticky fallback ──

  /// Whether this block was captured from a `position:sticky` element.
  bool get isFromStickyElement;

  /// Fallback coordinate context if demoted from viewport-relative.
  /// Only meaningful when [isFromStickyElement] is `true`.
  StickyFallback get stickyFallback;

  // ── Confidence ──

  /// Position accuracy confidence. Range [0, 1].
  PositionConfidence get positionConfidence;

  /// OCR text confidence. Range [0, 1].
  TextConfidence get textConfidence;

  // ── Source quality ──

  /// Higher value = higher quality source. Engine prefers the higher tier
  /// during merge. Consumer defines the scale.
  int get sourceQuality;
}
