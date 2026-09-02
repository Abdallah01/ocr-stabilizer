// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #128 — the result tables of the validation EXPERIMENT.md documents are
// derived from the committed `.ab.json` reports, and two of their cells
// have already rotted silently through a regeneration (caught by reviewers,
// not by a test). This test parses the result tables listed below (by
// exact header row) and checks each per-arm cell against the committed
// report — or, for the #119 `--coherent-floor` / `--coherent-reanchor` /
// `--coherent-adopt` sweeps, against a live replay (`abReport(stream,
// coherentShiftFloorPx: N)` / `coherentShiftReanchorMinBlocks: N` /
// `coherentShiftAdoptAgreeing: true`, deterministic over the committed
// streams) — at the document's own display precision: the
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
//   dynamic-reflow  #119 candidate-3 adopt row             pushdown-150 coherent/adopt lag
//                                                          triples + events, identity +2/+5,
//                                                          merges; the other 16 streams identical
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

import 'experiment_doc_support.dart';

void main() {
  const reflowDoc = '$reflowDir/EXPERIMENT.md';

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
      final rows = tableRows('$validationRoot/2026-08-mlkit-on-device/EXPERIMENT.md',
          '| stream | arm | disp n1-2 | disp n3-5 | disp n6-10 | wellObs pconf |');
      expect(rows, hasLength(4));
      for (final r in rows) {
        final base = '$validationRoot/2026-08-mlkit-on-device/${r[0]}';
        final a = arm(committed(base), armAlias[r[1]]!);
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
      final rows = tableRows('$validationRoot/2026-08-tesseract-matrix/EXPERIMENT.md',
          '| scenario | arm | disp n3-5 | disp n6-10 | disp n11+ | pconf mean/p50 |');
      expect(rows, hasLength(6));
      for (final r in rows) {
        final base = '$validationRoot/2026-08-tesseract-matrix/${r[0]}';
        final a = arm(committed(base), armAlias[r[1]]!);
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
      final rows = tableRows('$validationRoot/2026-08-paddleocr-matrix/EXPERIMENT.md',
          '| scenario | arm | disp n3-5 | disp n6-10 | disp n11+ | pconf mean |');
      expect(rows, hasLength(6));
      for (final r in rows) {
        final scenario = r[0] == 'ocr-jitter' ? 'ocr-jitter-dwell' : r[0];
        final base = '$validationRoot/2026-08-paddleocr-matrix/$scenario';
        final a = arm(committed(base), armAlias[r[1]]!);
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
      final found = Directory(validationRoot)
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.replaceAll('\\', '/'))
          .where((p) => p.endsWith('.ab.json') && !p.contains('.grouped'))
          .map((p) => p.substring(0, p.length - '.ab.json'.length))
          .toSet();
      expect(found, streamAlias.values.toSet(),
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
          streamAlias.values.toSet(),
          reason: 'a stream dropped from both tables leaves its #116 '
              'claims unchecked');
    });

    test('the #119 control + step tables cover the whole corpus, and the '
        'control tally is the sum of its floor-stepEvents column', () {
      final control = tableRows(reflowDoc, controlHeader);
      final step = tableRows(reflowDoc, stepHeader);
      expect([...control, ...step].map((r) => streamOf(r[0])).toSet(),
          streamAlias.values.toSet(),
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
      for (final base in streamAlias.values) {
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

    test('adopt row (candidate 3, #119 item 2): pushdown-150 replayed with '
        'coherentShiftAdoptAgreeing; every other stream byte-identical', () {
      final rows = tableRows(
          reflowDoc,
          '| stream | move cap | coherent (today) lag move/+3/+5 (stepEvents) '
          '| adopt lag move/+3/+5 (stepEvents) | identity +2/+5 coherent '
          '| identity +2/+5 adopt | merges coherent / adopt |');
      expect(rows, hasLength(2));
      final r = rows[0];
      expect(r[0], 'pushdown-150');
      final base = streamOf(r[0]);
      final move = int.parse(r[1]);
      final rep = adoptReport(base);
      final coherent = arm(rep, 'agreementCoherent');
      final adopt = arm(rep, 'agreementCoherentAdopt');
      final damp = arm(rep, 'agreementWeighted');
      expectStepArmCell(coherent, damp, move, r[2], 'adopt row: coherent');
      expectStepArmCell(adopt, damp, move, r[3], 'adopt row: adopt');
      for (final (col, a) in [(4, coherent), (5, adopt)]) {
        final parts = r[col].split(' / ');
        expect(parts, hasLength(2), reason: 'adopt row col $col: "${r[col]}"');
        expectAtDisplay(
            identityAt(a, move + 2), parts[0], 'adopt row col $col: +2');
        expectAtDisplay(
            identityAt(a, move + 5), parts[1], 'adopt row col $col: +5');
      }
      final merges = r[6].split(' / ');
      expect(merges, hasLength(2));
      expect(coherent['mergeCount'], int.parse(merges[0]),
          reason: 'adopt row: coherent merges');
      expect(adopt['mergeCount'], int.parse(merges[1]),
          reason: 'adopt row: adopt merges');
      // Row 2: the lever is a no-op on every other committed stream.
      expect(rows[1][0], startsWith('all other 16'));
      final others = streamAlias.values.where((b) => b != base).toSet();
      expect(others, hasLength(16));
      for (final other in others) {
        final o = adoptReport(other);
        expect(jsonEncode(arm(o, 'agreementCoherentAdopt')),
            jsonEncode(arm(o, 'agreementCoherent')),
            reason: '$other: the lever must be a no-op where no group forms '
                'or every moved pair already votes');
      }
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
