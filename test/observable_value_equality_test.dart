// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause
//
// PR #138 review: the two 2.5.0 result values are compared by consumers
// (`result.identityTurnover == IdentityTurnover.none`, snapshot
// assertions in tests), so they define value equality; and an all-zero
// census resolves to the canonical `none` by identity.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

void main() {
  group('IdentityTurnover equality', () {
    test('value equality and hashCode over the four counts', () {
      final a =
          IdentityTurnover(merged: 1, admitted: 2, retained: 3, dropped: 4);
      final b =
          IdentityTurnover(merged: 1, admitted: 2, retained: 3, dropped: 4);
      final c =
          IdentityTurnover(merged: 1, admitted: 2, retained: 3, dropped: 5);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });

    test('the factory canonicalises an all-zero census to `none`', () {
      final z =
          IdentityTurnover(merged: 0, admitted: 0, retained: 0, dropped: 0);
      expect(identical(z, IdentityTurnover.none), isTrue);
      expect(z, IdentityTurnover.none);
      expect(IdentityTurnover.none.hashCode, z.hashCode);
    });
  });

  group('CoherentShiftEvent equality', () {
    CoherentShiftEvent e({
      Offset t = const Offset(0, 150),
      int m = 3,
      int a = 0,
      CoherentShiftSource s = CoherentShiftSource.quorum,
    }) =>
        CoherentShiftEvent(
            translation: t, memberCount: m, adoptedCount: a, decidedBy: s);

    test('value equality and hashCode over all four fields', () {
      expect(e(), e());
      expect(e().hashCode, e().hashCode);
      expect(e(), isNot(e(t: const Offset(0, 151))));
      expect(e(), isNot(e(m: 4)));
      expect(e(m: 4), isNot(e(m: 4, a: 1)));
      expect(e(), isNot(e(s: CoherentShiftSource.floor)));
    });
  });
}
