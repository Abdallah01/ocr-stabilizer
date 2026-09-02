// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// Pins the dynamic-reflow validation entry (#93,
// doc/replay/validation/2026-08-dynamic-reflow/): the corpus construction
// claim (every line below the slab moved by exactly the stated offset) and
// the regime each scenario lands in when replayed through the engine —
// push-down keeps identity but the position model damps the step (#116),
// re-wrap resets most identities. The regime pins are deliberate: a change
// that fixes #116 turns the push-down pin red ON PURPOSE, and the entry's
// tables must be regenerated with it.
import 'dart:io';
import 'dart:math' show max, min;

import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

import '../../tool/replay/src/capture_stream.dart';
import '../../tool/replay/src/pregroup.dart';
import '../../tool/replay/src/replay_session.dart';

const _dir = 'doc/replay/validation/2026-08-dynamic-reflow';

/// The slab's page y in the after-frames and its height (gen_corpus.py).
const _slabTop = 1692.0;
const _slabPx = 300.0;

/// First capture rendered after the reflow event (gen_corpus.py REFLOW_AT).
const _reflowCapture = 7;

/// Tesseract's line boxes vary by a few px between reads of the same
/// pixels (glyph extents, the subpixel perturbation); the page moved by
/// exactly the slab height, the boxes report it within this band.
const _boxTolerance = 8.0;

CaptureStream _load(String name) =>
    CaptureStream.parse(File('$_dir/$name.jsonl').readAsLinesSync());

