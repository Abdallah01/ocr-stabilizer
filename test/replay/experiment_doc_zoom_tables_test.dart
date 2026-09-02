// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #135 — the result tables of doc/replay/validation/2026-09-zoom/
// EXPERIMENT.md, pinned the way #128 / #136 pin the other corpora: every
// cell against a live replay of the committed streams through the
// shipping configuration (`transformReport`), at the document's own
// display precision. The margins table is pinned against the SAME
// per-capture points the per-stream table summarises, so the reading
// rule's stated margins cannot drift from the data under them.
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
const _variantConfigs = [
  's93-r2',
  's07-r1',
  's07-r2',
  's21-r1',
  's21-r2',
  's42-r1',
  's42-r2',
];
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

const _zoomHeader =
    '| stream | capture | scale | translation dx / dy | pairs | rejected | '
    'residual (px) | span (px) | merged / admitted |';
const _peakHeader =
    '| stream | peak scale | peak |scale - 1| | residual at peak (px) | pairs '
    'at peak | capture |';
const _marginHeader =
    '| residual under | pairs at least | largest control |scale - 1| | set by '
    '| control captures under both |';

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

/// (label, capture, |scale - 1|, residual, pairs) for every estimated
/// capture of every non-zoom stream — the margins table's population.
List<(String, int, double, double, int)> controlPoints(
    List<List<String>> peakRows) {
  final points = <(String, int, double, double, int)>[];
  for (final r in peakRows) {
    final rep = reportOf(controlBase(r[0]));
    for (final entry in (rep['transformByCapture'] as Map).entries) {
      final v = entry.value as Map?;
      if (v == null) continue;
      points.add((
        r[0],
        int.parse(entry.key as String),
        ((v['scale'] as num) - 1).abs().toDouble(),
        (v['residualPx'] as num).toDouble(),
        v['pairs'] as int,
      ));
    }
  }
  return points;
}

void main() {
  test(
      'the zoom corpus on disk is exactly the four streams the tables '
      'cite, and the peak table covers every non-zoom stream in the '
      'repository', () {
    final onDisk = Directory(_zoomDir)
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.jsonl'))
        .map((n) => n.substring(0, n.length - '.jsonl'.length))
        .toSet();
    expect(onDisk, _zoomStreams.toSet());
    final cited = tableRows(_doc, _peakHeader).map((r) => r[0]).toSet();
    final expected = {
      ...streamAlias.keys
          .map((k) => _variantStreams.contains(k) ? 's93-r1 / $k' : k),
      for (final c in _variantConfigs)
        for (final s in _variantStreams) '$c / $s',
    };
    expect(cited, expected,
        reason: 'a non-zoom stream missing from the peak table is a '
            'control the reading rule was never checked against');
  });

  test(
      'zoom streams: scale, translation, pairs, rejected, residual, span '
      'and the identity census per capture', () {
    final rows = tableRows(_doc, _zoomHeader);
    expect(rows, hasLength(_zoomStreams.length * 5));
    for (final r in rows) {
      final where = '${r[0]} cap ${r[1]}';
      expect(_zoomStreams, contains(r[0]), reason: where);
      final rep = reportOf('$_zoomDir/${r[0]}');
      final cap = int.parse(r[1]);
      final census = censusAt(rep, cap);
      expect(r[8], '${census['merged']} / ${census['admitted']}',
          reason: '$where: merged / admitted');
      final e = estimateAt(rep, cap);
      if (r[2] == '—') {
        expect(e, isNull, reason: '$where: doc says no estimate');
        expect(r.sublist(3, 8), everyElement('—'), reason: where);
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
    }
  });

  test(
      'every non-zoom stream: the peak |scale - 1| capture and its scale, '
      'residual and pairs', () {
    final rows = tableRows(_doc, _peakHeader);
    for (final r in rows) {
      final where = r[0];
      final s = reportOf(controlBase(r[0]))['summary'] as Map;
      if (r[1] == '—') {
        expect(s['peakScaleDeviation'], isNull, reason: where);
        continue;
      }
      expectAtDisplay(s['peakScale'], r[1], '$where peak scale');
      expectAtDisplay(s['peakScaleDeviation'], r[2], '$where peak dev');
      expectAtDisplay(s['residualAtPeakPx'], r[3], '$where residual');
      expect(s['pairsAtPeak'], int.parse(r[4]), reason: '$where pairs');
      expect(s['peakScaleDeviationCapture'], int.parse(r[5]),
          reason: '$where capture');
    }
  });

  test(
      'margins: for each residual cap and pair floor, the largest control '
      '|scale - 1| over every qualifying capture, who set it, and the '
      'population — from the same per-capture points', () {
    final points = controlPoints(tableRows(_doc, _peakHeader));
    final rows = tableRows(_doc, _marginHeader);
    expect(rows, isNotEmpty);
    for (final r in rows) {
      final where = 'residual ${r[0]} pairs ${r[1]}';
      final cap = double.parse(r[0].replaceAll(RegExp(r'[<> px]'), ''));
      final floor = int.parse(r[1].replaceAll(RegExp(r'[>= ]'), ''));
      final under = points.where((p) => p.$4 < cap && p.$5 >= floor).toList();
      expect(int.parse(r[4]), under.length, reason: '$where: population');
      if (under.isEmpty) {
        expect(r[2], '—', reason: where);
        continue;
      }
      final worst = under.reduce((a, b) => a.$3 >= b.$3 ? a : b);
      expectAtDisplay(worst.$3, r[2], '$where: largest deviation');
      expect(r[3], '${worst.$1} (cap ${worst.$2}, ${worst.$5} pairs)',
          reason: '$where: set by');
    }
  });
}
