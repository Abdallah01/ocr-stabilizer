// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

/// Scroll offsets and carousel identity captured at recognition time.
///
/// Groups logically-related fields that together describe where in the
/// scrollable content a block was captured.
class ScrollContext {
  /// Vertical scroll offset baked into the block's absolute rect.
  final double scrollY;

  /// Horizontal scroll offset baked into the block's absolute rect.
  final double scrollX;

  /// Carousel index this block belongs to (-1 = not a carousel block).
  final int hzScrollerIndex;

  /// Creates a scroll context. Defaults represent "no scroll, no carousel".
  const ScrollContext({
    this.scrollY = 0,
    this.scrollX = 0,
    this.hzScrollerIndex = -1,
  });

  /// Sentinel value for "no scroll context".
  static const none = ScrollContext();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ScrollContext &&
          scrollY == other.scrollY &&
          scrollX == other.scrollX &&
          hzScrollerIndex == other.hzScrollerIndex;

  @override
  int get hashCode => Object.hash(scrollY, scrollX, hzScrollerIndex);
}
