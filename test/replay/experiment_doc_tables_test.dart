// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause
//
// #128 — the result tables of the validation EXPERIMENT.md documents are
// derived from the committed `.ab.json` reports, and two of their cells
// have already rotted silently through a regeneration (caught by reviewers,
// not by a test). This test parses the result tables listed below (by
// exact header row) and checks each per-arm cell against the committed
// report — or, for the #119 `--coherent-floor` / `--coherent-reanchor`
// sweeps, against a live replay (`abReport(stream, coherentShiftFloorPx:
// N)` / `coherentShiftReanchorMinBlocks: N`, deterministic over the
// committed streams) — at the document's own display precision: the
// report value rendered to the cell's decimals must equal the cell. Prose
// claims stay out of scope by design (the issue's rule).
//
// Scope, table by table (header rows quoted verbatim in the code below):
//   dynamic-reflow  "Control streams — no real step"       snap/coherent stepEvents
//   dynamic-reflow  "Step streams — real pushdown/pushup"  damp/snap/coherent lag triples,
//                                                          identity at move, stepEvents
//   dynamic-reflow  #119 "Control streams (10)"            merges damp/floor, stepEvents,
//                                                          max lag delta, the tally row
//   dynamic-reflow  #119 "Step streams (7)"                damp/coherent/floor lag triples,
//                                                          floor stepEvents, identity ×3
//   dynamic-reflow  #119 "Ship rule"                       its three results (restated
//                                                          floor-390 figures)
//   dynamic-reflow  #119 "Floor sensitivity"               control stepEvents + pushdown-600
//                                                          lag at the move, per floor
//   dynamic-reflow  #119 candidate-2 re-anchor sweep       control stepEvents + pushdown-600
//                                                          lag triple, per count
//   mlkit-on-device "Result"                               displacement means, wellObserved pconf
//   tesseract-matrix "Result"                              displacement means, pconf mean/p50
//   paddleocr-matrix "Result"                              displacement means, pconf mean
// The #116 and #119 control + step tables are also checked to cover the
// whole committed corpus, and every table's row keys must be unique — a
// duplicated row plus a dropped stream cannot hide behind a row count.
// NOT parsed, deliberately — cells no `.ab.json` arm or replay carries as
// a number: the per-capture matched/new counts, the pregroup
// unit-of-identity table, the `bk` bucket-policy emulation rows, the
// "largest moved pair" geometry table (per-pair distances the report does
// not emit), the re-anchor sweep's "combined tally" and "streams firing"
// breakdown, and the floor sweep's verdict prose.

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
final _sweeps = <String, Report>{};

Report committed(String base) => _committed.putIfAbsent(
    base,
    () => jsonDecode(File('$base.ab.json').readAsStringSync())
        as Map<String, Object?>);

CaptureStream _stream(String base) =>
    CaptureStream.parse(File('$base.jsonl').readAsLinesSync());

/// The `--coherent-floor=N` replay the #119 section reports — not
/// committed (the doc's own Reproduce block), so replayed live.
Report floorReportAt(String base, double floorPx) => _sweeps.putIfAbsent(
    '$base@floor=$floorPx',
    () => abReport(_stream(base), coherentShiftFloorPx: floorPx));

/// The shipped floor (390) — the value the #119 result tables cite.
Report floorReport(String base) => floorReportAt(base, 390);

/// The `--coherent-reanchor=N` replay of #119's candidate-2 sweep.
Report reanchorReportAt(String base, int minBlocks) => _sweeps.putIfAbsent(
    '$base@reanchor=$minBlocks',
    () => abReport(_stream(base), coherentShiftReanchorMinBlocks: minBlocks));

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

/// Every row of the markdown table whose header row (trimmed) equals
/// [header] in [doc] — searched from the heading [after] when given, so a
/// header used twice resolves to the section meant — the rows after the
/// `|---|` separator up to the first non-table line, cells trimmed with
/// `**bold**` markers removed. Fails loudly when the header is not found:
/// a renamed column must show up as a red test, not as a silently skipped
/// table.
List<List<String>> _rawRows(String doc, String header, {String? after}) {
  final lines = File(doc).readAsLinesSync();
  var from = 0;
  if (after != null) {
    from = lines.indexWhere((l) => l.trim() == after);
    if (from < 0) fail('$doc: anchor heading not found:\n  $after');
  }
  final start = lines.indexWhere((l) => l.trim() == header, from);
  if (start < 0) fail('$doc: table header not found:\n  $header');
  final rows = <List<String>>[];
  for (var i = start + 2; i < lines.length && lines[i].startsWith('|'); i++) {
    final cells = lines[i]
        .split('|')
        .map((c) => c.replaceAll('**', '').trim())
        .toList();
    rows.add(cells.sublist(1, cells.length - 1));
  }
  return rows;
}

