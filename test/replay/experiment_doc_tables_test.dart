// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause
//
// #128 — the result tables of the validation EXPERIMENT.md documents are
// derived from the committed `.ab.json` reports, and two of their cells
// have already rotted silently through a regeneration (caught by reviewers,
// not by a test). This test parses every table whose header row is stable
// and checks each per-arm cell against the committed report — or, for the
// `--coherent-floor=390` arm the #119 section cites, against a live replay
// (`abReport(stream, coherentShiftFloorPx: 390)`, deterministic over the
// committed streams) — at the document's own display precision: a cell
// matches when |value − cell| ≤ half a unit in the cell's last shown
// decimal. Prose claims stay out of scope by design (the issue's rule).
//
// Scope, table by table (header rows quoted verbatim in the code below):
//   dynamic-reflow  "Control streams — no real step"       snap/coherent stepEvents
//   dynamic-reflow  "Step streams — real pushdown/pushup"  damp/snap/coherent lag triples,
//                                                          identity at move, stepEvents
//   dynamic-reflow  #119 "Control streams (10)"            merges damp/floor, stepEvents, max lag delta
//   dynamic-reflow  #119 "Step streams (7)"                damp/coherent/floor lag triples,
//                                                          floor stepEvents, identity ×3
//   mlkit-on-device "Result"                               displacement means, wellObserved pconf
//   tesseract-matrix "Result"                              displacement means, pconf mean/p50
//   paddleocr-matrix "Result"                              displacement means, pconf mean
// Tables whose cells come from anything other than an `.ab.json` arm (the
// per-capture matched/new counts, the pregroup unit-of-identity table, the
// `bk` bucket-policy emulation rows) are deliberately not parsed.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:test/test.dart';

import '../../tool/replay/src/ab_report.dart';
import '../../tool/replay/src/capture_stream.dart';

const _v = 'doc/replay/validation';
const _reflow = '$_v/2026-08-dynamic-reflow';

/// The short names the dynamic-reflow tables use → committed stream base.
const _alias = {
  'rewrap': '$_reflow/rewrap',
  'pushdown-300': '$_reflow/pushdown',
  'pushdown-050': '$_reflow/variants/pushdown-050',
  'pushdown-150': '$_reflow/variants/pushdown-150',
  'pushdown-600': '$_reflow/variants/pushdown-600',
  'pushup-300': '$_reflow/variants/pushup-300',
  'pushdown-300-early': '$_reflow/variants/pushdown-300-early',
  'pushdown-300-late': '$_reflow/variants/pushdown-300-late',
  'tess-stable-dwell': '$_v/2026-08-tesseract-matrix/stable-dwell',
  'tess-jitter-dwell': '$_v/2026-08-tesseract-matrix/ocr-jitter-dwell',
  'tess-scroll': '$_v/2026-08-tesseract-matrix/scroll',
  'paddle-stable-dwell': '$_v/2026-08-paddleocr-matrix/stable-dwell',
  'paddle-jitter-dwell': '$_v/2026-08-paddleocr-matrix/ocr-jitter-dwell',
  'paddle-scroll': '$_v/2026-08-paddleocr-matrix/scroll',
  'mlkit-dwell': '$_v/2026-08-mlkit-on-device/dwell',
  'mlkit-dwell-bk': '$_v/2026-08-mlkit-on-device/dwell-bk',
  'mlkit-scroll': '$_v/2026-08-mlkit-on-device/scroll',
};

/// The arm names the matrix tables use → report arm key.
const _armAlias = {
  'agreement': 'agreementWeighted',
  'legacy': 'legacy',
};

typedef Arm = Map<String, Object?>;
typedef Report = Map<String, Object?>;

final _committed = <String, Report>{};
final _floor = <String, Report>{};

Report committed(String base) => _committed.putIfAbsent(
    base,
    () => jsonDecode(File('$base.ab.json').readAsStringSync())
        as Map<String, Object?>);

/// The `--coherent-floor=390` replay the #119 section reports — not
/// committed (the doc's own Reproduce block), so replayed live.
Report floorReport(String base) => _floor.putIfAbsent(
    base,
    () => abReport(
          CaptureStream.parse(File('$base.jsonl').readAsLinesSync()),
          coherentShiftFloorPx: 390,
        ));

Arm arm(Report r, String name) {
  final a = r[name];
  if (a is! Map) fail('arm $name missing from report (keys: ${r.keys})');
  return a.cast<String, Object?>();
}

