import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// ABSOLUTE RECT TESTS
// =============================================================================

void main() {
  group('AbsoluteRect construction', () {
    test('fromLTRB exposes the given edges', () {
      final r = AbsoluteRect.fromLTRB(10, 20, 110, 70);
      expect(r.left, 10);
      expect(r.top, 20);
      expect(r.right, 110);
      expect(r.bottom, 70);
    });

    test('fromLTWH computes right and bottom from width and height', () {
      final r = AbsoluteRect.fromLTWH(10, 20, 100, 50);
      expect(r.left, 10);
      expect(r.top, 20);
      expect(r.right, 110);
      expect(r.bottom, 70);
    });

    test('primary constructor wraps a Rect verbatim', () {
      const rect = Rect.fromLTRB(1, 2, 3, 4);
      const r = AbsoluteRect(rect);
      expect(r.raw, rect);
    });

    test('zero is a zero-sized rect at the origin', () {
      expect(AbsoluteRect.zero.raw, Rect.zero);
      expect(AbsoluteRect.zero.left, 0);
      expect(AbsoluteRect.zero.top, 0);
      expect(AbsoluteRect.zero.width, 0);
      expect(AbsoluteRect.zero.height, 0);
    });
  });

  group('AbsoluteRect accessors', () {
    final r = AbsoluteRect.fromLTWH(10, 20, 100, 50);

    test('width and height', () {
      expect(r.width, 100);
      expect(r.height, 50);
    });

    test('size', () {
      expect(r.size, const Size(100, 50));
    });

    test('center', () {
      expect(r.center, const Offset(60, 45));
    });

    test('topLeft', () {
      expect(r.topLeft, const Offset(10, 20));
    });

    test('raw round-trips to the underlying Rect', () {
      expect(r.raw, const Rect.fromLTRB(10, 20, 110, 70));
    });
  });

  group('AbsoluteRect.overlaps', () {
    test('intersecting rects overlap (both directions)', () {
      final a = AbsoluteRect.fromLTRB(0, 0, 100, 100);
      final b = AbsoluteRect.fromLTRB(50, 50, 150, 150);
      expect(a.overlaps(b), isTrue);
      expect(b.overlaps(a), isTrue);
    });

    test('disjoint rects do not overlap', () {
      final a = AbsoluteRect.fromLTRB(0, 0, 100, 100);
      final b = AbsoluteRect.fromLTRB(200, 200, 300, 300);
      expect(a.overlaps(b), isFalse);
      expect(b.overlaps(a), isFalse);
    });

    test('edge-touching rects do not overlap (Rect semantics)', () {
      final a = AbsoluteRect.fromLTRB(0, 0, 100, 100);
      final b = AbsoluteRect.fromLTRB(100, 0, 200, 100);
      expect(a.overlaps(b), isFalse);
    });

    test('contained rect overlaps its container', () {
      final outer = AbsoluteRect.fromLTRB(0, 0, 100, 100);
      final inner = AbsoluteRect.fromLTRB(25, 25, 75, 75);
      expect(outer.overlaps(inner), isTrue);
      expect(inner.overlaps(outer), isTrue);
    });
  });

  group('AbsoluteRect.expandToInclude', () {
    test('returns smallest rect containing both', () {
      final a = AbsoluteRect.fromLTRB(0, 0, 50, 50);
      final b = AbsoluteRect.fromLTRB(100, 100, 200, 150);
      final union = a.expandToInclude(b);
      expect(union.raw, const Rect.fromLTRB(0, 0, 200, 150));
    });

    test('is symmetric', () {
      final a = AbsoluteRect.fromLTRB(0, 0, 50, 50);
      final b = AbsoluteRect.fromLTRB(100, 100, 200, 150);
      expect(a.expandToInclude(b), b.expandToInclude(a));
    });

    test('container absorbs a contained rect', () {
      final outer = AbsoluteRect.fromLTRB(0, 0, 100, 100);
      final inner = AbsoluteRect.fromLTRB(25, 25, 75, 75);
      expect(outer.expandToInclude(inner), outer);
    });
  });

  group('AbsoluteRect equality (extension type delegates to Rect)', () {
    test('same values compare equal with equal hashCodes', () {
      final a = AbsoluteRect.fromLTRB(10, 20, 110, 70);
      final b = AbsoluteRect.fromLTRB(10, 20, 110, 70);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('fromLTRB and fromLTWH describing the same rect are equal', () {
      expect(
        AbsoluteRect.fromLTRB(10, 20, 110, 70),
        AbsoluteRect.fromLTWH(10, 20, 100, 50),
      );
    });

    test('different values are not equal', () {
      final a = AbsoluteRect.fromLTRB(10, 20, 110, 70);
      final b = AbsoluteRect.fromLTRB(10, 20, 110, 71);
      expect(a, isNot(equals(b)));
    });

    test('zero equals a zero-sized rect built at runtime', () {
      expect(AbsoluteRect.zero, AbsoluteRect.fromLTWH(0, 0, 0, 0));
    });
  });
}