void main() {
  group('dynamic-reflow corpus (#93)', () {
    test('both streams parse: 12 captures, a viewport, nothing skipped', () {
      for (final name in ['pushdown', 'rewrap']) {
        final s = _load(name);
        expect(s.batches, hasLength(12), reason: name);
        expect(s.skippedLines, 0, reason: name);
        expect(s.batches.first.captureId, 1, reason: name);
        expect(s.viewport, isNotNull,
            reason: '$name: the meta record carries vp for updateViewport');
      }
    });

    test(
        'pushdown construction: every line below the slab sits exactly '
        '300 px lower than its capture-6 twin, lines above are untouched',
        () {
      final s = _load('pushdown');
      final before = {
        for (final b in s.batches[_reflowCapture - 2].blocks)
          b.originalText: b.absoluteRect.raw.top,
      };
      var shiftedPairs = 0, untouchedPairs = 0;
      for (final b in s.batches[_reflowCapture - 1].blocks) {
        final old = before[b.originalText];
        if (old == null) continue; // OCR read the line differently once
        final top = b.absoluteRect.raw.top;
        if (top >= _slabTop) {
          expect(top - old, closeTo(_slabPx, _boxTolerance),
              reason: b.originalText);
          shiftedPairs++;
        } else {
          expect(top - old, closeTo(0, _boxTolerance), reason: b.originalText);
          untouchedPairs++;
        }
      }
      expect(shiftedPairs, greaterThanOrEqualTo(8),
          reason: 'the claim needs enough identical reads to be checkable');
      expect(untouchedPairs, greaterThanOrEqualTo(8));
    });

    test(
        'pushdown regime: identity mostly retained on the move, yet no merge '
        'moves a tracked position by more than a fraction of the step (#116)',
        () {
      final r = replay(_load('pushdown'),
          model: PositionMergeModel.agreementWeighted);
      final onMove = r.merges
          .where((m) => m.captureId == _reflowCapture && !m.nestedFragment)
          .toList();
      expect(onMove.length, greaterThanOrEqualTo(15),
          reason: 'measured 20 matched identities on the reflow frame');
      final maxDisplacement =
          onMove.map((m) => m.displacement).reduce(max);
      expect(maxDisplacement, lessThan(_slabPx / 3),
          reason: 'the 300 px step is damped as jitter — the regime #116 '
              'tracks; a fix that snaps turns this red on purpose');
    });

    test(
        'rewrap regime: the swap frame resets most identities and the new '
        'chains track from the next capture', () {
      final r =
          replay(_load('rewrap'), model: PositionMergeModel.agreementWeighted);
      int mergesAt(int cap) => r.merges
          .where((m) => m.captureId == cap && !m.nestedFragment)
          .length;
      expect(mergesAt(_reflowCapture), lessThanOrEqualTo(10),
          reason: 'measured 7: only prefix-similar lines survive the swap');
      expect(mergesAt(_reflowCapture - 1), greaterThanOrEqualTo(25),
          reason: 'measured 28 before the swap');
      expect(mergesAt(_reflowCapture + 1), greaterThanOrEqualTo(25),
          reason: 'measured 29: the new chains track immediately');
    });
  });

  group('unit of identity: lines vs pre-grouped paragraphs (#101)', () {
    // The same captures replayed under both unit choices: as the lines OCR
    // emitted (the engine's unit) and pre-grouped into three-block /
    // 200-rune paragraphs, the way a consumer that groups BEFORE tracking
    // would feed them. Captures 2-6 are static (nothing has moved yet), so
    // the share of units the engine re-finds there is pure identity
    // retention — the number the entry's addendum tabulates. Every merge
    // counts, nested-fragment confirmations included: the fragment found
    // its block, which is the identity question (the other tests drop them
    // only because their displacement is zero by construction).
    List<double> retention(CaptureStream s, {required bool afterReflow}) {
      final r = replay(s, model: PositionMergeModel.agreementWeighted);
      final caps = afterReflow
          ? [for (var c = _reflowCapture + 1; c <= 12; c++) c]
          : [for (var c = 2; c < _reflowCapture; c++) c];
      return [
        for (final cap in caps)
          r.merges.where((m) => m.captureId == cap).length /
              s.batches[cap - 1].blocks.length,
      ];
    }

    CaptureStream grouped(String name) => CaptureStream.parse(
        pregroupJsonl(File('$_dir/$name.jsonl').readAsLinesSync()));

    test('lines: every static capture re-finds at least nine in ten units',
        () {
      final kept = retention(_load('pushdown'), afterReflow: false);
      expect(kept.reduce(min), greaterThanOrEqualTo(0.9),
          reason: 'measured 28-29 of 30 on each of captures 2-6: one line '
              'read differently is one identity lost, nothing else');
    });

    test(
        'pre-grouped paragraphs: a static capture loses a quarter or more — '
        'one differently-read line re-chunks the rest of its paragraph', () {
      final s = grouped('pushdown');
      expect(s.batches, hasLength(12));
      expect(s.skippedLines, 0);
      expect(s.batches.first.blocks.length,
          lessThan(_load('pushdown').batches.first.blocks.length),
          reason: 'grouping folded lines into fewer, larger units');
      final kept = retention(s, afterReflow: false);
      expect(kept.reduce(min), lessThanOrEqualTo(0.75),
          reason: 'measured 7 of 11 on capture 5 and 10 of 14 on capture 6: '
              'the grouper re-chunked a paragraph around one misread line, '
              'so the neighbours changed text and rect too — grouping '
              'imported its own instability');
    });

    test('rewrap, static captures after the swap: lines keep at least 85 in '
        '100; paragraphs drop to 65 in 100 or less (the same re-chunking, '
        'on the new text)', () {
      final lines = retention(_load('rewrap'), afterReflow: true);
      expect(lines.reduce(min), greaterThanOrEqualTo(0.85),
          reason: 'measured 29, 28, 28, 27, 26 of 30 (31 on capture 10)');
      final paragraphs = retention(grouped('rewrap'), afterReflow: true);
      expect(paragraphs.reduce(min), lessThanOrEqualTo(0.65),
          reason: 'measured 11, 11, 11, 6, 7 of 11: three clean captures, '
              'then one misread line re-chunks and 5 of 11 units vanish');
    });
  });
}