int stepEvents(Arm a) => (a['stepEventsByCapture'] as Map)
    .values
    .fold<int>(0, (sum, v) => sum + (v as int));

num? lagAt(Arm a, int capture) =>
    (a['meanTopLagByCapture'] as Map)['$capture'] as num?;

num? identityAt(Arm a, int capture) =>
    (a['identityByCapture'] as Map)['$capture'] as num?;

Map<String, Object?>? bucket(Arm a, String name) =>
    ((a['displacementByObsN'] as Map)[name] as Map?)?.cast<String, Object?>();

Arm pconf(Arm a) => (a['wellObservedPconf'] as Map).cast<String, Object?>();

/// Parses the markdown table whose header row (trimmed) equals [header]
/// in [doc]: the rows after the `|---|` separator up to the first non-table
/// line, cells trimmed with `**bold**` markers removed, the `tally` row
/// dropped. Fails loudly when the header is not found — a renamed column
/// must show up as a red test, not as a silently skipped table.
List<List<String>> tableRows(String doc, String header) {
  final lines = File(doc).readAsLinesSync();
  final start = lines.indexWhere((l) => l.trim() == header);
  if (start < 0) fail('$doc: table header not found:\n  $header');
  final rows = <List<String>>[];
  for (var i = start + 2; i < lines.length && lines[i].startsWith('|'); i++) {
    final cells = lines[i]
        .split('|')
        .map((c) => c.replaceAll('**', '').trim())
        .toList();
    final inner = cells.sublist(1, cells.length - 1);
    if (inner.first == 'tally') continue;
    rows.add(inner);
  }
  if (rows.isEmpty) fail('$doc: no data rows under:\n  $header');
  return rows;
}

final _number = RegExp(r'^-?\d+(?:\.(\d+))?$');

/// [value] rounds to [cell] at the cell's own precision.
void expectAtDisplay(Object? value, String cell, String where) {
  final m = _number.firstMatch(cell);
  if (m == null) fail('$where: "$cell" is not a plain number');
  if (value is! num) fail('$where: doc says $cell but the report has $value');
  final decimals = m.group(1)?.length ?? 0;
  final tolerance = 0.5 * math.pow(10, -decimals) + 1e-9;
  expect((value.toDouble() - double.parse(cell)).abs() <= tolerance, isTrue,
      reason: '$where: doc says $cell, report has $value '
          '(display precision: $decimals decimals)');
}

/// A "move / +3 / +5" lag triple ("n/a" = undefined for that capture).
void expectLagTriple(Arm a, int moveCap, String cell, String where) {
  final parts = cell.split(' / ');
  expect(parts, hasLength(3), reason: '$where: "$cell" is not a triple');
  for (final (i, offset) in const [0, 3, 5].indexed) {
    final value = lagAt(a, moveCap + offset);
    if (parts[i] == 'n/a') {
      expect(value, isNull,
          reason: '$where: doc says n/a at capture ${moveCap + offset} but '
              'the report has $value');
    } else {
      expectAtDisplay(value, parts[i], '$where[+$offset]');
    }
  }
}

/// A step-arm cell: either "identical — 0 events" (the arm fell through to
/// damp on every merge — zero events AND damp's own lag values) or a lag
/// triple followed by "(N)" step events.
void expectStepArmCell(Arm a, Arm damp, int moveCap, String cell, String where) {
  if (cell.startsWith('identical')) {
    expect(stepEvents(a), 0, reason: '$where: "identical" claims 0 events');
    for (final offset in const [0, 3, 5]) {
      expect(lagAt(a, moveCap + offset), lagAt(damp, moveCap + offset),
          reason: '$where: "identical" claims damp\'s lag at +$offset');
    }
    return;
  }
  final m = RegExp(r'^(.*) \((\d+)\)$').firstMatch(cell);
  if (m == null) fail('$where: "$cell" is neither identical nor "triple (N)"');
  expectLagTriple(a, moveCap, m.group(1)!, where);
  expect(stepEvents(a), int.parse(m.group(2)!),
      reason: '$where: step events');
}

int moveCapOf(String cell, String where) {
  final m = RegExp(r'cap (\d+)').firstMatch(cell);
  if (m == null) fail('$where: no "@ cap N" in "$cell"');
  return int.parse(m.group(1)!);
}

String streamOf(String short) {
  final base = _alias[short];
  if (base == null) fail('no committed stream for table row "$short"');
  return base;
}

