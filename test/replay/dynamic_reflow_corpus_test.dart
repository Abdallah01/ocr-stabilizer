// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause
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
import 'dart:math' show max;

import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

import '../../tool/replay/src/capture_stream.dart';
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
}
