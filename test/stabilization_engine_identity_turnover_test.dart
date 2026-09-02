// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// 2.5.0 — `StabilizationResult.identityTurnover`: the per-capture identity
// census. `merged` = fresh blocks that merged into a tracked identity
// (primary, band, nested); `admitted` = fresh blocks that became NEW
// identities; `retained` = cached identities nothing matched, kept by
// missed-frame retention; `dropped` = cached identities that left
// tracking this capture (retention expired, cross-frame supersession, or
// retention 0). The rewrap shape a consumer wants to detect is "most
// fresh blocks admitted as new, no coherent shift decided" — the
// dynamic-reflow entry's 23-of-30 rewrap frame.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

DefaultTrackedBlock<Object> _block(String text, {required double top}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(0, top, 100, 20),
      payload: const Object(),
      originalText: text,
      observationCount: 1,
    );

StabilizationEngine<DefaultTrackedBlock<Object>, Object> _engine(
        {int retention = 3}) =>
    StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
      merger: (existing, fresh, m) => existing.applyMerge(m),
      missedFrameRetention: retention,
    );

const _a = 'alpha block text one';
const _b = 'bravo block text two';
const _c = 'charlie block text three';
const _d = 'delta block text four';
const _e = 'echo block text five';
const _f = 'foxtrot block text six';

List<DefaultTrackedBlock<Object>> _abc() => [
      _block(_a, top: 500),
      _block(_b, top: 600),
      _block(_c, top: 700),
    ];

void main() {
  group('StabilizationResult.identityTurnover (2.5.0)', () {
    test('first capture: every fresh block is admitted as a new identity', () {
      final t = _engine().stabilize(_abc()).identityTurnover;
      expect(t.admitted, 3);
      expect(t.merged, 0);
      expect(t.retained, 0);
      expect(t.dropped, 0);
      expect(t.fresh, 3);
      expect(t.admittedShare, 1.0);
    });

    test('a re-sighting merges every block: admitted 0, share 0.0', () {
      final engine = _engine();
      engine.stabilize(_abc());
      final t = engine.stabilize(_abc()).identityTurnover;
      expect(t.merged, 3);
      expect(t.admitted, 0);
      expect(t.retained, 0);
      expect(t.dropped, 0);
      expect(t.admittedShare, 0.0);
    });

    test(
        'REWRAP shape: new line texts in the same boxes — all admitted, '
        'the old identities superseded (dropped), none retained', () {
      final engine = _engine();
      engine.stabilize(_abc());
      engine.stabilize(_abc());
      final t = engine.stabilize([
        _block(_d, top: 500),
        _block(_e, top: 600),
        _block(_f, top: 700),
      ]).identityTurnover;
      expect(t.admitted, 3);
      expect(t.merged, 0);
      expect(t.admittedShare, 1.0);
      expect(t.dropped, 3,
          reason: 'cross-frame supersession (2.1.0): a fresh block covering '
              'an unmatched cached block evicts it rather than retaining '
              'two boxes on one region');
      expect(t.retained, 0);
    });

    test(
        'partial rewrap: 2 re-sighted + 2 new at fresh positions — share '
        '0.5, the unmatched third identity retained', () {
      final engine = _engine();
      engine.stabilize(_abc());
      final t = engine.stabilize([
        _block(_a, top: 500),
        _block(_b, top: 600),
        _block(_d, top: 800),
        _block(_e, top: 900),
      ]).identityTurnover;
      expect(t.merged, 2);
      expect(t.admitted, 2);
      expect(t.admittedShare, 0.5);
      expect(t.retained, 1, reason: '$_c missed once, within retention 3');
      expect(t.dropped, 0);
    });

    test(
        'missed-frame retention: unmatched identities are retained for '
        'exactly missedFrameRetention captures, then dropped', () {
      final engine = _engine(retention: 3);
      engine.stabilize(_abc());
      final onlyA = [_block(_a, top: 500)];
      for (var miss = 1; miss <= 3; miss++) {
        final t = engine.stabilize(onlyA).identityTurnover;
        expect(t.merged, 1, reason: 'miss $miss');
        expect(t.retained, 2, reason: 'miss $miss: b and c still retained');
        expect(t.dropped, 0, reason: 'miss $miss');
      }
      final t = engine.stabilize(onlyA).identityTurnover;
      expect(t.retained, 0, reason: 'miss 4 exceeds retention 3');
      expect(t.dropped, 2, reason: 'b and c expire together');
    });

    test('retention 0: every unmatched cached identity is dropped at once', () {
      final engine = _engine(retention: 0);
      engine.stabilize(_abc());
      final t = engine.stabilize([_block(_a, top: 500)]).identityTurnover;
      expect(t.merged, 1);
      expect(t.retained, 0);
      expect(t.dropped, 2);
    });

    test('an empty capture: nothing fresh, everything cached retained', () {
      final engine = _engine();
      engine.stabilize(_abc());
      final t = engine.stabilize([]).identityTurnover;
      expect(t.fresh, 0);
      expect(t.admittedShare, 0.0);
      expect(t.retained, 3);
      expect(t.dropped, 0);
    });
  });
}
