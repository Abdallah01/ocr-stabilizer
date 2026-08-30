// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause
//
// #119 item 2: on the measured 150 px pushdown capture the coherent-shift
// quorum DOES form (three short movers clear their own-height "moved"
// gate), but 13 taller pairs that made the SAME step sit under their gate
// (3x a 57-62 px height = 171-186 px > 150) and damp — so the decided
// translation reaches 3 of the 16 pairs that moved together, and the rest
// lag by the damped fraction. `coherentShiftAdoptAgreeing` (opt-in, default
// OFF) carries an eligible under-gate pair along once a translation has
// been decided, if its displacement is within the quorum's own tolerance
// (`coherentShiftTolerance x min(own height, the group's median height)`)
// of that translation. It never changes who may VOTE or what the vote is.
//
// Fixture: three 20 px blocks (gate 60 px) and one 60 px block (gate
// 180 px), all stepping dy +150 in one capture. Idiom of
// stabilization_engine_coherent_shift_frozen_drift_test.dart.
//
// Membership is observed through `MergeResult.stepResponseApplied` (null
// for a pair merged as damp, `coherentShift` for a member), not only
// through the merged position: the ordinary merge weight pulls a
// wrongly-adopted pair back toward its own observation, so a position
// assertion alone could not tell "not adopted" from "adopted then pulled
// back" (found by mutation).
import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/step_response.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(
  String text, {
  required double top,
  double height = 20,
}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(0, top, 100, height),
      payload: const Object(),
      originalText: text,
      observationCount: 3,
    );

const _a = 'alpha block text one';
const _b = 'bravo block text two';
const _c = 'charlie block text three';
const _tall = 'tall block text four';
const _short = [_a, _b, _c];

typedef _Outcome = ({
  Map<String, double> tops,
  Map<String, StepResponse?> steps,
});

/// Seeds [shortCount] short blocks (tops 500, 600, 700) and one tall block
/// (top 800, 60 px), then steps the short ones by +150 and the tall one by
/// [tallDy]. Returns each block's merged top and the step response its
/// merge applied, by text.
_Outcome _run({
  required bool adopt,
  double tallDy = 150,
  double? floorPx,
  int shortCount = 3,
}) {
  final tops = <String, double>{};
  final steps = <String, StepResponse?>{};
  final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
    merger: (existing, fresh, m) {
      final merged = existing.applyMerge(m);
      tops[fresh.originalText] = merged.absoluteRect.raw.top;
      steps[fresh.originalText] = m.stepResponseApplied;
      return merged;
    },
    stepResponse: StepResponse.coherentShift,
    coherentShiftAdoptAgreeing: adopt,
    coherentShiftFloorPx: floorPx,
    missedFrameRetention: 3,
  );
  final texts = _short.take(shortCount).toList();
  engine.stabilize([
    for (var i = 0; i < texts.length; i++)
      _block(texts[i], top: 500 + 100.0 * i),
    _block(_tall, top: 800, height: 60),
  ]);
  engine.stabilize([
    for (var i = 0; i < texts.length; i++)
      _block(texts[i], top: 650 + 100.0 * i),
    _block(_tall, top: 800 + tallDy, height: 60),
  ]);
  return (tops: tops, steps: steps);
}

const _voterTop = {_a: 650.0, _b: 750.0, _c: 850.0};

void main() {
  group('coherentShiftAdoptAgreeing (#119 item 2)', () {
    test(
        'OFF (default): the quorum fires for the three short movers, and the '
        'tall pair that made the same step damps short of its observation — '
        'the blind spot the lever closes', () {
      final off = _run(adopt: false);
      for (final t in _short) {
        expect(off.tops[t], closeTo(_voterTop[t]!, 0.5),
            reason: '$t is a voting member; its merge applies the translation');
        expect(off.steps[t], StepResponse.coherentShift);
      }
      expect(off.steps[_tall], isNull,
          reason: 'under its 180 px gate the tall pair cannot vote and is '
              'not carried along — merged as damp');
      expect(off.tops[_tall], lessThan(949.5),
          reason: 'it damps short of 950');
      expect(off.tops[_tall], greaterThan(800));
    });

    test(
        'ON: the tall under-gate pair whose displacement matches the decided '
        'translation is adopted and merged with it — it lands where it was '
        'observed; the voters are untouched', () {
      final on = _run(adopt: true);
      expect(on.steps[_tall], StepResponse.coherentShift,
          reason: 'adopted: merged as a member');
      expect(on.tops[_tall], closeTo(950, 0.5),
          reason: 'baseline translated by the decided +150, then the '
              'ordinary merge against a zero residual');
      for (final t in _short) {
        expect(on.tops[t], closeTo(_voterTop[t]!, 0.5),
            reason: 'adoption widens membership only');
        expect(on.steps[t], StepResponse.coherentShift);
      }
    });

    test(
        'ON: an under-gate pair whose displacement DISAGREES with the '
        'translation is not adopted — never pushed past its own observation',
        () {
      final on = _run(adopt: true, tallDy: 40);
      expect(on.steps[_tall], isNull,
          reason: '110 px off the decided translation — merged as damp, '
              'not as a member');
      expect(on.tops[_tall], lessThanOrEqualTo(840.5),
          reason: 'never past its own observation');
      expect(on.tops[_tall], greaterThan(800));
    });

    test(
        'ON: the tolerance is the quorum rule — coherentShiftTolerance x '
        'min(own height, the group median height) — so a tall pair 20 px '
        'off the translation is NOT adopted (10 px allowed by the 20 px '
        'group, not 30 px by its own 60 px height)', () {
      final twentyOff = _run(adopt: true, tallDy: 130);
      expect(twentyOff.steps[_tall], isNull,
          reason: '20 px off: outside 0.5 x min(60, 20) = 10 px');
      final eightOff = _run(adopt: true, tallDy: 142);
      expect(eightOff.steps[_tall], StepResponse.coherentShift,
          reason: '8 px off: inside the 10 px allowance — adopted');
    });

    test(
        'ON: adoption also follows a plan the floor fallback decided (a lone '
        'mover clearing coherentShiftFloorPx)', () {
      final on = _run(adopt: true, shortCount: 1, floorPx: 100);
      expect(on.tops[_a], closeTo(650, 0.5),
          reason: 'the lone mover is re-anchored by the floor');
      expect(on.steps[_tall], StepResponse.coherentShift,
          reason: 'the agreeing tall pair follows the floor-decided shift');
      expect(on.tops[_tall], closeTo(950, 0.5));
      final off = _run(adopt: false, shortCount: 1, floorPx: 100);
      expect(off.steps[_tall], isNull,
          reason: 'CONTROL — without the lever the floor re-anchors its '
              'lone mover only');
      expect(off.tops[_tall], lessThan(949.5));
    });

    test('ON with no decided plan is identical to OFF (nothing to follow)',
        () {
      final on = _run(adopt: true, shortCount: 1);
      final off = _run(adopt: false, shortCount: 1);
      expect(on.tops, equals(off.tops));
      expect(on.steps, equals(off.steps));
      expect(on.steps.values, everyElement(isNull),
          reason: 'one short mover cannot form a quorum and no fallback is '
              'set — the lever has no plan to widen, so a control capture '
              'with no group is untouched by construction');
    });

    // MUTATION-VERIFY TARGET (#119 item 2): opt-in, like the two fallbacks.
    test('defaults to OFF', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
      );
      expect(engine.coherentShiftAdoptAgreeing, isFalse,
          reason: 'DEFAULT-OFF PIN: shipping it enabled would change the '
              'numerics for every consumer without them asking');
    });
  });
}
