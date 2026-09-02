// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// PR #138 review: the identity census's nested-fragment arms were
// declared (the class doc lists "a nested-fragment confirmation" under
// `merged`, and the engine counts a contradicted host's fragment as
// `admitted`) but no test constructed a nested fragment, so both counters
// could be deleted with the suite green. These cases build them from the
// #112 fixtures (`stabilization_engine_nested_fragment_test.dart`,
// `stabilization_engine_nested_contradiction_test.dart`), and add the two
// contract pins the review asked for: a pure zoom that keeps the line
// texts is a clean re-sighting (U9's wording), and an all-zero census is
// the canonical `IdentityTurnover.none` instance.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

DefaultTrackedBlock<void> _at(Rect r, String text, {int observations = 1}) =>
    DefaultTrackedBlock<void>(
      absoluteRect: AbsoluteRect(r),
      payload: null,
      originalText: text,
      observationCount: observations,
    );

StabilizationEngine<DefaultTrackedBlock<void>, void> _engine({
  int retention = 0,
  SpatialBlockIndex<DefaultTrackedBlock<void>>? index,
}) =>
    StabilizationEngine<DefaultTrackedBlock<void>, void>(
      merger: (existing, fresh, merge) => existing.applyMerge(merge),
      missedFrameRetention: retention,
      spatialIndex: index,
    );

// Geometry from the #112 fixture: a two-line paragraph and its first line.
const Rect kPara = Rect.fromLTWH(33, 754, 300, 52);
const Rect kLine = Rect.fromLTWH(33, 762, 280, 18);
const String kParaText =
    'The quick brown fox jumps over the lazy dog near the river bank';
const String kLineText = 'The quick brown fox jumps';

// The grouping-contradiction fixture: a paragraph and its two lines.
const Rect kHost = Rect.fromLTWH(0, 0, 200, 100);
const Rect kLine1 = Rect.fromLTWH(0, 0, 200, 40);
const Rect kLine2 = Rect.fromLTWH(0, 50, 200, 40);

void main() {
  group('identityTurnover — nested-fragment arms (#112 paths)', () {
    test(
        'a line inside an established paragraph with fragment text is a '
        'nested confirmation: counted as merged, not admitted', () {
      final engine = _engine();
      engine.stabilize([_at(kPara, kParaText)]);
      engine.stabilize([_at(kPara, kParaText)]);
      final t = engine.stabilize([_at(kLine, kLineText)]).identityTurnover;
      expect(t.merged, 1, reason: 'the fragment confirms its host');
      expect(t.admitted, 0);
      expect(t.dropped, 0, reason: 'the host was matched (consumed)');
      expect(t.retained, 0);
    });

    test(
        'a host the grouping detector contradicts is NOT confirmed: its '
        'lines are admitted as new identities and the host is dropped', () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<void>>();
      final engine = _engine(index: index);
      index.add(_at(kHost, 'hello world', observations: 3));
      final r = engine.stabilize([
        _at(kLine1, 'hello'),
        _at(kLine2, 'world'),
      ]);
      expect(r.contradictions, hasLength(1), reason: 'fixture precondition');
      final t = r.identityTurnover;
      expect(t.admitted, 2,
          reason: 'the contradicted-host branch admits each fragment');
      expect(t.merged, 0);
      expect(t.dropped, 1,
          reason: 'retention 0: the unconfirmed host leaves the index');
      expect(t.retained, 0);
    });

    test(
        'a fragment whose host already merged THIS capture is folded, not '
        'counted twice: fresh < the batch size', () {
      final engine = _engine();
      engine.stabilize([_at(kPara, kParaText)]);
      engine.stabilize([_at(kPara, kParaText)]);
      final t = engine.stabilize([
        _at(kPara, kParaText),
        _at(kLine, kLineText),
      ]).identityTurnover;
      // Whether the line is removed as an intra-batch duplicate or folded
      // into its already-merged host, it produces no identity outcome of
      // its own — the documented reason `fresh` can be smaller than the
      // batch passed in.
      expect(t.merged, 1);
      expect(t.admitted, 0);
      expect(t.fresh, 1);
    });
  });

  group('identityTurnover — contract pins (U9, none)', () {
    test(
        'a PURE zoom that keeps the line texts is a clean re-sighting: '
        'every block merges, nothing is admitted, and no coherentShift is '
        'decided (the scaled displacements never agree as one translation)',
        () {
      final engine = _engine(retention: 3);
      List<DefaultTrackedBlock<void>> page(double scale) => [
            for (final (text, top) in [
              ('alpha block text one', 500.0),
              ('bravo block text two', 600.0),
              ('charlie block text three', 700.0),
            ])
              _at(Rect.fromLTWH(0, top * scale, 100 * scale, 20 * scale), text),
          ];
      engine.stabilize(page(1.0));
      engine.stabilize(page(1.0));
      final r = engine.stabilize(page(1.25));
      expect(r.identityTurnover.merged, 3);
      expect(r.identityTurnover.admitted, 0);
      expect(r.identityTurnover.admittedShare, 0.0);
      expect(r.coherentShift, isNull,
          reason: 'displacements 125 / 150 / 175 px grow with distance '
              'from the zoom origin — no single translation clusters them');
    });

    test(
        'an empty capture over an empty engine reports the canonical '
        'IdentityTurnover.none instance (identical, not merely equal)', () {
      final t = _engine().stabilize([]).identityTurnover;
      expect(identical(t, IdentityTurnover.none), isTrue);
      expect(t, IdentityTurnover.none);
    });
  });
}
