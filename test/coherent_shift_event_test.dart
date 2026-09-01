// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause
//
// `CoherentShiftEvent` is the capture-level record of a decided coherent
// shift (2.5.0). Its invariants are engine-output invariants, so they
// throw rather than degrade (CONTRIBUTING: production-critical invariants
// on stored state must throw).
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

CoherentShiftEvent _event({
  Offset translation = const Offset(0, 150),
  int memberCount = 3,
  int adoptedCount = 0,
  CoherentShiftSource decidedBy = CoherentShiftSource.quorum,
}) =>
    CoherentShiftEvent(
      translation: translation,
      memberCount: memberCount,
      adoptedCount: adoptedCount,
      decidedBy: decidedBy,
    );

void main() {
  group('CoherentShiftEvent invariants', () {
    test('valid construction succeeds and exposes its fields', () {
      final e = _event(adoptedCount: 1, memberCount: 4);
      expect(e.translation, const Offset(0, 150));
      expect(e.memberCount, 4);
      expect(e.adoptedCount, 1);
      expect(e.votedCount, 3,
          reason: 'voters = members minus the adopted under-gate pairs');
      expect(e.decidedBy, CoherentShiftSource.quorum);
    });

    test(
        'memberCount must be >= 1 — an event with nobody following it is '
        'not an event', () {
      expect(() => _event(memberCount: 0), throwsA(isA<ArgumentError>()));
      expect(() => _event(memberCount: -1), throwsA(isA<ArgumentError>()));
    });

    test(
        'adoptedCount must sit in [0, memberCount] — adopted pairs are a '
        'SUBSET of the members', () {
      expect(() => _event(adoptedCount: -1), throwsA(isA<ArgumentError>()));
      expect(() => _event(memberCount: 2, adoptedCount: 3),
          throwsA(isA<ArgumentError>()));
      expect(() => _event(memberCount: 2, adoptedCount: 2), returnsNormally,
          reason: 'every member adopted is legal for a floor-decided plan '
              'whose lone voter is joined by agreeing pairs');
    });

    test('translation must be finite', () {
      expect(() => _event(translation: const Offset(double.nan, 0)),
          throwsA(isA<ArgumentError>()));
      expect(() => _event(translation: const Offset(0, double.infinity)),
          throwsA(isA<ArgumentError>()));
    });

    test('toString names every field (walk-log greppable)', () {
      final s = _event(memberCount: 4, adoptedCount: 1).toString();
      expect(s, contains('quorum'));
      expect(s, contains('members=4'));
      expect(s, contains('adopted=1'));
      expect(s, contains('150'));
    });
  });
}
