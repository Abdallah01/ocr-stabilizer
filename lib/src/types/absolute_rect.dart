import 'dart:ui' show Offset, Rect, Size;

/// Bounding box in absolute coordinates (world-space).
///
/// Wraps [Rect] for zero-cost compile-time coordinate safety.
/// Only this type provides [overlaps] and [expandToInclude] — spatial
/// operations are meaningful only within a single coordinate space.
extension type const AbsoluteRect(Rect raw) {
  /// Creates from left, top, right, bottom coordinates.
  AbsoluteRect.fromLTRB(double l, double t, double r, double b)
    : raw = Rect.fromLTRB(l, t, r, b);

  /// Creates from left, top, width, height.
  AbsoluteRect.fromLTWH(double l, double t, double w, double h)
    : raw = Rect.fromLTWH(l, t, w, h);

  /// A zero-sized rect at the origin.
  static const zero = AbsoluteRect(Rect.zero);

  /// Left edge in absolute coordinates.
  double get left => raw.left;

  /// Top edge in absolute coordinates.
  double get top => raw.top;

  /// Right edge in absolute coordinates.
  double get right => raw.right;

  /// Bottom edge in absolute coordinates.
  double get bottom => raw.bottom;

  /// Width in absolute coordinates.
  double get width => raw.width;

  /// Height in absolute coordinates.
  double get height => raw.height;

  /// Size as a [Size] value.
  Size get size => raw.size;

  /// Center point of the rect.
  Offset get center => raw.center;

  /// Top-left corner of the rect.
  Offset get topLeft => raw.topLeft;

  /// Whether this rect overlaps [other] in world-space.
  bool overlaps(AbsoluteRect other) => raw.overlaps(other.raw);

  /// Returns smallest rect that contains both `this` and [other].
  AbsoluteRect expandToInclude(AbsoluteRect other) =>
      AbsoluteRect(raw.expandToInclude(other.raw));
}
