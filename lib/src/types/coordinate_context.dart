// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// =============================================================================
// COORDINATE CONTEXT (#147, 3.0)
// =============================================================================
// Which frame a block's `absoluteRect` is expressed in, as one sealed type.
// Before 3.0 `Observation` carried eight separate getters for this —
// `isViewportRelative`, `isInnerScrollerChild`, `innerScrollerTop`,
// `isHorizontalScrollChild`, `containerId`, `scrollContext`,
// `isFromStickyElement`, `stickyFallback` — and the combinations the engine
// never expected (a container id without an inner scroller, a carousel child
// without a carousel index, an inner-scroller top on a page block) were only
// rejected by scattered invariants. The three variants here make those
// combinations unrepresentable; the eight legacy names survive as derived
// views (on this type and, through `ObservationCoordinateViews`, on every
// block) so the engine's read sites and a consumer's existing code keep
// reading the same values.
// =============================================================================

import 'package:meta/meta.dart';

import 'container_id.dart';
import 'scroll_context.dart';
import 'sticky_fallback.dart';

/// The frame a block's rect is expressed in.
///
/// Three shapes, matching what a DOM/OCR classifier can observe:
///
/// - [CoordinateContext.page] — page-absolute; the default. A block inside
///   a horizontal scroller (carousel) is a page block whose
///   [ScrollContext.hzScrollerIndex] is `>= 0`.
/// - [CoordinateContext.innerScroller] — inside a vertical inner scroller
///   whose page-absolute [InnerScrollerCoordinates.top] is known; the
///   optional [ContainerId] gives the drift tracker a stable space key.
///   May also sit inside a carousel.
/// - [CoordinateContext.viewport] — `position: fixed` or `sticky`: the
///   rect is viewport-relative, no scroll is baked in, and a sticky origin
///   carries the [StickyFallback] a consumer demotes it to. Never a
///   carousel child.
///
/// The eight 2.x getters are available as views on every variant.
@immutable
sealed class CoordinateContext {
  const CoordinateContext._();

  /// Page-absolute coordinates (the default).
  const factory CoordinateContext.page({ScrollContext scroll}) =
      PageCoordinates;

  /// Inside a vertical inner scroller.
  const factory CoordinateContext.innerScroller({
    required double top,
    ContainerId? containerId,
    ScrollContext scroll,
  }) = InnerScrollerCoordinates;

  /// Viewport-relative (`position: fixed` or `sticky`).
  const factory CoordinateContext.viewport({StickyFallback? stickyFallback}) =
      ViewportCoordinates;

  /// Adapter for a consumer that still holds the 2.x flat flags. Builds the
  /// matching variant, or throws [ArgumentError] for a combination the
  /// sealed type cannot express:
  ///
  /// - `containerId` without `isInnerScrollerChild`;
  /// - `innerScrollerTop != 0` without `isInnerScrollerChild`;
  /// - `isInnerScrollerChild` together with `isViewportRelative`;
  /// - `isHorizontalScrollChild` without a carousel index in
  ///   `scrollContext`, or a carousel index without the flag (on a
  ///   non-viewport block);
  /// - `isFromStickyElement` without `isViewportRelative`.
  ///
  /// On a viewport block the scroll context (including any carousel index)
  /// is dropped — a viewport-relative rect has no scroll baked in and is
  /// never a carousel child, exactly as the classifier populated it.
  factory CoordinateContext.fromFlags({
    bool isViewportRelative = false,
    bool isInnerScrollerChild = false,
    double innerScrollerTop = 0,
    bool isHorizontalScrollChild = false,
    ContainerId? containerId,
    ScrollContext scrollContext = ScrollContext.none,
    bool isFromStickyElement = false,
    StickyFallback stickyFallback = StickyFallback.none,
  }) {
    if (containerId != null && !isInnerScrollerChild) {
      throw ArgumentError(
          'containerId requires isInnerScrollerChild (got $containerId)');
    }
    if (innerScrollerTop != 0 && !isInnerScrollerChild) {
      throw ArgumentError('innerScrollerTop requires isInnerScrollerChild '
          '(got $innerScrollerTop)');
    }
    if (isFromStickyElement && !isViewportRelative) {
      throw ArgumentError('isFromStickyElement requires isViewportRelative');
    }
    if (isViewportRelative) {
      if (isInnerScrollerChild) {
        throw ArgumentError(
            'a block cannot be viewport-relative and an inner-scroller child');
      }
      if (isHorizontalScrollChild) {
        throw ArgumentError(
            'a viewport-relative block is never a horizontal-scroll child');
      }
      return ViewportCoordinates(
          stickyFallback: isFromStickyElement ? stickyFallback : null);
    }
    final inCarousel = scrollContext.hzScrollerIndex >= 0;
    if (isHorizontalScrollChild != inCarousel) {
      throw ArgumentError(
          'isHorizontalScrollChild=$isHorizontalScrollChild disagrees with '
          'scrollContext.hzScrollerIndex=${scrollContext.hzScrollerIndex}');
    }
    if (isInnerScrollerChild) {
      return InnerScrollerCoordinates(
        top: innerScrollerTop,
        containerId: containerId,
        scroll: scrollContext,
      );
    }
    return PageCoordinates(scroll: scrollContext);
  }

