// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause
//
// Test backfill for #34 — covers gaps the v0.4.0 fan-out review identified:
//
// - T2: primary always beats band, even when band candidate is locked first
//       in the single-pass _findMatch scan.
// - T3: a second band-admit on a block already in its provisional window is
//       absorbed by the freeze-path early-return; no double-wrap, no
//       captures-counter reset.
// - C1: rejectedTextBand counter ticks correctly so the band funnel is
//       decomposable.

import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(
  String text, {
  required double left,
  required double top,
  double width = 50,
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
  group('#34 T2 — primary-beats-band resolution in single-pass _findMatch', () {
    test(
        'a band candidate locked first is superseded by a later primary match in the same scan; matchesAdmitted stays 0',
        () {
      // Seed two well-observed blocks at NEARBY rects so the spatial index
      // surfaces both as candidates for one fresh observation:
      //   - "hxlxo wxrxd" at (0, 0)   — band-similar to "hello world"
      //                                 (used throughout the band test suite;
      //                                 Lev ~0.55, Jaccard >= 0.60).
      //   - "hello world" at (60, 0)  — primary-identical to fresh.
      //
      // Custom spatialConfirm always returns true so the band candidate
      // would be admitted if the engine didn't prefer primary; this isolates
      // the precedence test from the default drift-aware spatial gate.
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
          spatialConfirm: (fresh, candidate) => true,
        ),
      );

      // Seed BOTH blocks in one stabilize call. During this call the
      // engine processes them sequentially against an empty spatialIndex
      // (the index is rebuilt AFTER the per-frame loop, not between
      // iterations), so neither merges with the other — both end up in
      // stableBlocks. After the call's terminal rebuild, the index holds
      // BOTH seeds.
      //
      // Cell math (bucket=200, key=round((left+w/2)/200), probe is ±1):
      //   - seed1 at x=0,   w=50 → cell 0 ((0+25)/200 = 0.125 → 0)
      //   - seed2 at x=400, w=50 → cell 2 ((400+25)/200 = 2.125 → 2)
      //   - fresh at x=200, w=50 → cell 1 ((200+25)/200 = 1.125 → 1)
      // Fresh in cell 1 probes cells 0..2 → sees BOTH seeds simultaneously.
      engine.stabilize([
        _block('hxlxo wxrxd', left: 0, top: 0, observationCount: 5),
        _block('hello world', left: 400, top: 0, observationCount: 5),
      ]);

      // Reset stats so we only count counters that tick during the actual
      // precedence test.
      engine.bandStats.reset();

      // Fresh "hello world" at x=200 — cell 1 surfaces both seeds as
      // candidates.
      engine.stabilize([_block('hello world', left: 200, top: 0)]);

      // Primary always wins → no band admission, regardless of which order
      // the spatial index surfaces candidates.
      expect(engine.bandStats.matchesAdmitted, 0,
          reason: 'primary match must supersede any band candidate locked '
              'earlier in the same single-pass scan — matchesAdmitted ticks '
              'only when the band path actually returns the match.');

      // bandMatchesIdentified MAY be 1 (the band candidate was scanned and
      // qualified) — that's the locked-but-superseded state we explicitly
      // expect.
      expect(engine.bandStats.bandMatchesIdentified, greaterThanOrEqualTo(1),
          reason: 'the band-similar candidate qualified during scan (lock), '
              'but matchesAdmitted should NOT tick — that\'s the precedence '
              'rule under test');

      expect(engine.bandStats.primaryMatchesAdmitted, greaterThanOrEqualTo(1),
          reason: 'primary-identical candidate must drive primary admission');
    });
  });

  group(
      '#34 T3 — second band-admit on a still-provisional block is absorbed by freeze-path',
      () {
    test(
        'second band-admission event on a provisional block does not re-wrap or reset captures',
        () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
          provisionalCaptures: 3,
        ),
      );

      // Step 1: seed with observationCount: 5 (above floor).
      engine.stabilize([
        _block('hello world', left: 0, top: 0, observationCount: 5),
      ]);

      // Step 2: first band-admission. Block becomes provisional with captures=3.
      final r1 = engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);
      final after1 =
          r1.stableBlocks.firstWhere((b) => b.absoluteRect.raw.left == 0);
      expect(after1.isProvisional, isTrue,
          reason: 'first band admit marks the block provisional');
      expect(after1.provisionalCapturesRemaining, 3);

      // Step 3: a SECOND band-similar observation arrives while the block
      // is still provisional. Re-using 'hxlxo wxrxd' (proven band-similar
      // to 'hello world' across the band test suite — Lev ~0.55, below
      // primary's 0.70 floor but above band's 0.50 floor). The cached
      // block's text-vote winner is 'hello world' (seed seeded first;
      // ties to first), so this second observation goes through the band
      // path AGAIN, not the primary path. The merge logic's freeze-path
      // early-return must absorb this without re-wrapping or resetting
      // captures.
      final r2 = engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);
      final after2 =
          r2.stableBlocks.firstWhere((b) => b.absoluteRect.raw.left == 0);
      expect(after2.isProvisional, isTrue,
          reason: 'block stays provisional, not re-wrapped');
      expect(after2.provisionalCapturesRemaining, lessThan(3),
          reason: 'captures must decrement on the second admit pass, not '
              'reset to 3 — that would extend the provisional window '
              'indefinitely under repeated band activity');
      expect(after2.provisionalCapturesRemaining, greaterThanOrEqualTo(1),
          reason: 'one decrement step keeps captures >= 1');
    });
  });

  group('#34 C1 — rejectedTextBand counter ticks on text-band miss', () {
    test(
        'a candidate that passes observation-floor + spatial gates but fails BOTH band text floors ticks rejectedTextBand',
        () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: BandFallbackConfig(
          mode: BandFallbackMode.observeOnly,
          candidateObservationFloor: 1,
          bandLevenshteinFloor: 0.50,
          bandJaccardFloor: 0.60,
          spatialConfirm: (fresh, candidate) => true, // always pass spatial
        ),
      );

      // Seed: "hello world".
      engine.stabilize([
        _block('hello world', left: 0, top: 0, observationCount: 5),
      ]);

      // Fresh: completely unrelated text at the same rect.
      //   - 'zzzzzzz' has no significant-character overlap with "hello world".
      //   - Lev/Jaccard well below both band floors.
      // Spatial passes (custom predicate always true), observation floor passes
      // (seed has 5 observations). Only the text-band gate should reject.
      engine.stabilize([_block('zzzzzzz', left: 0, top: 0)]);

      expect(engine.bandStats.rejectedTextBand, greaterThanOrEqualTo(1),
          reason: 'text-band miss must tick the new rejectedTextBand counter');
      // Sanity: the candidate WAS considered (passed earlier gates).
      expect(engine.bandStats.candidatesConsidered, greaterThanOrEqualTo(1));
      // And it didn't reach bandMatchesIdentified.
      expect(engine.bandStats.bandMatchesIdentified, 0);
    });

    test(
        'decomposability: rejectedCandidateFloor + rejectedSpatial + rejectedTextBand + bandMatchesIdentified == candidatesConsidered (no admit-mode early-exit)',
        () {
      // observeOnly avoids the admit-mode early-exit so the funnel sums
      // exactly — the C1 doc claim depends on this regime.
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: BandFallbackConfig(
          mode: BandFallbackMode.observeOnly,
          candidateObservationFloor: 1,
          spatialConfirm: (fresh, candidate) => true,
        ),
      );

      // Multiple seeds at the same rect with varied text to exercise the
      // text-band reject path.
      engine.stabilize([
        _block('hello world', left: 0, top: 0, observationCount: 5),
        _block('foo bar baz', left: 0, top: 0, width: 60, observationCount: 5),
        _block('the quick fox',
            left: 0, top: 0, width: 70, observationCount: 5),
      ]);

      engine.stabilize([_block('zzzzzzz', left: 0, top: 0)]);

      final s = engine.bandStats;
      expect(
        s.rejectedCandidateFloor +
            s.rejectedSpatial +
            s.rejectedTextBand +
            s.bandMatchesIdentified,
        s.candidatesConsidered,
        reason: 'band funnel decomposability invariant — the new counter '
            'closes the gap that the doc on candidatesConsidered called out',
      );
    });
  });
}