void main() {
  const reflowDoc = '$_reflow/EXPERIMENT.md';

  group('dynamic-reflow — step response A/B (#116)', () {
    test('control streams: snap / coherent stepEvents', () {
      final rows = tableRows(reflowDoc,
          '| stream | kind | snap stepEvents | snap | coherent stepEvents | coherent |');
      expect(rows, hasLength(10));
      for (final r in rows) {
        final c = committed(streamOf(r[0]));
        expect(stepEvents(arm(c, 'agreementSnap')), int.parse(r[2]),
            reason: '${r[0]}: snap stepEvents');
        expect(stepEvents(arm(c, 'agreementCoherent')), int.parse(r[4]),
            reason: '${r[0]}: coherent stepEvents');
      }
    });

    test('step streams: damp / snap / coherent lag triples, identity at '
        'move, step events', () {
      final rows = tableRows(
          reflowDoc,
          '| stream | gap / reflow-at | damp lag: move / +3 / +5 | identity at '
          'move | snap lag: move / +3 / +5 (stepEvents) | snap | coherent lag: '
          'move / +3 / +5 (stepEvents) | coherent |');
      expect(rows, hasLength(7));
      for (final r in rows) {
        final name = r[0];
        final c = committed(streamOf(name));
        final move = moveCapOf(r[1], name);
        final damp = arm(c, 'agreementWeighted');
        expectLagTriple(damp, move, r[2], '$name damp');
        expectAtDisplay(identityAt(damp, move), r[3], '$name identity');
        expectStepArmCell(
            arm(c, 'agreementSnap'), damp, move, r[4], '$name snap');
        expectStepArmCell(
            arm(c, 'agreementCoherent'), damp, move, r[6], '$name coherent');
      }
    });
  });

  group('dynamic-reflow — closing the large-slab blind spot (#119, '
      'floor 390 replayed live)', () {
    test('control streams: merges damp/floor, stepEvents, max lag delta', () {
      final rows = tableRows(
          reflowDoc,
          '| stream | merges (damp / floor) | coherent stepEvents | floor '
          'stepEvents | max lag delta vs coherent | verdict |');
      expect(rows, hasLength(10));
      for (final r in rows) {
        final name = r[0];
        final base = streamOf(name);
        final c = committed(base);
        final f = arm(floorReport(base), 'agreementCoherentFloor');
        final damp = arm(c, 'agreementWeighted');
        final coherent = arm(c, 'agreementCoherent');
        final merges = r[1].split(' / ');
        expect(damp['mergeCount'], int.parse(merges[0]),
            reason: '$name: damp merges');
        expect(f['mergeCount'], int.parse(merges[1]),
            reason: '$name: floor merges');
        expect(stepEvents(coherent), int.parse(r[2]),
            reason: '$name: coherent stepEvents');
        expect(stepEvents(f), int.parse(r[3]), reason: '$name: floor stepEvents');
        var maxDelta = 0.0;
        for (final cap in (coherent['meanTopLagByCapture'] as Map).keys) {
          final a = lagAt(coherent, int.parse(cap as String));
          final b = lagAt(f, int.parse(cap));
          if (a == null || b == null) continue;
          maxDelta = math.max(maxDelta, (a - b).abs().toDouble());
        }
        expectAtDisplay(
            maxDelta, r[4].replaceAll(' px', ''), '$name: max lag delta');
      }
    });

    test('step streams: damp / coherent / floor lag triples, floor '
        'stepEvents, identity at move ×3', () {
      final rows = tableRows(
          reflowDoc,
          '| stream | move cap | damp lag move/+3/+5 | coherent (today) | '
          '**floor 390** | floor stepEvents | identity at move (damp / '
          'coherent / floor) | step-rule verdict |');
      expect(rows, hasLength(7));
      for (final r in rows) {
        final name = r[0];
        final base = streamOf(name);
        final c = committed(base);
        final move = int.parse(r[1]);
        final damp = arm(c, 'agreementWeighted');
        final coherent = arm(c, 'agreementCoherent');
        final f = arm(floorReport(base), 'agreementCoherentFloor');
        expectLagTriple(damp, move, r[2], '$name damp');
        expectLagTriple(coherent, move, r[3], '$name coherent');
        expectLagTriple(f, move, r[4], '$name floor');
        expect(stepEvents(f), int.parse(r[5]), reason: '$name: floor stepEvents');
        final ids = r[6].split(' / ');
        expect(ids, hasLength(3));
        expectAtDisplay(identityAt(damp, move), ids[0], '$name identity damp');
        expectAtDisplay(
            identityAt(coherent, move), ids[1], '$name identity coherent');
        expectAtDisplay(identityAt(f, move), ids[2], '$name identity floor');
      }
    });
  });

  /// A displacement-bucket cell: a mean at display precision, or "—" for a
  /// bucket the stream never reached.
  void expectBucketCell(Arm a, String name, String cell, String where) {
    final b = bucket(a, name);
    if (cell == '—') {
      expect(b == null || b['count'] == 0, isTrue,
          reason: '$where: doc says — for $name but the report has $b');
      return;
    }
    if (b == null) fail('$where: doc has $cell for $name, report has no bucket');
    expectAtDisplay(b['mean'], cell, '$where $name mean');
  }

  /// "1.0 (saturated)" = every well-observed pconf pinned at 1.0.
  bool isSaturatedCell(String cell) => cell.startsWith('1.0 (saturated)');

  group('mlkit-on-device — Result (#108)', () {
    test('displacement means and well-observed pconf per arm', () {
      final rows = tableRows('$_v/2026-08-mlkit-on-device/EXPERIMENT.md',
          '| stream | arm | disp n1-2 | disp n3-5 | disp n6-10 | wellObs pconf |');
      expect(rows, hasLength(4));
      for (final r in rows) {
        final base = '$_v/2026-08-mlkit-on-device/${r[0]}';
        final a = arm(committed(base), _armAlias[r[1]]!);
        final where = '${r[0]}/${r[1]}';
        expectBucketCell(a, 'n1-2', r[2], where);
        expectBucketCell(a, 'n3-5', r[3], where);
        expectBucketCell(a, 'n6-10', r[4], where);
        final p = r[5];
        if (isSaturatedCell(p)) {
          expect(a['wellObservedPconfSaturated'], 1.0, reason: '$where pconf');
        } else if (p.startsWith('—')) {
          expect(pconf(a)['count'], 0,
              reason: '$where: doc says no well-observed chain');
        } else {
          expectAtDisplay(pconf(a)['mean'], p, '$where pconf mean');
        }
      }
    });
  });

  group('tesseract-matrix — Result', () {
    test('displacement means and pconf mean/p50 per arm', () {
      final rows = tableRows('$_v/2026-08-tesseract-matrix/EXPERIMENT.md',
          '| scenario | arm | disp n3-5 | disp n6-10 | disp n11+ | pconf mean/p50 |');
      expect(rows, hasLength(6));
      for (final r in rows) {
        final base = '$_v/2026-08-tesseract-matrix/${r[0]}';
        final a = arm(committed(base), _armAlias[r[1]]!);
        final where = 'tess ${r[0]}/${r[1]}';
        expectBucketCell(a, 'n3-5', r[2], where);
        expectBucketCell(a, 'n6-10', r[3], where);
        expectBucketCell(a, 'n11+', r[4], where);
        if (isSaturatedCell(r[5])) {
          expect(a['wellObservedPconfSaturated'], 1.0, reason: '$where pconf');
        } else {
          final mp = r[5].split(' / ');
          expect(mp, hasLength(2), reason: '$where: "${r[5]}" is not mean / p50');
          expectAtDisplay(pconf(a)['mean'], mp[0], '$where pconf mean');
          expectAtDisplay(pconf(a)['p50'], mp[1], '$where pconf p50');
        }
      }
    });
  });

  group('paddleocr-matrix — Result', () {
    test('displacement means and pconf mean per arm', () {
      final rows = tableRows('$_v/2026-08-paddleocr-matrix/EXPERIMENT.md',
          '| scenario | arm | disp n3-5 | disp n6-10 | disp n11+ | pconf mean |');
      expect(rows, hasLength(6));
      for (final r in rows) {
        final scenario = r[0] == 'ocr-jitter' ? 'ocr-jitter-dwell' : r[0];
        final base = '$_v/2026-08-paddleocr-matrix/$scenario';
        final a = arm(committed(base), _armAlias[r[1]]!);
        final where = 'paddle ${r[0]}/${r[1]}';
        expectBucketCell(a, 'n3-5', r[2], where);
        expectBucketCell(a, 'n6-10', r[3], where);
        expectBucketCell(a, 'n11+', r[4], where);
        if (isSaturatedCell(r[5])) {
          expect(a['wellObservedPconfSaturated'], 1.0, reason: '$where pconf');
        } else {
          expectAtDisplay(pconf(a)['mean'], r[5], '$where pconf mean');
        }
      }
    });
  });
}
