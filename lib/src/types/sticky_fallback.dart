// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

/// Fallback coordinate context for sticky elements demoted from viewport-relative.
///
/// When a `position:sticky` element loses its VR status (e.g. scroll passes
/// its sticky threshold), these values describe where it should be positioned
/// in normal or inner-scroller coordinate space.
///
/// Only meaningful when the block's `isFromStickyElement` is `true`.
class StickyFallback {
  /// Fallback scroll Y if demoted from viewport-relative.
  final double scrollY;

  /// Fallback scroll X if demoted from viewport-relative.
  final double scrollX;

  /// Whether the fallback context is an inner-scroller.
  final bool isIc;

  /// Carousel index for the fallback context (-1 = not carousel).
  final int hzScrollerIndex;

  /// Creates a sticky fallback context.
  const StickyFallback({
    this.scrollY = 0,
    this.scrollX = 0,
    this.isIc = false,
    this.hzScrollerIndex = -1,
  });

  /// Sentinel value for "no sticky fallback".
  static const none = StickyFallback();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StickyFallback &&
          scrollY == other.scrollY &&
          scrollX == other.scrollX &&
          isIc == other.isIc &&
          hzScrollerIndex == other.hzScrollerIndex;

  @override
  int get hashCode => Object.hash(scrollY, scrollX, isIc, hzScrollerIndex);
}
