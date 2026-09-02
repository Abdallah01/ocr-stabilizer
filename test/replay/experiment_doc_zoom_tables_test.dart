// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #135 — the result tables of doc/replay/validation/2026-09-zoom/
// EXPERIMENT.md, pinned the way #128 / #136 pin the other corpora: every
// cell against a live replay of the committed streams through the
// shipping configuration (`transformReport`), at the document's own
// display precision. Each table's ROW SET is pinned too (which streams,
// which captures, which rule bounds), so a dropped or swapped row goes
// red, not only a wrong cell. The margins table is pinned against the
// SAME per-capture points the per-stream table summarises, so the
// reading rule's stated margins cannot drift from the data under them.
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/replay/src/transform_report.dart';
import 'experiment_doc_support.dart';

const _zoomDir = '$validationRoot/2026-09-zoom';
const _doc = '$_zoomDir/EXPERIMENT.md';
const _zoomStreams = [
  'zoom-125',
  'zoom-125-rewrap',
  'zoom-080',
  'zoom-080-rewrap',
];
const _zoomCaptures = [5, 6, 7, 8, 9];
const _variantStreams = [
  'pushdown-050',
  'pushdown-150',
  'pushdown-300',
  'pushdown-600',
  'pushup-300',
  'pushdown-300-early',
  'pushdown-300-late',
  'rewrap',
  'tess-stable-dwell',
  'tess-jitter-dwell',
  'tess-scroll',
];
// The margins table's axes, in the order zoom_report.py prints them; the
// spellings are the script's cells.
const _residualCaps = ['< 5 px', '< 10 px', '< 20 px', '< 40 px', 'any'];
const _pairFloors = ['>= 3', '>= 6'];
const _gapCaps = ['<= 0.5', 'any'];

const _zoomHeader =
    '| stream | capture | scale | translation dx / dy | pairs | rejected | '
    'residual (px) | span (px) | gap share | merged / admitted |';
const _peakHeader =
    '| stream | peak scale | peak deviation | residual at peak (px) | pairs '
    'at peak | gap share at peak | capture |';
const _marginHeader =
    '| residual under | pairs at least | gap share at most | largest control '
    'deviation | set by | control captures under all three |';

/// The #136 configurations on disk: every `sNN-rN` directory under
/// variants/ — the same enumeration zoom_report.py uses, so a new
/// configuration must land in the peak table.
List<String> variantConfigsOnDisk() => Directory('$reflowDir/variants')
    .listSync()
    .whereType<Directory>()
    .map((d) => d.uri.pathSegments.where((s) => s.isNotEmpty).last)
    .where((n) => RegExp(r'^s\d+-r\d+$').hasMatch(n))
    .toList()
  ..sort();

/// The stream a peak-table row names: `s93-r1 / <name>` is the published
/// corpus (via the alias map), `<config> / <name>` a #136 variant, and a
/// bare name one of the published cross-engine controls.
String controlBase(String label) {
  final parts = label.split(' / ');
  if (parts.length == 2) {
    return parts[0] == 's93-r1'
        ? streamOf(parts[1])
        : '$reflowDir/variants/${parts[0]}/${parts[1]}';
  }
  return streamOf(label);
}

final _reports = <String, Map<String, Object?>>{};
Map<String, Object?> reportOf(String base) =>
    _reports.putIfAbsent(base, () => transformReport(streamAt(base)));

Map<String, Object?>? estimateAt(Map<String, Object?> report, int cap) =>
    (report['transformByCapture'] as Map)['$cap'] as Map<String, Object?>?;

Map<String, Object?> censusAt(Map<String, Object?> report, int cap) =>
    (report['identityByCapture'] as Map)['$cap'] as Map<String, Object?>;

/// One estimated control capture: label, capture, |scale - 1|, residual,
/// pairs, gap share — the margins table's population.
typedef ControlPoint = ({
  String label,
  int cap,
  double dev,
  double residual,
  int pairs,
  double gap
});

List<ControlPoint> controlPoints(List<List<String>> peakRows) {
  final points = <ControlPoint>[];
  for (final r in peakRows) {
    final rep = reportOf(controlBase(r[0]));
    for (final entry in (rep['transformByCapture'] as Map).entries) {
      final v = entry.value as Map?;
      if (v == null) continue;
      points.add((
        label: r[0],
        cap: int.parse(entry.key as String),
        dev: ((v['scale'] as num) - 1).abs().toDouble(),
        residual: (v['residualPx'] as num).toDouble(),
        pairs: v['pairs'] as int,
        gap: (v['gapShare'] as num).toDouble(),
      ));
    }
  }
  return points;
}

/// `< 10 px` -> 10; `any` -> no bound.
double residualCapOf(String cell) => cell == 'any'
    ? double.infinity
    : double.parse(cell.replaceAll(RegExp('[<> px]'), ''));

/// `<= 0.5` -> 0.5; `any` -> no bound.
double gapCapOf(String cell) =>
    cell == 'any' ? double.infinity : double.parse(cell.replaceAll('<= ', ''));

