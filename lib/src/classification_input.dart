// =============================================================================
// CLASSIFICATION INPUT INTERFACE
// =============================================================================
// Platform-agnostic abstraction for viewport geometry at screenshot time.
//
// Decouples BlockClassifierService from WebView-specific snapshot types,
// enabling future extraction to the package and reuse for PDF, camera, etc.
// =============================================================================

import 'dart:ui' show Rect;

import 'types/container_id.dart';

/// Input geometry for block classification.
///
/// Captures the viewport state at screenshot time. Platform-specific
/// implementations (WebView, PDF viewer, camera) provide their own
/// construction logic; the classifier operates on this abstraction.
abstract interface class ClassificationInput {
  // ── Viewport geometry ──

  /// Vertical scroll offset (page-space pixels).
  double get scrollY;

  /// Horizontal scroll offset (page-space pixels).
  double get scrollX;

  /// Scale factor converting image pixels to CSS/layout pixels.
  /// For WebView: `dpr * visualViewportScale`.
  double get imageToLayoutScale;

  /// Visual viewport height in layout pixels.
  double get viewportHeight;

  /// Visual viewport top in page coordinates.
  double get viewportPageTop;

  // ── Inner-scroller context ──

  /// Whether an inner-scroller container is active.
  bool get hasInnerScroller;

  /// Page-absolute top of the inner-scroller element.
  double get innerScrollerTop;

  /// Client height of the inner-scroller element.
  double get innerScrollerHeight;

  /// Affine transform matrix for the inner-scroller (CSS matrix 6-tuple).
  /// Null if no transform is applied.
  List<double>? get innerScrollerTransform;

  /// Stable container ID for the active inner-scroller.
  ContainerId? get innerScrollerContainerId;

  // ── Carousel context ──

  /// Information about active horizontal scroll containers.
  List<CarouselInput> get carousels;

  // ── Timestamp ──

  /// When the viewport state was captured (for freshness scoring).
  DateTime get captureTime;
}

/// Carousel (horizontal scroller) geometry at capture time.
abstract interface class CarouselInput {
  /// Bounding rect of the carousel container in page coordinates.
  Rect get rect;

  /// Current horizontal scroll offset within the carousel.
  double get scrollLeft;

  /// CSS transform matrix (6-tuple), or null if none.
  List<double>? get transform;

  /// Whether the carousel is currently animating.
  bool get isAnimating;
}
