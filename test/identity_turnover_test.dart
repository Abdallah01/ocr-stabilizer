// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// `IdentityTurnover` is the per-capture identity census on
// `StabilizationResult` (2.5.0): how many fresh blocks merged into a
// tracked identity, how many were admitted as NEW identities, and what
// happened to the cached identities nothing matched. The consumer-side
// use is rewrap detection — a capture where most fresh blocks are new
// identities while no coherent shift was decided is the "same page, new
// line boxes" shape the dynamic-reflow entry measured (23 of 30 admitted
// as new on the rewrap frame).
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

void main() {
  group('IdentityTurnover invariants', () {
    test('valid construction exposes the four counts', () {
      final t =
          IdentityTurnover(merged: 7, admitted: 23, retained: 2, dropped: 1);
      expect(t.merged, 7);
      expect(t.admitted, 23);
      expect(t.retained, 2);
      expect(t.dropped, 1);
    });

    test('fresh = merged + admitted; admittedShare = admitted / fresh', () {
      final t =
          IdentityTurnover(merged: 7, admitted: 23, retained: 0, dropped: 0);
      expect(t.fresh, 30);
      expect(t.admittedShare, closeTo(23 / 30, 1e-9));
    });

    test('admittedShare is 0.0 (not NaN) on an empty capture', () {
      final t =
          IdentityTurnover(merged: 0, admitted: 0, retained: 4, dropped: 0);
      expect(t.fresh, 0);
      expect(t.admittedShare, 0.0);
    });

    test('`none` is the all-zero census and is const', () {
      const n = IdentityTurnover.none;
      expect(n.merged, 0);
      expect(n.admitted, 0);
      expect(n.retained, 0);
      expect(n.dropped, 0);
      expect(n.fresh, 0);
      expect(n.admittedShare, 0.0);
      expect(identical(n, IdentityTurnover.none), isTrue);
    });

    test('every count must be >= 0', () {
      expect(
          () => IdentityTurnover(
              merged: -1, admitted: 0, retained: 0, dropped: 0),
          throwsA(isA<ArgumentError>()));
      expect(
          () => IdentityTurnover(
              merged: 0, admitted: -1, retained: 0, dropped: 0),
          throwsA(isA<ArgumentError>()));
      expect(
          () => IdentityTurnover(
              merged: 0, admitted: 0, retained: -1, dropped: 0),
          throwsA(isA<ArgumentError>()));
      expect(
          () => IdentityTurnover(
              merged: 0, admitted: 0, retained: 0, dropped: -1),
          throwsA(isA<ArgumentError>()));
    });

    test('toString names every count', () {
      final s =
          IdentityTurnover(merged: 7, admitted: 23, retained: 2, dropped: 1)
              .toString();
      expect(s, contains('merged=7'));
      expect(s, contains('admitted=23'));
      expect(s, contains('retained=2'));
      expect(s, contains('dropped=1'));
    });
  });

  test('StabilizationResult defaults: no coherent shift, `none` turnover', () {
    const r = StabilizationResult<Object>(stableBlocks: []);
    expect(r.coherentShift, isNull);
    expect(identical(r.identityTurnover, IdentityTurnover.none), isTrue);
  });
}
