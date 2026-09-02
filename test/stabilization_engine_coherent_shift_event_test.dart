// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// 2.5.0 — the capture-level coherent-shift event. Before this, a consumer
// could learn that a shift was applied only per block (`MergeResult
// .stepResponseApplied`, delivered through its own merger callback) and
// never the decided translation, how many pairs followed it, how many of
// those were adopted under-gate pairs, or WHICH path decided it (the
// quorum, the #119 absolute-pixel floor, or the #119 batch re-anchor).
// `StabilizationResult.coherentShift` carries exactly that, and nothing
// else: a capture where no plan was decided (every control stream, damp,
// snap) reports null.
//
// Fixture: the adopt-agreeing idiom — three 20 px voters (gate 60 px) and
// one 60 px tall block (gate 180 px); a +150 step clears the voters' gate
// and sits under the tall one's, so adoption is observable in
// `adoptedCount`. The per-block wire is cross-checked on every run: the
// event's `memberCount` MUST equal the number of merger callbacks that
// carried `stepResponseApplied == coherentShift` — the event is a
// summary of merges that actually happened, not of the plan alone.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

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

const _short = [
  'alpha block text one',
  'bravo block text two',
  'charlie block text three'
];
const _tall = 'tall block text four';

typedef _Run = ({
  StabilizationResult<DefaultTrackedBlock<Object>> seed,
  StabilizationResult<DefaultTrackedBlock<Object>> step,
  int appliedMembers,
});

_Run _run({
  bool adopt = true,
  double voterDy = 150,
  double tallDy = 150,
  double? floorPx,
  int? reanchorMinBlocks,
  int shortCount = 3,
  StepResponse stepResponse = StepResponse.coherentShift,
}) {
  var applied = 0;
  final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
    merger: (existing, fresh, m) {
      if (m.stepResponseApplied == StepResponse.coherentShift) applied++;
      return existing.applyMerge(m);
    },
    stepResponse: stepResponse,
    coherentShiftAdoptAgreeing: adopt,
    coherentShiftFloorPx: floorPx,
    coherentShiftReanchorMinBlocks: reanchorMinBlocks,
    missedFrameRetention: 3,
  );
  final texts = _short.take(shortCount).toList();
  final seed = engine.stabilize([
    for (var i = 0; i < texts.length; i++)
      _block(texts[i], top: 500 + 100.0 * i),
    _block(_tall, top: 800, height: 60),
  ]);
  final step = engine.stabilize([
    for (var i = 0; i < texts.length; i++)
      _block(texts[i], top: 500 + voterDy + 100.0 * i),
    _block(_tall, top: 800 + tallDy, height: 60),
  ]);
  return (seed: seed, step: step, appliedMembers: applied);
}

void main() {
  group('StabilizationResult.coherentShift (2.5.0)', () {
    test('the seed capture (nothing to match) reports no event', () {
      final r = _run();
      expect(r.seed.coherentShift, isNull);
    });

    test(
        'quorum-decided, adoption ON: translation, 3 voters + 1 adopted, '
        'decidedBy quorum — and memberCount equals the merges that applied '
        'it', () {
      final r = _run(adopt: true);
      final e = r.step.coherentShift;
      expect(e, isNotNull);
      expect(e!.decidedBy, CoherentShiftSource.quorum);
      expect(e.translation.dy, closeTo(150, 0.5));
      expect(e.translation.dx, closeTo(0, 0.5));
      expect(e.memberCount, 4);
      expect(e.adoptedCount, 1, reason: 'the tall under-gate pair');
      expect(e.votedCount, 3);
      expect(r.appliedMembers, e.memberCount,
          reason: 'the event summarises merges that actually applied the '
              'plan — the per-block wire and the capture-level event must '
              'agree exactly');
    });

    test(
        'quorum-decided, adoption OFF (2.3.x numerics): 3 members, 0 '
        'adopted', () {
      final r = _run(adopt: false);
      final e = r.step.coherentShift!;
      expect(e.decidedBy, CoherentShiftSource.quorum);
      expect(e.memberCount, 3);
      expect(e.adoptedCount, 0);
      expect(r.appliedMembers, 3);
    });

    test(
        'adoption ON but no agreeing under-gate pair (tall block '
        'stationary): adoptedCount 0', () {
      final r = _run(adopt: true, tallDy: 0);
      final e = r.step.coherentShift!;
      expect(e.memberCount, 3);
      expect(e.adoptedCount, 0);
    });

    test(
        'a control capture (no movement) reports null, and no merge '
        'applied a shift', () {
      final r = _run(voterDy: 0, tallDy: 0);
      expect(r.step.coherentShift, isNull);
      expect(r.appliedMembers, 0);
    });

    test(
        'damp and snap never produce a capture-level event — the event is '
        'the COHERENT plan, snap stays per-block', () {
      expect(_run(stepResponse: StepResponse.damp).step.coherentShift, isNull);
      expect(_run(stepResponse: StepResponse.snap).step.coherentShift, isNull);
    });

    test(
        'floor-decided (#119): a lone 150 px mover below the quorum of 3, '
        'admitted by a 100 px coherentShiftFloorPx — decidedBy floor, 1 '
        'member', () {
      // +150 keeps the mover inside the primary match's reach (the adopt-
      // agreeing fixture's own floor geometry); a mover past that reach is
      // admitted as a NEW identity and can never be a plan member — the
      // 600 px starved-quorum shape the floor exists for is "one straggler
      // still matches", not "nobody matches".
      final r = _run(shortCount: 1, voterDy: 150, tallDy: 0, floorPx: 100);
      final e = r.step.coherentShift;
      expect(e, isNotNull);
      expect(e!.decidedBy, CoherentShiftSource.floor);
      expect(e.translation.dy, closeTo(150, 0.5));
      expect(e.memberCount, 1);
      expect(e.adoptedCount, 0,
          reason: 'the stationary tall pair disagrees with +150');
      expect(r.appliedMembers, 1);
    });

    test(
        'the same lone mover WITHOUT a floor falls through to damp — no '
        'event (the starved-quorum blind spot, contract U4)', () {
      final r = _run(shortCount: 1, voterDy: 150, tallDy: 0);
      expect(r.step.coherentShift, isNull);
      expect(r.appliedMembers, 0);
    });

    test(
        're-anchor-decided (#119 candidate 2): two movers below the '
        'quorum of 3, coherentShiftReanchorMinBlocks 2 — decidedBy '
        'reanchor, 2 members', () {
      final r =
          _run(shortCount: 2, voterDy: 150, tallDy: 0, reanchorMinBlocks: 2);
      final e = r.step.coherentShift;
      expect(e, isNotNull);
      expect(e!.decidedBy, CoherentShiftSource.reanchor);
      expect(e.memberCount, 2);
      expect(e.adoptedCount, 0);
      expect(r.appliedMembers, 2);
    });

    test(
        'with both fallbacks configured the floor answers first (the '
        'documented ordering) — decidedBy floor', () {
      final r = _run(
          shortCount: 1,
          voterDy: 150,
          tallDy: 0,
          floorPx: 100,
          reanchorMinBlocks: 1);
      expect(r.step.coherentShift!.decidedBy, CoherentShiftSource.floor);
    });
  });
}
