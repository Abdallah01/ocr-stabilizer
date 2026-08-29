// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause
//
// #116 finding C: the applied translation and the residual/confidence
// driving a coherent-shift merge used to come from TWO different drift
// snapshots. `_detectCoherentShift`'s dry pre-pass votes the group's
// translation from `driftTracker.medianDriftForKey` read ONCE, before
// this capture's own merges run. But `_mergeImpl`'s step 2 re-read that
// same call LIVE, against a tracker any EARLIER same-capture merge in
// the real interleaved loop had already mutated (every ordinary merge
// records a drift observation, whether or not it is a coherent-shift
// member — see `_mergeImpl`'s trackDrift step). Which member's merge
// runs first (and therefore whether a shared space key has crossed the
// tracker's 3-observation floor by the time a LATER member's merge
// reads it) follows arrival order, so `MergeResult.driftCorrection` —
// and the residual computed from it — could silently diverge across
// otherwise-identical orderings even after finding B made the group's
// MEMBERSHIP and translation themselves order-independent.
//
// This reuses stabilization_engine_coherent_shift_order_independence_
// test.dart's 4-block scenario (3 uniform movers sharing one drift
// space key, 1 jittered outlier that never joins the group) and adds a
// 4th block (charlie, the outlier) whose own real merge ALSO writes a
// same-capture drift observation into that shared space key — the
// exact contamination source. It pins two things finding B's own test
// cannot: (1) every coherent-shift member's `driftCorrection` this
// capture is the SAME frozen pre-capture snapshot (`Offset.zero` here,
// since the tracker is empty before this capture), and (2) the merged
// rects that follow from it are therefore identical across every
// arrival order.
import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/step_response.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';
import 'package:ocr_stabilizer/src/types/geometry.dart' show Offset;

DefaultTrackedBlock<Object> _block(
  String text, {
  required double left,
  required double top,
  double width = 100,
  double height = 20,
  int observationCount = 3,
}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, width, height),
      payload: const Object(),
      originalText: text,
      observationCount: observationCount,
    );

const _alphaText = 'alpha block text one';
const _bravoText = 'bravo block text two';
const _charlieText = 'charlie block text three';
const _deltaText = 'delta block text four';

/// Runs the shared 4-block coherent-shift scenario with fresh blocks
/// supplied to `stabilize()` in [order]. Returns, per original text, the
/// [MergeResult.driftCorrection] and merged rect the engine produced —
/// captured via the merger callback, since [DefaultTrackedBlock] itself
/// retains neither.
({Map<String, Offset> driftCorrection, Map<String, AbsoluteRect> rects})
    _runScenario(List<int> order) {
  final driftCorrection = <String, Offset>{};
  final rects = <String, AbsoluteRect>{};
  final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
    merger: (existing, fresh, m) {
      driftCorrection[fresh.originalText] = m.driftCorrection;
      final merged = existing.applyMerge(m);
      rects[fresh.originalText] = merged.absoluteRect;
      return merged;
    },
    stepResponse: StepResponse.coherentShift,
    missedFrameRetention: 3,
  );

  // Seed 4 established blocks, well separated so text stays unambiguous.
  // alpha/bravo/charlie/delta's FRESH tops below (650/750/850/950) all
  // land in the SAME drift space key (regionSize defaults to 500, so
  // floor(top / 500) == 1 for all four) — the shared space key finding C
  // guards against cross-member contamination in.
  final seeds = [
    _block(_alphaText, left: 0, top: 500),
    _block(_bravoText, left: 0, top: 600),
    _block(_charlieText, left: 300, top: 700),
    _block(_deltaText, left: 0, top: 800),
  ];
  engine.stabilize(seeds);

  // All 4 shift dy=+150. alpha/bravo/delta shift dx=0 exactly (a clean,
  // uniform page-scroll group); charlie shifts dx=+15 too (the "extra
  // horizontal jitter" outlier) — it still MATCHES and MERGES (and so
  // still writes a same-capture drift observation into the shared space
  // key), it just never joins the coherent-shift group.
  final freshByIndex = [
    _block(_alphaText, left: 0, top: 650),
    _block(_bravoText, left: 0, top: 750),
    _block(_charlieText, left: 315, top: 850),
    _block(_deltaText, left: 0, top: 950),
  ];
  final fresh = [for (final i in order) freshByIndex[i]];
  engine.stabilize(fresh);

  return (driftCorrection: driftCorrection, rects: rects);
}

void main() {
  group('StabilizationEngine coherent-shift merges use ONE frozen drift '
      'snapshot (#116, finding C)', () {
    // Same exhaustive 6-permutation sweep as finding B's test — the
    // point here is a DIFFERENT observable (residual/driftCorrection and
    // the merged rects that follow from it), not membership.
    final permutations = [
      [0, 1, 2, 3],
      [3, 2, 1, 0],
      [2, 0, 1, 3],
      [3, 1, 0, 2],
      [1, 3, 0, 2],
      [0, 2, 3, 1],
    ];

    test(
        'every coherent-shift member reports the SAME driftCorrection this '
        'capture — the pre-capture snapshot, not a live re-read', () {
      for (final order in permutations) {
        final r = _runScenario(order);
        // The tracker is empty before this capture (the seeding capture
        // above matched nothing, so recorded no observations) — the
        // frozen pre-capture median for every space key is Offset.zero.
        // Before finding C, whichever member's real merge happened to
        // run AFTER this capture's own contaminating observations (from
        // charlie and/or earlier group members) crossed the tracker's
        // 3-observation floor would report a non-zero, arrival-order-
        // dependent value instead.
        for (final text in [_alphaText, _bravoText, _deltaText]) {
          expect(r.driftCorrection[text], Offset.zero,
              reason: 'order $order: "$text" must report the frozen '
                  'pre-capture snapshot, not a live tracker re-read '
                  'contaminated by an earlier same-capture merge');
        }
      }
    });

    test('every arrival order produces IDENTICAL merged rects for the '
        'clean group', () {
      final results = [for (final order in permutations) _runScenario(order)];
      final reference = results.first;

      for (var i = 1; i < results.length; i++) {
        final r = results[i];
        for (final text in [_alphaText, _bravoText, _deltaText]) {
          expect(r.rects[text]!.raw.left, reference.rects[text]!.raw.left,
              reason: 'permutation ${permutations[i]} vs '
                  '${permutations[0]}: "$text" left diverged');
          expect(r.rects[text]!.raw.top, reference.rects[text]!.raw.top,
              reason: 'permutation ${permutations[i]} vs '
                  '${permutations[0]}: "$text" top diverged');
        }
      }
    });
  });
}
