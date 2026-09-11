// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'types/confidence_types.dart';
import 'types/container_id.dart';
import 'types/coordinate_context.dart';
import 'types/scroll_context.dart';
import 'types/sticky_fallback.dart';

/// Per-block metadata the classifier attaches to each classified group:
/// the coordinate frame and the two confidences.
///
/// 3.0 (#147): the seven coordinate fields collapsed into [coordinates];
/// every former field name is still readable as a derived view.
class BlockMeta {
  /// The frame the group's rect is expressed in.
  final CoordinateContext coordinates;

  /// Spatial confidence score from position stability.
  final PositionConfidence positionConfidence;

  /// Text recognition confidence from OCR engine.
  final TextConfidence textConfidence;

  /// Creates block metadata for a classified group.
  const BlockMeta({
    required this.coordinates,
    required this.positionConfidence,
    required this.textConfidence,
  });

  // ── Derived views (the 2.x fields) ──

  /// Whether this block is viewport-relative (fixed/sticky).
  bool get isViewportRelative => coordinates.isViewportRelative;

  /// Whether this block lives inside an inner scrollable container.
  bool get isInnerScrollerChild => coordinates.isInnerScrollerChild;

  /// Page-absolute top of the inner scroller (`0` when not inside one).
  double get innerScrollerTop => coordinates.innerScrollerTop;

  /// Stable hash identifying the DOM container this block belongs to.
  ContainerId? get containerId => coordinates.containerId;

  /// Scroll offsets and carousel index at capture time.
  ScrollContext get captureContext => coordinates.scrollContext;

  /// Whether this block originates from a CSS `position:sticky` element.
  bool get isFromStickyElement => coordinates.isFromStickyElement;

  /// Fallback coordinate context for sticky element demotion.
  StickyFallback get stickyFallback => coordinates.stickyFallback;

  /// Whether this block is a direct child of a horizontal scroller.
  bool get isHorizontalScrollChild => coordinates.isHorizontalScrollChild;

  /// Carousel index from capture context (-1 = not carousel).
  int get hzScrollerIndex => captureContext.hzScrollerIndex;

  /// Vertical scroll offset at capture time.
  double get captureScrollY => captureContext.scrollY;

  /// Horizontal scroll offset at capture time.
  double get captureScrollX => captureContext.scrollX;

  /// Fallback vertical scroll offset for sticky demotion.
  double get stickyFallbackScrollY => stickyFallback.scrollY;

  /// Fallback horizontal scroll offset for sticky demotion.
  double get stickyFallbackScrollX => stickyFallback.scrollX;

  /// Whether the sticky fallback context is inner-scroller.
  bool get stickyFallbackIsIc => stickyFallback.isIc;

  /// Carousel index for the sticky fallback context.
  int get stickyFallbackHzIndex => stickyFallback.hzScrollerIndex;
}
