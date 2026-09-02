// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/drift_tracker.dart';
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
  int observationCount = 1,
}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, width, height),
      payload: const Object(),
      originalText: text,
      observationCount: observationCount,
    );

void main() {
  group('StabilizationEngine pre-pass vs. same-capture band interleaving '
      '(#116, finding A)', () {
    // Band-eligible text pair reused verbatim from
    // stabilization_engine_band_admit_test.dart: fails primary (Lev 0.70 /
    // Jaccard 0.80) but clears the default band floors.
    const cand1Text = 'hello world';
    const fresh1Text = 'hxlxo wxrxd';
    const cand2Text = 'goodbye moon';
    const fresh2Text = 'gxxdbxe mxxn';

    test(
        'a same-capture band admission that crosses the drift tracker\'s '
        '3-observation floor changes a LATER same-capture band decision — '
        'matching main\'s interleaved match+merge loop, not the pre-pass '
        'snapshot', () {
      // Seed the drift tracker directly with exactly 2 prior observations
      // for this space key (region index 1, since regionSize defaults to
      // 500 and every rect below sits at top in [500, 999)). `_findMatch`'s
      // band spatial-confirm reads `driftMarginForKey`, which is pinned to
      // Offset.zero below 3 observations — so this space key's margin is
      // 0.0 until a 3rd observation lands.
      final tracker = DriftTracker();
      final seedBlock = _block('seed', left: 0, top: 700);
      tracker.addObservation(seedBlock, const Offset(0, 20), blockHeight: 20);
      tracker.addObservation(seedBlock, const Offset(0, 20), blockHeight: 20);
      expect(
        tracker.medianDriftForKey(tracker.spaceKeyFor(seedBlock)),
        Offset.zero,
        reason: 'sanity: exactly 2 observations, below the 3-observation '
            'floor — median is still pinned to zero',
      );

      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        driftTracker: tracker,
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
        ),
        missedFrameRetention: 3,
        // Isolate this from #116's own step-response machinery — the
        // regression under test predates and is orthogonal to it (finding A
        // says explicitly: present even under damp).
        stepResponse: StepResponse.damp,
      );

      // Establish cand1 (top=500) and cand2 (top=950). Both sit in the
      // SAME drift space key (region index 1), but 450px apart — outside
      // each other's spatial-index 3x3 bucket neighborhood (bucket height
      // 200px), so neither is ever a spatial-confirm candidate for the
      // other's fresh counterpart. Verified empirically: with less
      // separation both fresh blocks see BOTH candidates and the band
      // counters below no longer hold cleanly.
      final cand1 = _block(cand1Text, left: 0, top: 500);
      final cand2 = _block(cand2Text, left: 0, top: 950);
      engine.stabilize([cand1, cand2]);

      // Target capture: two band-eligible fresh blocks in the SAME
      // capture, same space key.
      //
      // fresh1 sits at cand1's EXACT rect (100% overlap) — its band
      // spatial-confirm passes at ANY margin, including 0. Admitting it
      // records a drift observation (raw drift (0,0), since the rects are
      // identical) — the 3rd observation for this space key, which flips
      // `medianDriftForKey` from Offset.zero to the median of
      // [(0,20),(0,20),(0,0)] = (0,20) (dy dominates the margin — see
      // DriftTracker.driftMarginForKey).
      final fresh1 = _block(fresh1Text, left: 0, top: 500);

      // fresh2 sits 1px below cand2's bottom edge (cand2: top=950,
      // bottom=970; fresh2: top=971). At drift margin 0, the two rects do
      // not touch at all (overlapRatio == 0.0 — well under the 0.80 band
      // spatial floor). At drift margin 20 (the value fresh1's admission
      // produces, once medianBlockHeightForKey settles at 20), expanding
      // fresh2's rect by 20px on every side closes the 1px gap and
      // overlaps 19 of cand2's 20px height for 100% of its width:
      // overlapRatio == (100*19)/(100*20) == 0.95 >= 0.80.
      final fresh2 = _block(fresh2Text, left: 0, top: 971);

      final result = engine.stabilize([fresh1, fresh2]);
      expect(result.stableBlocks, hasLength(2),
          reason: 'exactly one merge/insert outcome per fresh block');

      // Identify by top-left position: the two outcomes sit far apart
      // (~500 vs ~950+) regardless of exactly how the drift-corrected
      // weighted-average lerp lands the first merge, so a coarse split is
      // robust without hard-pinning that unrelated arithmetic.
      final sorted = result.stableBlocks.toList()
        ..sort((a, b) => a.absoluteRect.raw.top.compareTo(b.absoluteRect.raw.top));
      final merged1 = sorted[0];
      final outcome2 = sorted[1];

      // fresh1 must have band-admitted against cand1 regardless of
      // ordering — its own spatial confirm never depended on the tracker
      // state this capture changes.
      expect(merged1.isProvisional, isTrue,
          reason: 'fresh1 band-admits against cand1 unconditionally — its '
              'own spatial confirm has 100% overlap at margin 0');
      expect(merged1.observationCount, 2,
          reason: 'fresh1 merges into cand1 (seeded observationCount 1)');

      // THE regression: fresh2 must band-admit against cand2 too — main's
      // interleaved match+merge loop lets fresh1's merge (processed first,
      // in fresh-block order) land its drift observation BEFORE fresh2's
      // own spatial-confirm runs, exactly as it would across two separate
      // stabilize() calls. A pre-pass that resolves every match against a
      // single pre-capture drift-tracker snapshot cannot see fresh1's
      // same-capture contribution, and rejects fresh2's band match
      // entirely — regressing to a brand-new (obsCount 1, non-provisional)
      // block instead.
      expect(outcome2.isProvisional, isTrue,
          reason: 'fresh2 must band-admit against cand2 — this is the '
              'exact case finding A identifies as regressed. A rejected '
              'match instead inserts fresh2 as a brand-new, '
              'non-provisional block');
      expect(outcome2.observationCount, 2,
          reason: 'a band admission increments observationCount from '
              "cand2's seeded 1 — a rejected match would instead insert "
              'fresh2 as a brand-new block with observationCount 1');

      // Counters: both fresh blocks reach _findMatch and miss primary (2,
      // from this capture) plus cand1/cand2's own seeding capture (2,
      // empty index) == 4 total. Each fresh block's spatial-index query
      // only ever reaches its own same-position candidate (2 considered).
      // Both admit under the correct (interleaved) behavior.
      expect(engine.bandStats.primaryMatchesRejected, 4);
      expect(engine.bandStats.candidatesConsidered, 2);
      expect(engine.bandStats.bandMatchesIdentified, 2,
          reason: 'both band spatial-confirms pass once fresh1\'s own '
              'admission has landed its drift observation');
      expect(engine.bandStats.matchesAdmitted, 2);
    });
  });
}
