// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #136 — the "Variance across seeds and repetitions" tables of the
// dynamic-reflow EXPERIMENT.md, pinned the way #128 pins the rest of the
// document: every cell against a live replay of the committed variant
// streams (no `.ab.json` is committed for them — the streams are the
// evidence and the replay is deterministic) at the document's own
// display precision. The floor bounds are pinned as the boundary they
// claim: the floor arm fires at the bound and NOT one pixel above it,
// so a bound copied from a stale run, or a stream regenerated under the
// table, goes red. The summary table is pinned against the per-row
// tables it aggregates, so the two cannot disagree silently.
import 'dart:io';

import 'package:test/test.dart';

import 'experiment_doc_support.dart';

const _doc = '$reflowDir/EXPERIMENT.md';
const _variants = '$reflowDir/variants';
const _section = '## Variance across seeds and repetitions (#136, 2026-09-02)';
const _published = 's93-r1';

const _controls = [
  'rewrap',
  'tess-stable-dwell',
  'tess-jitter-dwell',
  'tess-scroll',
];
const _steps = [
  'pushdown-050',
  'pushdown-150',
  'pushdown-300',
  'pushdown-600',
  'pushup-300',
  'pushdown-300-early',
  'pushdown-300-late',
];
const _slab = 'pushdown-600';
const _shippedFloor = 390.0;
// The bisection range the report script searched (variance_report.py).
const _floorLo = 200;
const _floorHi = 700;

const _configsHeader =
    '| config | seed | perturb-seed | what varies against the published corpus |';
const _controlHeader =
    '| config | control | coherent stepEvents | floor 390 stepEvents | adopt '
    'stepEvents | largest firing floor (px) |';
const _stepHeader =
    '| config | stream | move cap | damp lag move/+3/+5 | coherent lag '
    'move/+3/+5 (stepEvents) | adopt lag move/+3/+5 (stepEvents) | floor 390 '
    'lag move/+3/+5 (stepEvents) | step rule: coherent / adopt / floor |';
const _windowHeader =
    '| config | control ceiling (px) | slab bound (px) | floor window | 390 '
    'inside | pushdown-600 lag at move: coherent → floor 390 |';
const _summaryHeader = '| quantity | min | median | max | n |';

/// A configuration's stream: the published corpus for [_published], the
/// committed variant directory otherwise.
String baseOf(String config, String stream) =>
    config == _published ? streamOf(stream) : '$_variants/$config/$stream';

final _full = <String, Report>{};

/// The `--coherent-floor=390 --coherent-adopt` replay: damp, coherent,
/// floor and adopt arms in one report.
Report full(String base) => _full.putIfAbsent(
    base,
    () => abReport(streamAt(base),
        coherentShiftFloorPx: _shippedFloor, coherentShiftAdoptAgreeing: true));

bool fires(String base, int floorPx) =>
    stepEvents(arm(floorReportAt(base, floorPx.toDouble()),
        'agreementCoherentFloor')) >
    0;

/// The #116 step rule: the arm's lag is at most half of damp's at the
/// move, at +3 and at +5 — over the captures the stream still has.
bool passesStepRule(Arm a, Arm damp, int move) {
  for (final o in const [0, 3, 5]) {
    final d = lagAt(damp, move + o);
    if (d == null) continue;
    final v = lagAt(a, move + o);
    if (v == null || v > d / 2) return false;
  }
  return true;
}

/// A "largest firing floor" / "control ceiling" / "slab bound" cell:
/// an integer floor, `< 200` (never fires in range), `>= 700` (still
/// fires at the top of the range) or `none`. Returns the integer, or
/// null for the two "outside the range" forms after asserting them.
int? checkFloorBound(String base, String cell, String where) {
  if (cell == '< $_floorLo' || cell == 'none') {
    expect(fires(base, _floorLo), isFalse,
        reason: '$where: doc says the floor arm never fires from $_floorLo up');
    return null;
  }
  if (cell == '>= $_floorHi') {
    expect(fires(base, _floorHi), isTrue,
        reason: '$where: doc says the floor arm still fires at $_floorHi');
    return _floorHi;
  }
  final f = int.tryParse(cell);
  if (f == null) fail('$where: "$cell" is not a floor bound');
  expect(fires(base, f), isTrue, reason: '$where: must fire at $f');
  expect(fires(base, f + 1), isFalse,
      reason: '$where: must NOT fire at ${f + 1} — the bound is the '
          'largest firing floor');
  return f;
}

