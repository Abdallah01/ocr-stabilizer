// =============================================================================
// PURE-DART GEOMETRY PRIMITIVES
// =============================================================================
// Package-owned replacements for the `dart:ui` value types this package used
// to depend on ([Offset], [Size], [Rect]). Member names, constructors, and
// numeric semantics intentionally mirror `dart:ui` exactly — including the
// edge cases several tests pin:
//
// - `Rect.overlaps` is strict: rects that merely touch on an edge do NOT
//   overlap.
// - `Rect.intersect` on non-overlapping rects returns a rect with negative
//   width/height (callers gate on `isEmpty`, which is `left >= right ||
//   top >= bottom`).
// - `Rect.lerp` scales toward/from zero when one argument is null and uses
//   plain double lerp (`a * (1 - t) + b * t`) per edge otherwise.
// - `toString` uses `toStringAsFixed(1)` formatting, matching `dart:ui`.
//
// Only the API surface actually used by this package (lib/, test/, example/)
// is implemented. Value equality (`==` / `hashCode`) is field-based.
// =============================================================================

import 'dart:math' as math;

import 'package:meta/meta.dart';

/// Linearly interpolate between two doubles, `dart:ui`-style:
/// `a * (1.0 - t) + b * t`.
double _lerpDouble(double a, double b, double t) => a * (1.0 - t) + b * t;

/// An immutable 2D floating-point offset (a vector), API-compatible with the
/// subset of `dart:ui`'s `Offset` used by this package.
@immutable
class Offset {
  /// Creates an offset with the given [dx] and [dy] components.
  const Offset(this.dx, this.dy);

  /// The x component of the offset.
  final double dx;

  /// The y component of the offset.
  final double dy;

  /// An offset with zero magnitude: `Offset(0.0, 0.0)`.
  static const Offset zero = Offset(0.0, 0.0);

  /// The magnitude (Euclidean length) of the offset.
  double get distance => math.sqrt(dx * dx + dy * dy);

  /// Vector addition: returns an offset whose components are the sums of the
  /// operands' components.
  Offset operator +(Offset other) => Offset(dx + other.dx, dy + other.dy);

  /// Vector subtraction: returns an offset whose components are the
  /// differences of the operands' components.
  Offset operator -(Offset other) => Offset(dx - other.dx, dy - other.dy);

  @override
  bool operator ==(Object other) =>
      other is Offset && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(dx, dy);

  @override
  String toString() =>
      'Offset(${dx.toStringAsFixed(1)}, ${dy.toStringAsFixed(1)})';
}

/// An immutable 2D floating-point size (width and height), API-compatible
/// with the subset of `dart:ui`'s `Size` used by this package.
@immutable
class Size {
  /// Creates a size with the given [width] and [height].
  const Size(this.width, this.height);

  /// The horizontal extent of this size.
  final double width;

  /// The vertical extent of this size.
  final double height;

  /// An empty size: `Size(0.0, 0.0)`.
  static const Size zero = Size(0.0, 0.0);

  @override
  bool operator ==(Object other) =>
      other is Size && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() =>
      'Size(${width.toStringAsFixed(1)}, ${height.toStringAsFixed(1)})';
}

/// An immutable 2D axis-aligned floating-point rectangle whose coordinates
/// are relative to a common origin, API-compatible with the subset of
/// `dart:ui`'s `Rect` used by this package.
///
/// A rect may have a negative width or height (e.g. as produced by
/// [intersect] on disjoint rects); such rects report [isEmpty] as true.
@immutable
class Rect {
  /// Creates a rectangle from its left, top, right, and bottom edges.
  const Rect.fromLTRB(this.left, this.top, this.right, this.bottom);

  /// Creates a rectangle from its left and top edges, its width, and its
  /// height.
  const Rect.fromLTWH(double left, double top, double width, double height)
      : this.fromLTRB(left, top, left + width, top + height);