  // ── Derived views (the 2.x getters) ──

  /// Whether the rect is viewport-relative (fixed/sticky).
  bool get isViewportRelative;

  /// Whether the block sits inside a vertical inner scroller.
  bool get isInnerScrollerChild;

  /// Page-absolute top of the inner scroller (`0` when not inside one).
  double get innerScrollerTop;

  /// Whether the block sits inside a horizontal scroller (carousel).
  bool get isHorizontalScrollChild;

  /// Stable id of the inner scroller, when the host could compute one.
  ContainerId? get containerId;

  /// Scroll offsets baked into the rect and the carousel index
  /// ([ScrollContext.none] for a viewport-relative block).
  ScrollContext get scrollContext;

  /// Whether the block came from a `position: sticky` element.
  bool get isFromStickyElement;

  /// The context a sticky block is demoted to ([StickyFallback.none]
  /// unless [isFromStickyElement]).
  StickyFallback get stickyFallback;
}

/// Page-absolute coordinates.
final class PageCoordinates extends CoordinateContext {
  /// Creates page-absolute coordinates; [scroll] carries the offsets baked
  /// into the rect and, when `hzScrollerIndex >= 0`, the carousel.
  const PageCoordinates({this.scroll = ScrollContext.none}) : super._();

  /// Scroll offsets and carousel index at capture time.
  final ScrollContext scroll;

  @override
  bool get isViewportRelative => false;
  @override
  bool get isInnerScrollerChild => false;
  @override
  double get innerScrollerTop => 0;
  @override
  bool get isHorizontalScrollChild => scroll.hzScrollerIndex >= 0;
  @override
  ContainerId? get containerId => null;
  @override
  ScrollContext get scrollContext => scroll;
  @override
  bool get isFromStickyElement => false;
  @override
  StickyFallback get stickyFallback => StickyFallback.none;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PageCoordinates && other.scroll == scroll;

  @override
  int get hashCode => Object.hash(PageCoordinates, scroll);

  @override
  String toString() => 'CoordinateContext.page(scroll: $scroll)';
}

/// Inside a vertical inner scroller.
final class InnerScrollerCoordinates extends CoordinateContext {
  /// Creates inner-scroller coordinates. [top] is the scroller element's
  /// page-absolute top at capture time; [containerId] its stable id when
  /// the host can compute one.
  const InnerScrollerCoordinates({
    required this.top,
    this.containerId,
    this.scroll = ScrollContext.none,
  }) : super._();

  /// Page-absolute top of the inner scroller at capture time.
  final double top;

  @override
  final ContainerId? containerId;

  /// Scroll offsets and carousel index at capture time.
  final ScrollContext scroll;

  @override
  bool get isViewportRelative => false;
  @override
  bool get isInnerScrollerChild => true;
  @override
  double get innerScrollerTop => top;
  @override
  bool get isHorizontalScrollChild => scroll.hzScrollerIndex >= 0;
  @override
  ScrollContext get scrollContext => scroll;
  @override
  bool get isFromStickyElement => false;
  @override
  StickyFallback get stickyFallback => StickyFallback.none;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InnerScrollerCoordinates &&
          other.top == top &&
          other.containerId == containerId &&
          other.scroll == scroll;

  @override
  int get hashCode =>
      Object.hash(InnerScrollerCoordinates, top, containerId, scroll);

  @override
  String toString() => 'CoordinateContext.innerScroller(top: $top, '
      'containerId: $containerId, scroll: $scroll)';
}

/// Viewport-relative (`position: fixed` or `sticky`).
final class ViewportCoordinates extends CoordinateContext {
  /// Creates viewport-relative coordinates. A non-null [stickyFallback]
  /// marks a `position: sticky` origin and carries the context a consumer
  /// demotes the block to.
  const ViewportCoordinates({StickyFallback? stickyFallback})
      : _stickyFallback = stickyFallback,
        super._();

  final StickyFallback? _stickyFallback;

  @override
  bool get isViewportRelative => true;
  @override
  bool get isInnerScrollerChild => false;
  @override
  double get innerScrollerTop => 0;
  @override
  bool get isHorizontalScrollChild => false;
  @override
  ContainerId? get containerId => null;
  @override
  ScrollContext get scrollContext => ScrollContext.none;
  @override
  bool get isFromStickyElement => _stickyFallback != null;
  @override
  StickyFallback get stickyFallback => _stickyFallback ?? StickyFallback.none;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ViewportCoordinates && other._stickyFallback == _stickyFallback;

  @override
  int get hashCode => Object.hash(ViewportCoordinates, _stickyFallback);

  @override
  String toString() =>
      'CoordinateContext.viewport(stickyFallback: $_stickyFallback)';
}
