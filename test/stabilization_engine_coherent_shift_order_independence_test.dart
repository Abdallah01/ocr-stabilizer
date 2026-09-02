// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #116 finding B: `_detectCoherentShift`'s original clustering sorted
// moved pairs by displacement.dy ONLY, then ran a single greedy pass with
// an INCREMENTAL running median. Two moved pairs with equal (or
// near-equal) dy have no secondary sort key, so their relative order in
// the sort — and therefore which running-median state a later candidate
// is compared against — depended on caller arrival order. This pins
// order-INDEPENDENCE of GROUP MEMBERSHIP for the exact failure shape a
// hand-trace found: 3 blocks shifting uniformly plus 1 with extra
// horizontal jitter. Under the old algorithm, some caller orderings
// grouped only 2 of the 3 clean movers (below `coherentShiftMinBlocks`,
// so the whole batch fell back to damp) while others correctly grouped
// all 3 — see this file's git log for a debug trace proving the
// divergence against the pre-fix source.
//
// Scope note: this file pins membership only (which blocks join the
// group, and that non-members are excluded) — the fix here alone is
// NOT sufficient for identical numeric output (translation / merged
// rects) across arrival orders, because a member's real merge still
// re-reads a same-capture-mutable drift tracker unless finding C's
// frozen-snapshot fix is also in place. See
// stabilization_engine_coherent_shift_frozen_drift_test.dart for that
// numeric pin.
import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/step_response.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

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

/// Runs the fixed 4-block coherent-shift scenario with fresh blocks
/// supplied to `stabilize()` in [order] (an index permutation over
/// [alpha, bravo, charlie, delta]). Returns, per original text, the
/// [StepResponse] the engine applied to that block's merge — captured via
/// the merger callback, since [DefaultTrackedBlock] itself does not
/// retain `stepResponseApplied`.
Map<String, StepResponse?> _runScenario(List<int> order) {
  final applied = <String, StepResponse?>{};
  final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
    merger: (existing, fresh, m) {
      applied[fresh.originalText] = m.stepResponseApplied;
      return existing.applyMerge(m);
    },
    stepResponse: StepResponse.coherentShift,
    missedFrameRetention: 3,
  );

  // Seed 4 established blocks, well separated so text stays unambiguous.
  final seeds = [
    _block(_alphaText, left: 0, top: 500),
    _block(_bravoText, left: 0, top: 600),
    _block(_charlieText, left: 300, top: 700),
    _block(_deltaText, left: 0, top: 800),
  ];
  engine.stabilize(seeds);

  // All 4 shift dy=+150. alpha/bravo/delta shift dx=0 exactly (a clean,
  // uniform page-scroll group); charlie shifts dx=+15 too (the "extra
  // horizontal jitter" outlier). height=20, the default
  // coherentShiftTolerance=0.5 => tolerance=10px, so charlie's 15px
  // exceeds the clean group's tolerance and must never join it.
  final freshByIndex = [
    _block(_alphaText, left: 0, top: 650),
    _block(_bravoText, left: 0, top: 750),
    _block(_charlieText, left: 315, top: 850),
    _block(_deltaText, left: 0, top: 950),
  ];
  final fresh = [for (final i in order) freshByIndex[i]];
  engine.stabilize(fresh);

  return applied;
}

void main() {
  group('StabilizationEngine coherent-shift clustering is order-'
      'independent (#116, finding B)', () {
    // 6 permutations of 4 elements is a full sweep of arrival order —
    // exhaustive here since the scenario is small and the point is to
    // never hit a bad ordering, not to sample a subset.
    final permutations = [
      [0, 1, 2, 3],
      [3, 2, 1, 0],
      [2, 0, 1, 3],
      [3, 1, 0, 2],
      [1, 3, 0, 2],
      [0, 2, 3, 1],
    ];

    test('the clean 3-block group (alpha/bravo/delta) forms in EVERY '
        'arrival order; the jittered outlier (charlie) never joins it',
        () {
      for (final order in permutations) {
        final applied = _runScenario(order);
        expect(applied[_alphaText], StepResponse.coherentShift,
            reason: 'order $order: alpha must receive the group shift');
        expect(applied[_bravoText], StepResponse.coherentShift,
            reason: 'order $order: bravo must receive the group shift');
        expect(applied[_deltaText], StepResponse.coherentShift,
            reason: 'order $order: delta must receive the group shift');
        expect(applied[_charlieText], isNull,
            reason: 'order $order: charlie\'s 15px horizontal jitter '
                'exceeds the clean group\'s 10px tolerance — it must '
                'never join the coherent-shift group, in any order');
      }
    });

    // Numeric consistency (identical translation / merged rects across
    // permutations, not just identical membership) needs finding C's
    // frozen-drift-snapshot fix as well as this one — see
    // stabilization_engine_coherent_shift_frozen_drift_test.dart.
  });
}
