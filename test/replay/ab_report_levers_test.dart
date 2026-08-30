// PR #129 review C2: the replay tool's lever plumbing had no test — both
// #119 arms could have been computed with the levers OFF and every test
// stayed green. This pins that `abReport` hands each lever to its own
// arm's engine, on the #119 large-slab shape (a lone +190 mover among
// five; see group (l) of test/stabilization_engine_step_response_test.dart):
// the floor arm and the re-anchor arm each log ONE step event on the move
// capture, and the baseline coherentShift arm logs none. The third lever
// (`--coherent-adopt`, #119 item 2) is pinned on a quorum-FIRING shape
// instead — three 30 px movers plus one 200 px pair making the same step:
// 3 step events in the baseline arm, 4 in the adopt arm.
import 'package:test/test.dart';

import '../../tool/replay/src/ab_report.dart';
import '../../tool/replay/src/capture_stream.dart';

void main() {
  // An explicit 400 px bucket (`bk`): the viewport formula's default cell
  // is smaller than the +190 px move below, which would leave the mover
  // spatially unmatched — admitted as a new block, never a mover — and
  // the test would be blind to the levers for the wrong reason.
  const meta =
      '{"t": "meta", "v": 1, "ts": 0, "vp": [360, 587], "bk": [400, 400]}';
  const tops = [50.0, 600.0, 1100.0, 1600.0, 2100.0];
  String block(int i, double top) =>
      '{"rect": [0, $top, 200, ${top + 30}], '
      '"otext": "paragraph number $i text", "pconf": 0.9, "tconf": 0.9, '
      '"obsN": 1, "prov": false, "provN": 0}';
  String obs(int cap, {double firstDy = 0}) =>
      '{"t": "obs", "ts": $cap, "cap": $cap, "raw": 5, "blocks": ['
      '${[
        for (var i = 0; i < 5; i++) block(i, tops[i] + (i == 0 ? firstDy : 0))
      ].join(', ')}]}';
  CaptureStream stream() =>
      CaptureStream.parse([meta, obs(1), obs(2, firstDy: 190)]);

  Map<String, Object?> arm(Map<String, Object?> report, String name) =>
      report[name] as Map<String, Object?>;
  int stepEventsAt(Map<String, Object?> a, int cap) =>
      (a['stepEventsByCapture'] as Map<String, Object?>)['$cap'] as int;

  test('without the levers no floor / re-anchor arm is reported, and the '
      'baseline coherentShift arm sees no step on a lone mover', () {
    final report = abReport(stream());
    expect(report.containsKey('agreementCoherentFloor'), isFalse);
    expect(report.containsKey('agreementCoherentReanchor'), isFalse);
    expect(stepEventsAt(arm(report, 'agreementCoherent'), 2), 0,
        reason: 'one mover among five never clears the quorum');
  });

  test('coherentShiftFloorPx reaches the floor arm: one step event on the '
      'move capture, none in the baseline arm', () {
    final report = abReport(stream(), coherentShiftFloorPx: 150);
    expect((report['input'] as Map<String, Object?>)['coherentShiftFloorPx'],
        150);
    expect(stepEventsAt(arm(report, 'agreementCoherentFloor'), 2), 1,
        reason: 'the lever must actually reach the arm\'s engine');
    expect(stepEventsAt(arm(report, 'agreementCoherentFloor'), 1), 0);
    expect(stepEventsAt(arm(report, 'agreementCoherent'), 2), 0,
        reason: 'the baseline arm is untouched by the lever');
  });

  // #119 item 2: a fixture where the quorum DOES fire — three 30 px movers
  // (gate 90 px) stepping +150 — plus one 200 px block (gate 600 px) making
  // the same step: under its gate, so it damps in the baseline arm and is
  // adopted in the adopt arm. Step events on the move capture: 3 vs 4.
  String tallBlock(double top) =>
      '{"rect": [0, $top, 200, ${top + 200}], "otext": "tall paragraph text", '
      '"pconf": 0.9, "tconf": 0.9, "obsN": 1, "prov": false, "provN": 0}';
  String quorumObs(int cap, {double dy = 0}) =>
      '{"t": "obs", "ts": $cap, "cap": $cap, "raw": 4, "blocks": ['
      '${[
        for (var i = 0; i < 3; i++) block(i, tops[i] + dy),
        tallBlock(1600 + dy),
      ].join(', ')}]}';
  CaptureStream quorumStream() =>
      CaptureStream.parse([meta, quorumObs(1), quorumObs(2, dy: 150)]);

  test('coherentShiftAdoptAgreeing reaches the adopt arm: the agreeing '
      'under-gate pair is one more step event on the move capture', () {
    final report = abReport(quorumStream(), coherentShiftAdoptAgreeing: true);
    expect(
        (report['input'] as Map<String, Object?>)['coherentShiftAdoptAgreeing'],
        isTrue);
    expect(stepEventsAt(arm(report, 'agreementCoherent'), 2), 3,
        reason: 'CONTROL — the quorum fires for the three movers; the tall '
            'pair sits under its own gate');
    expect(stepEventsAt(arm(report, 'agreementCoherentAdopt'), 2), 4,
        reason: 'the lever must actually reach the arm engine: the tall '
            'pair follows the decided shift');
    expect(abReport(stream()).containsKey('agreementCoherentAdopt'), isFalse,
        reason: 'without the lever no adopt arm is reported');
  });

  test('coherentShiftReanchorMinBlocks reaches the re-anchor arm', () {
    final report = abReport(stream(), coherentShiftReanchorMinBlocks: 1);
    expect(
        (report['input'] as Map<String, Object?>)[
            'coherentShiftReanchorMinBlocks'],
        1);
    expect(stepEventsAt(arm(report, 'agreementCoherentReanchor'), 2), 1,
        reason: 'the lever must actually reach the arm\'s engine');
    expect(stepEventsAt(arm(report, 'agreementCoherent'), 2), 0);
  });
}
