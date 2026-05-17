import 'types/confidence_types.dart';
import 'types/container_id.dart';
import 'types/scroll_context.dart';
import 'types/sticky_fallback.dart';

/// Per-block metadata collected during classification.
///
/// Captures all classification flags and confidence scores for a group,
/// parallel to the group's absolute rect. Uses [ScrollContext] and
/// [StickyFallback] to group semantically related scroll fields.
class BlockMeta {
  /// Whether this block is viewport-relative (fixed/sticky).
  final bool isViewportRelative;

  /// Whether this block lives inside an inner scrollable container.
  final bool isInnerScrollerChild;

  /// CSS top offset of the inner scroller relative to viewport.
  final double innerScrollerTop;

  /// Stable hash identifying the DOM container this block belongs to.
  final ContainerId? containerId;

  /// Scroll offsets and carousel index at capture time.
  final ScrollContext captureContext;

  /// Whether this block originates from a CSS `position:sticky` element.
  final bool isFromStickyElement;

  /// Fallback coordinate context for sticky element demotion.
  final StickyFallback stickyFallback;

  /// Spatial confidence score from position stability.
  final PositionConfidence positionConfidence;

  /// Text recognition confidence from OCR engine.
  final TextConfidence textConfidence;

  /// Creates block metadata for a classified group.
  const BlockMeta({
    required this.isViewportRelative,
    required this.isInnerScrollerChild,
    required this.innerScrollerTop,
    required this.captureContext,
    required this.positionConfidence,
    required this.textConfidence,
    this.containerId,
    this.isFromStickyElement = false,
    this.stickyFallback = const StickyFallback(),
  });

  // ── Convenience accessors for backward compatibility ──

  /// Whether this block is a direct child of a horizontal scroller.
  bool get isHorizontalScrollChild =>
      captureContext.hzScrollerIndex >= 0 && !isViewportRelative;

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