  /// A rectangle with left, top, right, and bottom edges all at zero.
  static const Rect zero = Rect.fromLTRB(0.0, 0.0, 0.0, 0.0);

  /// The offset of the left edge from the x axis.
  final double left;

  /// The offset of the top edge from the y axis.
  final double top;

  /// The offset of the right edge from the x axis.
  final double right;

  /// The offset of the bottom edge from the y axis.
  final double bottom;

  /// The distance between the left and right edges.
  double get width => right - left;

  /// The distance between the top and bottom edges.
  double get height => bottom - top;

  /// The distance between the upper-left corner and the lower-right corner.
  Size get size => Size(width, height);

  /// The offset of the upper-left corner of this rectangle.
  Offset get topLeft => Offset(left, top);

  /// The offset of the center of this rectangle.
  Offset get center => Offset(left + width / 2.0, top + height / 2.0);

  /// Whether this rectangle encloses zero area.
  ///
  /// Matches `dart:ui` semantics: true when `left >= right` or
  /// `top >= bottom` — i.e. negative-size rects (such as the result of
  /// [intersect] on disjoint rects) are empty.
  bool get isEmpty => left >= right || top >= bottom;

  /// Returns a new rectangle translated by the given horizontal and vertical
  /// distances.
  Rect translate(double translateX, double translateY) => Rect.fromLTRB(
        left + translateX,
        top + translateY,
        right + translateX,
        bottom + translateY,
      );

  /// Returns a new rectangle translated by the given offset.
  Rect shift(Offset offset) => translate(offset.dx, offset.dy);

  /// Returns the intersection of this rectangle and [other].
  ///
  /// Matches `dart:ui` semantics: if the rectangles do not overlap, the
  /// result has a negative width and/or height (check [isEmpty]) rather
  /// than being clamped to zero.
  Rect intersect(Rect other) => Rect.fromLTRB(
        math.max(left, other.left),
        math.max(top, other.top),
        math.min(right, other.right),
        math.min(bottom, other.bottom),
      );

  /// Whether this rectangle and [other] have a non-zero area of overlap.
  ///
  /// Matches `dart:ui` semantics: rectangles that merely touch along an
  /// edge or at a corner do not overlap.
  bool overlaps(Rect other) {
    if (right <= other.left || other.right <= left) return false;
    if (bottom <= other.top || other.bottom <= top) return false;
    return true;
  }

  /// Returns the smallest rectangle that encloses both this rectangle and
  /// [other].
  Rect expandToInclude(Rect other) => Rect.fromLTRB(
        math.min(left, other.left),
        math.min(top, other.top),
        math.max(right, other.right),
        math.max(bottom, other.bottom),
      );

  /// Linearly interpolate between two rectangles.
  ///
  /// Matches `dart:ui` semantics exactly:
  /// - both null → null;
  /// - [a] null → [b] scaled by `t` (grows from zero);
  /// - [b] null → [a] scaled by `1 - t` (shrinks toward zero);
  /// - otherwise each edge is interpolated with `edgeA * (1-t) + edgeB * t`.
  ///
  /// Values of `t` outside `[0, 1]` extrapolate.
  static Rect? lerp(Rect? a, Rect? b, double t) {
    if (b == null) {
      if (a == null) return null;
      final double k = 1.0 - t;
      return Rect.fromLTRB(a.left * k, a.top * k, a.right * k, a.bottom * k);
    }
    if (a == null) {
      return Rect.fromLTRB(b.left * t, b.top * t, b.right * t, b.bottom * t);
    }
    return Rect.fromLTRB(
      _lerpDouble(a.left, b.left, t),
      _lerpDouble(a.top, b.top, t),
      _lerpDouble(a.right, b.right, t),
      _lerpDouble(a.bottom, b.bottom, t),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Rect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'Rect.fromLTRB(${left.toStringAsFixed(1)}, '
      '${top.toStringAsFixed(1)}, ${right.toStringAsFixed(1)}, '
      '${bottom.toStringAsFixed(1)})';
}