void main() {
  test(
      'the zoom corpus on disk is exactly the four streams the tables '
      'cite, and the peak table covers every non-zoom stream in the '
      'repository — the published aliases plus every variant configuration '
      'directory on disk', () {
    final onDisk = Directory(_zoomDir)
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.jsonl'))
        .map((n) => n.substring(0, n.length - '.jsonl'.length))
        .toSet();
    expect(onDisk, _zoomStreams.toSet());
    final configs = variantConfigsOnDisk();
    expect(configs, isNotEmpty, reason: 'the #136 corpus is committed');
    expect(configs, isNot(contains('s93-r1')),
        reason: 's93-r1 is the published corpus, not a directory');
    final cited = tableRows(_doc, _peakHeader).map((r) => r[0]).toSet();
    final expected = {
      ...streamAlias.keys
          .map((k) => _variantStreams.contains(k) ? 's93-r1 / $k' : k),
      for (final c in configs)
        for (final s in _variantStreams) '$c / $s',
    };
    expect(cited, expected,
        reason: 'a non-zoom stream missing from the peak table is a '
            'control the reading rule was never checked against');
  });

  test(
      'zoom streams: every (stream, capture) row around the event, with '
      'scale, translation, pairs, rejected, residual, span, gap share and '
      'the identity census', () {
    final rows = tableRows(_doc, _zoomHeader);
    expect(rows.map((r) => '${r[0]} @ ${r[1]}').toList(), [
      for (final s in _zoomStreams)
        for (final c in _zoomCaptures) '$s @ $c',
    ]);
    for (final r in rows) {
      final where = '${r[0]} cap ${r[1]}';
      final rep = reportOf('$_zoomDir/${r[0]}');
      final cap = int.parse(r[1]);
      final census = censusAt(rep, cap);
      expect(r[9], '${census['merged']} / ${census['admitted']}',
          reason: '$where: merged / admitted');
      final e = estimateAt(rep, cap);
      if (r[2] == '—') {
        expect(e, isNull, reason: '$where: doc says no estimate');
        expect(r.sublist(3, 9), everyElement('—'), reason: where);
        continue;
      }
      if (e == null) fail('$where: doc has an estimate, the replay has none');
      expectAtDisplay(e['scale'], r[2], '$where scale');
      final t = r[3].split(' / ');
      expect(t, hasLength(2), reason: '$where: "${r[3]}"');
      expectAtDisplay(e['dx'], t[0], '$where dx');
      expectAtDisplay(e['dy'], t[1], '$where dy');
      expect(e['pairs'], int.parse(r[4]), reason: '$where pairs');
      expect(e['rejected'], int.parse(r[5]), reason: '$where rejected');
      expectAtDisplay(e['residualPx'], r[6], '$where residual');
      expectAtDisplay(e['spanPx'], r[7], '$where span');
      expectAtDisplay(e['gapShare'], r[8], '$where gap share');
    }
  });

  test(
      'every non-zoom stream: the peak-deviation capture and its scale, '
      'residual, pairs and gap share', () {
    final rows = tableRows(_doc, _peakHeader);
    for (final r in rows) {
      final where = r[0];
      final s = reportOf(controlBase(r[0]))['summary'] as Map;
      if (r[1] == '—') {
        expect(s['peakScaleDeviation'], isNull, reason: where);
        expect(r.sublist(2, 7), everyElement('—'), reason: where);
        continue;
      }
      expectAtDisplay(s['peakScale'], r[1], '$where peak scale');
      expectAtDisplay(s['peakScaleDeviation'], r[2], '$where peak dev');
      expectAtDisplay(s['residualAtPeakPx'], r[3], '$where residual');
      expect(s['pairsAtPeak'], int.parse(r[4]), reason: '$where pairs');
      expectAtDisplay(s['gapShareAtPeak'], r[5], '$where gap share');
      expect(s['peakScaleDeviationCapture'], int.parse(r[6]),
          reason: '$where capture');
    }
  });

  test(
      'margins: every (residual cap, pair floor, gap cap) row the rule '
      'needs, each with the largest control deviation over every '
      'qualifying capture, who set it, and the population — from the same '
      'per-capture points as the peak table', () {
    final points = controlPoints(tableRows(_doc, _peakHeader));
    final rows = tableRows(_doc, _marginHeader, keyCells: 3);
    expect(rows.map((r) => '${r[0]} | ${r[1]} | ${r[2]}').toList(), [
      for (final res in _residualCaps)
        for (final p in _pairFloors)
          for (final g in _gapCaps) '$res | $p | $g',
    ]);
    for (final r in rows) {
      final where = 'residual ${r[0]} pairs ${r[1]} gap ${r[2]}';
      final cap = residualCapOf(r[0]);
      final floor = int.parse(r[1].replaceAll(RegExp('[>= ]'), ''));
      final gapCap = gapCapOf(r[2]);
      final under = points
          .where((p) => p.residual < cap && p.pairs >= floor && p.gap <= gapCap)
          .toList();
      expect(int.parse(r[5]), under.length, reason: '$where: population');
      if (under.isEmpty) {
        expect(r[3], '—', reason: where);
        expect(r[4], '—', reason: where);
        continue;
      }
      final worst = under.reduce((a, b) => a.dev >= b.dev ? a : b);
      expectAtDisplay(worst.dev, r[3], '$where: largest deviation');
      expect(r[4], '${worst.label} (cap ${worst.cap}, ${worst.pairs} pairs)',
          reason: '$where: set by');
    }
  });
}