List<List<String>> rows(String header) =>
    tableRows(_doc, header, after: _section);

num median(List<num> xs) {
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

void main() {
  late final List<String> configs;

  setUpAll(() {
    configs = rows(_configsHeader).map((r) => r[0]).toList();
  });

  test('configurations: the published corpus first, unique labels, every '
      'variant directory holds exactly the eleven streams, and every '
      'variant directory on disk is a cited configuration', () {
    expect(configs.first, _published);
    expect(configs.toSet(), hasLength(configs.length));
    final expected = {..._controls, ..._steps};
    for (final c in configs.skip(1)) {
      final dir = Directory('$_variants/$c');
      expect(dir.existsSync(), isTrue, reason: '$c: variant directory');
      final found = dir
          .listSync()
          .whereType<File>()
          .map((f) => f.uri.pathSegments.last)
          .where((n) => n.endsWith('.jsonl'))
          .map((n) => n.substring(0, n.length - '.jsonl'.length))
          .toSet();
      expect(found, expected, reason: '$c: streams on disk');
    }
    final onDisk = Directory(_variants)
        .listSync()
        .whereType<Directory>()
        .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
        .toSet();
    expect(onDisk, configs.skip(1).toSet(),
        reason: 'a variant directory no table cites, or a cited '
            'configuration with no directory');
  });

  test('controls: stepEvents per arm and the largest firing floor, per '
      'configuration and control', () {
    final table = rows(_controlHeader);
    expect(table, hasLength(configs.length * _controls.length));
    for (final r in table) {
      final where = '${r[0]}/${r[1]}';
      expect(_controls, contains(r[1]), reason: '$where: not a control');
      final base = baseOf(r[0], r[1]);
      final rep = full(base);
      expect(stepEvents(arm(rep, 'agreementCoherent')), int.parse(r[2]),
          reason: '$where: coherent stepEvents');
      expect(stepEvents(arm(rep, 'agreementCoherentFloor')), int.parse(r[3]),
          reason: '$where: floor 390 stepEvents');
      expect(stepEvents(arm(rep, 'agreementCoherentAdopt')), int.parse(r[4]),
          reason: '$where: adopt stepEvents');
      checkFloorBound(base, r[5], '$where largest firing floor');
    }
  });

  test('steps: damp / coherent / adopt / floor lag triples, stepEvents and '
      'the step-rule verdicts, per configuration and stream', () {
    final table = rows(_stepHeader);
    expect(table, hasLength(configs.length * _steps.length));
    for (final r in table) {
      final where = '${r[0]}/${r[1]}';
      expect(_steps, contains(r[1]), reason: '$where: not a step stream');
      final move = int.parse(r[2]);
      final byName = switch (r[1]) {
        'pushdown-300-early' => 3,
        'pushdown-300-late' => 10,
        _ => 7,
      };
      expect(move, byName, reason: '$where: move capture per the stream name');
      final rep = full(baseOf(r[0], r[1]));
      final damp = arm(rep, 'agreementWeighted');
      expectLagTriple(damp, move, r[3], '$where damp');
      final arms = [
        arm(rep, 'agreementCoherent'),
        arm(rep, 'agreementCoherentAdopt'),
        arm(rep, 'agreementCoherentFloor'),
      ];
      const names = ['coherent', 'adopt', 'floor'];
      for (var i = 0; i < 3; i++) {
        expectStepArmCell(arms[i], damp, move, r[4 + i], '$where ${names[i]}');
      }
      final verdicts = r[7].split(' / ');
      expect(verdicts, hasLength(3), reason: '$where: "${r[7]}"');
      for (var i = 0; i < 3; i++) {
        expect(verdicts[i], passesStepRule(arms[i], damp, move) ? 'PASS' : 'FAIL',
            reason: '$where ${names[i]}: step rule');
      }
    }
  });

  test('floor window: the control ceiling is the largest control bound, '
      'the slab bound brackets pushdown-600\'s mover, the window and the '
      '"390 inside" verdict follow, and the slab lags restate the arms', () {
    final table = rows(_windowHeader);
    expect(table, hasLength(configs.length));
    final control = rows(_controlHeader);
    for (final r in table) {
      final c = r[0];
      final where = '$c window';
      // Control ceiling: the max over the config's control bounds — which
      // the control table already pinned as boundaries.
      final bounds = control
          .where((x) => x[0] == c)
          .map((x) => int.tryParse(x[5]) ?? (x[5] == '>= $_floorHi' ? _floorHi : null))
          .whereType<int>()
          .toList();
      final ceilingCell = bounds.isEmpty ? '< $_floorLo' : '${bounds.reduce((a, b) => a > b ? a : b)}';
      expect(r[1], ceilingCell, reason: '$where: control ceiling');
      final ceiling = int.tryParse(ceilingCell);
      final slab = baseOf(c, _slab);
      final bound = checkFloorBound(slab, r[2], '$where slab bound');
      final windowCell = bound == null || (ceiling != null && ceiling >= bound)
          ? 'empty'
          : '($ceilingCell, $bound]';
      expect(r[3], windowCell, reason: '$where: floor window');
      final inside = bound != null &&
          _shippedFloor <= bound &&
          (ceiling == null || ceiling < _shippedFloor);
      expect(r[4], inside ? 'yes' : 'no', reason: '$where: 390 inside');
      final lags = r[5].split(' → ');
      expect(lags, hasLength(2), reason: '$where: "${r[5]}"');
      final rep = full(slab);
      expectAtDisplay(lagAt(arm(rep, 'agreementCoherent'), 7), lags[0],
          '$where: coherent lag at move');
      expectAtDisplay(lagAt(arm(rep, 'agreementCoherentFloor'), 7), lags[1],
          '$where: floor lag at move');
    }
  });

  test('summary: min / median / max / n of every quantity, aggregated from '
      'the per-row tables above', () {
    final control = rows(_controlHeader);
    final step = rows(_stepHeader);
    final window = rows(_windowHeader);
    int? bound(String cell) =>
        int.tryParse(cell) ?? (cell == '>= $_floorHi' ? _floorHi : null);
    final ceilings = <num>[];
    final slabs = <num>[];
    final widths = <num>[];
    for (final w in window) {
      final l = bound(w[1]);
      final u = bound(w[2]);
      if (l != null) ceilings.add(l);
      if (u != null) slabs.add(u);
      if (l != null && u != null && l < u) widths.add(u - l);
    }
    List<num> passingOf(int col) => [
          for (final c in configs)
            step
                .where((r) => r[0] == c)
                .where((r) => r[7].split(' / ')[col] == 'PASS')
                .length
        ];
    final falseEvents = [
      for (final c in configs)
        control
            .where((r) => r[0] == c)
            .fold<int>(0, (s, r) => s + int.parse(r[3]))
    ];
    final expected = <String, List<num>>{
      'control ceiling (px)': ceilings,
      'slab bound (px)': slabs,
      'window width (px)': widths,
      'steps passing: coherent (of 7)': passingOf(0),
      'steps passing: adopt (of 7)': passingOf(1),
      'steps passing: floor 390 (of 7)': passingOf(2),
      'control false events at floor 390 (4 controls)': falseEvents,
    };
    final table = rows(_summaryHeader);
    expect(table.map((r) => r[0]).toSet(), expected.keys.toSet(),
        reason: 'the summary names exactly these quantities');
    for (final r in table) {
      final xs = expected[r[0]]!;
      expect(int.parse(r[4]), xs.length, reason: '${r[0]}: n');
      if (xs.isEmpty) continue;
      expectAtDisplay(xs.reduce((a, b) => a < b ? a : b), r[1], '${r[0]} min');
      expectAtDisplay(median(xs), r[2], '${r[0]} median');
      expectAtDisplay(xs.reduce((a, b) => a > b ? a : b), r[3], '${r[0]} max');
    }
  });
}
