// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// Shared by the EXPERIMENT.md table pins (#128's
// `experiment_doc_tables_test.dart` and #136's
// `experiment_doc_variance_tables_test.dart`): the committed-corpus
// alias map, the cached committed / live replays, the markdown table
// reader and the display-precision cell assertions. Moved here
// verbatim from the #128 test (only the private names became public);
// the assertions' semantics are documented on each function.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/replay/src/ab_report.dart';
import '../../tool/replay/src/capture_stream.dart';

export '../../tool/replay/src/ab_report.dart' show abReport;
export '../../tool/replay/src/capture_stream.dart' show CaptureStream;

/// The committed validation corpora, relative to the package root.
const validationRoot = 'doc/replay/validation';

/// The dynamic-reflow corpus (#93 / #116 / #119 / #136).
const reflowDir = '$validationRoot/2026-08-dynamic-reflow';

/// The short names the dynamic-reflow tables use → committed stream base.
const streamAlias = {
  'rewrap': '$reflowDir/rewrap',
  'pushdown-300': '$reflowDir/pushdown',
  'pushdown-050': '$reflowDir/variants/pushdown-050',
  'pushdown-150': '$reflowDir/variants/pushdown-150',
  'pushdown-600': '$reflowDir/variants/pushdown-600',
  'pushup-300': '$reflowDir/variants/pushup-300',
  'pushdown-300-early': '$reflowDir/variants/pushdown-300-early',
  'pushdown-300-late': '$reflowDir/variants/pushdown-300-late',
  'tess-stable-dwell': '$validationRoot/2026-08-tesseract-matrix/stable-dwell',
  'tess-jitter-dwell': '$validationRoot/2026-08-tesseract-matrix/ocr-jitter-dwell',
  'tess-scroll': '$validationRoot/2026-08-tesseract-matrix/scroll',
  'paddle-stable-dwell': '$validationRoot/2026-08-paddleocr-matrix/stable-dwell',
  'paddle-jitter-dwell': '$validationRoot/2026-08-paddleocr-matrix/ocr-jitter-dwell',
  'paddle-scroll': '$validationRoot/2026-08-paddleocr-matrix/scroll',
  'mlkit-dwell': '$validationRoot/2026-08-mlkit-on-device/dwell',
  'mlkit-dwell-bk': '$validationRoot/2026-08-mlkit-on-device/dwell-bk',
  'mlkit-scroll': '$validationRoot/2026-08-mlkit-on-device/scroll',
};

/// The arm names the matrix tables use → report arm key.
const armAlias = {
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

/// The committed capture stream at `<base>.jsonl`.
CaptureStream streamAt(String base) =>
    CaptureStream.parse(File('$base.jsonl').readAsLinesSync());

/// The `--coherent-floor=N` replay the #119 section reports — not
/// committed (the doc's own Reproduce block), so replayed live.
Report floorReportAt(String base, double floorPx) => _sweeps.putIfAbsent(
    '$base@floor=$floorPx',
    () => abReport(streamAt(base), coherentShiftFloorPx: floorPx));

/// The shipped floor (390) — the value the #119 result tables cite.
Report floorReport(String base) => floorReportAt(base, 390);

/// The `--coherent-reanchor=N` replay of #119's candidate-2 sweep.
Report reanchorReportAt(String base, int minBlocks) => _sweeps.putIfAbsent(
    '$base@reanchor=$minBlocks',
    () => abReport(streamAt(base), coherentShiftReanchorMinBlocks: minBlocks));

/// The `--coherent-adopt` replay of #119's candidate-3 row (item 2).
Report adoptReport(String base) => _sweeps.putIfAbsent('$base@adopt',
    () => abReport(streamAt(base), coherentShiftAdoptAgreeing: true));

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
  final base = streamAlias[short];
  if (base == null) fail('no committed stream for table row "$short"');
  return base;
}