/// The data rows of the table under [header]: [_rawRows] minus the `tally`
/// row (an aggregate — see [tallyRow]), with unique row keys (the first two
/// cells: stream, or stream + arm for the matrix tables). A duplicated row
/// standing in for a dropped one would keep a row COUNT green while the
/// dropped stream's claims left coverage — so it fails here instead.
List<List<String>> tableRows(String doc, String header, {String? after}) {
  final rows = _rawRows(doc, header, after: after)
      .where((r) => r.first != 'tally')
      .toList();
  if (rows.isEmpty) fail('$doc: no data rows under:\n  $header');
  final keys = rows.map((r) => r.take(2).join(' | ')).toList();
  if (keys.toSet().length != keys.length) {
    fail('$doc: duplicate row keys under:\n  $header\n  $keys');
  }
  return rows;
}

/// The `tally` row of the table under [header], or null when it has none.
/// Its cells are aggregates of a column; the caller that knows which
/// column checks them.
List<String>? tallyRow(String doc, String header, {String? after}) {
  for (final r in _rawRows(doc, header, after: after)) {
    if (r.first == 'tally') return r;
  }
  return null;
}

final _number = RegExp(r'^-?\d+(?:\.(\d+))?$');

/// [value] renders, at the cell's own precision, to exactly [cell].
void expectAtDisplay(Object? value, String cell, String where) {
  final m = _number.firstMatch(cell);
  if (m == null) fail('$where: "$cell" is not a plain number');
  if (value is! num) fail('$where: doc says $cell but the report has $value');
  final decimals = m.group(1)?.length ?? 0;
  // Render the way the document does (fixed decimals) and demand the same
  // string. A ±half-unit band would accept BOTH neighbouring renderings of
  // a value sitting on a rounding boundary (0.045 as 0.04 or as 0.05), so
  // a cell rewritten to the wrong neighbour would stay green.
  final v = value.toDouble();
  final rendered = (v == 0 ? 0.0 : v).toStringAsFixed(decimals);
  expect(rendered, double.parse(cell).toStringAsFixed(decimals),
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

  group('dynamic-reflow — #119 corpus coverage, ship rule and sweeps '
      '(replayed live)', () {
    const controlHeader =
        '| stream | merges (damp / floor) | coherent stepEvents | floor '
        'stepEvents | max lag delta vs coherent | verdict |';
    const stepHeader =
        '| stream | move cap | damp lag move/+3/+5 | coherent (today) | '
        '**floor 390** | floor stepEvents | identity at move (damp / '
        'coherent / floor) | step-rule verdict |';

    List<String> controls() => tableRows(reflowDoc, controlHeader)
        .map((r) => streamOf(r[0]))
        .toList();

    /// pushdown-600's move capture, read from the step table rather than
    /// hard-coded, so the sweep tables cannot disagree with it silently.
    int slabMoveCap() => int.parse(tableRows(reflowDoc, stepHeader)
        .firstWhere((r) => r[0] == 'pushdown-600')[1]);

    int controlEventsAtFloor(double floorPx) => controls().fold<int>(
        0,
        (sum, base) =>
            sum +
            stepEvents(arm(floorReportAt(base, floorPx), 'agreementCoherentFloor')));

    int eventsIn(String cell, String where) {
      final m = RegExp(r'(\d+) events').firstMatch(cell);
      if (m == null) fail('$where: no "N events" in "$cell"');
      return int.parse(m.group(1)!);
    }

    String pxIn(String cell, String where) {
      final m = RegExp(r'(-?\d+(?:\.\d+)?) px').firstMatch(cell);
      if (m == null) fail('$where: no "N px" in "$cell"');
      return m.group(1)!;
    }

    test('the alias map names exactly the committed corpus — every .jsonl '
        'with an .ab.json sibling, the .grouped pregroup reports excluded', () {
      final found = Directory(_v)
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.replaceAll('\\', '/'))
          .where((p) => p.endsWith('.ab.json') && !p.contains('.grouped'))
          .map((p) => p.substring(0, p.length - '.ab.json'.length))
          .toSet();
      expect(found, _alias.values.toSet(),
          reason: 'a committed report with no alias would never be cited '
              'by any table this test checks — or an alias points nowhere');
    });

    test('the #116 control + step tables cover the whole corpus', () {
      final control = tableRows(reflowDoc,
          '| stream | kind | snap stepEvents | snap | coherent stepEvents | coherent |');
      final step = tableRows(
          reflowDoc,
          '| stream | gap / reflow-at | damp lag: move / +3 / +5 | identity at '
          'move | snap lag: move / +3 / +5 (stepEvents) | snap | coherent lag: '
          'move / +3 / +5 (stepEvents) | coherent |');
      expect([...control, ...step].map((r) => streamOf(r[0])).toSet(),
          _alias.values.toSet(),
          reason: 'a stream dropped from both tables leaves its #116 '
              'claims unchecked');
    });

    test('the #119 control + step tables cover the whole corpus, and the '
        'control tally is the sum of its floor-stepEvents column', () {
      final control = tableRows(reflowDoc, controlHeader);
      final step = tableRows(reflowDoc, stepHeader);
      expect([...control, ...step].map((r) => streamOf(r[0])).toSet(),
          _alias.values.toSet(),
          reason: 'a stream dropped from both tables leaves its #119 '
              'claims unchecked');
      final tally = tallyRow(reflowDoc, controlHeader);
      if (tally == null) fail('the #119 control table lost its tally row');
      expect(eventsIn(tally[3], 'control tally'), controlEventsAtFloor(390),
          reason: 'tally: floor stepEvents across the controls');
      expect(tally[5], '${control.length}/${control.length}',
          reason: 'tally: verdict count');
    });

    test('floor sensitivity: control stepEvents in total and pushdown-600\'s '
        'lag at the move, replayed at each floor of the sweep', () {
      final rows =
          tableRows(reflowDoc, '| floor | controls | pushdown-600 | ships |');
      expect(rows, hasLength(4));
      final slab = streamOf('pushdown-600');
      final move = slabMoveCap();
      for (final r in rows) {
        final floorPx = double.parse(r[0].replaceAll(' px', ''));
        final where = 'floor ${r[0]}';
        expect(controlEventsAtFloor(floorPx), eventsIn(r[1], where),
            reason: '$where: total control stepEvents');
        expectAtDisplay(
            lagAt(arm(floorReportAt(slab, floorPx), 'agreementCoherentFloor'),
                move),
            pxIn(r[2], where),
            '$where: pushdown-600 lag at move');
      }
    });

    test('ship rule: its three results restate the floor-390 figures', () {
      final rows = tableRows(reflowDoc, '| criterion | result |',
          after: "#### Ship rule (#119's own, distinct from the A/B step rule)");
      expect(rows, hasLength(3));
      // Row 1: zero step events across the controls.
      final zero = RegExp(r'PASS — (\d+)$').firstMatch(rows[0][1]);
      if (zero == null) fail('ship rule row 1: no "PASS — N" in "${rows[0][1]}"');
      expect(controlEventsAtFloor(390), int.parse(zero.group(1)!),
          reason: 'ship rule: control step events');
      // Row 2: the slab's lag at the move.
      final slab = streamOf('pushdown-600');
      expectAtDisplay(
          lagAt(arm(floorReportAt(slab, 390), 'agreementCoherentFloor'),
              slabMoveCap()),
          pxIn(rows[1][1], 'ship rule row 2'),
          'ship rule: pushdown-600 lag at move');
      // Row 3: the worst regression — the most by which the floor arm's
      // lag exceeds today's coherent arm at any capture of any stream.
      var worst = 0.0;
      for (final base in _alias.values) {
        final coherent = arm(committed(base), 'agreementCoherent');
        final f = arm(floorReportAt(base, 390), 'agreementCoherentFloor');
        for (final cap in (coherent['meanTopLagByCapture'] as Map).keys) {
          final a = lagAt(coherent, int.parse(cap as String));
          final b = lagAt(f, int.parse(cap));
          if (a == null || b == null) continue;
          worst = math.max(worst, (b - a).toDouble());
        }
      }
      expectAtDisplay(worst, pxIn(rows[2][1], 'ship rule row 3'),
          'ship rule: worst regression');
    });

    test('re-anchor sweep (candidate 2): control stepEvents in total and '
        'pushdown-600\'s lag triple, replayed at each count', () {
      final rows = tableRows(
          reflowDoc,
          '| count | control stepEvents (streams firing) | pushdown-600 lag '
          'move/+3/+5 | combined tally | verdict |');
      expect(rows, hasLength(3));
      final slab = streamOf('pushdown-600');
      final move = slabMoveCap();
      for (final r in rows) {
        final count = int.parse(r[0]);
        final where = 'reanchor count $count';
        final total = controls().fold<int>(
            0,
            (sum, base) =>
                sum +
                stepEvents(arm(reanchorReportAt(base, count),
                    'agreementCoherentReanchor')));
        final claimed = RegExp(r'^(\d+)').firstMatch(r[1]);
        if (claimed == null) fail('$where: no leading count in "${r[1]}"');
        expect(total, int.parse(claimed.group(1)!),
            reason: '$where: total control stepEvents');
        expectLagTriple(
            arm(reanchorReportAt(slab, count), 'agreementCoherentReanchor'),
            move,
            r[2],
            '$where pushdown-600');
      }
    });
  });
}
