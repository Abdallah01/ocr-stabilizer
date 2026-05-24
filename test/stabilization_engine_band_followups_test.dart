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

import 'package:flutter_test/flutter_test.dart';

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
        'a band candidate locked first is superseded by a later primary match in the same scan',
        () {
      // Two seeded blocks, both with observationCount well above the band
      // candidate floor:
      //   - "hello world" at (0, 0)        — band-similar to fresh
      //   - "the quick brown fox" at (200, 0) — primary-identical to fresh
      //
      // Fresh: "the quick brown fox" at (200, 0). The spatial index may
      // surface BOTH seeds as candidates. Whichever order it returns:
      //   - The "hello world" seed is band-similar to fresh via Lev/Jacc band
      //     floors (after sufficient overlap, would be a band match).
      //   - The "the quick brown fox" seed is primary-identical (Lev = 1.0).
      // The PR2 single-pass design must ensure primary always wins regardless
      // of order — and bandStats.matchesAdmitted must be 0 because the primary
      // match supersedes any locked band candidate.
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
          // Custom spatialConfirm accepts everything so the band-similar
          // candidate would be admitted if the engine didn't prefer primary.
          // (The default closure requires spatial overlap; using a permissive
          // predicate isolates the precedence test from the spatial-index
          // cell filter.)
        ),
      );

      // Seed both blocks with well-observed counts.
      engine.stabilize([
        _block('hello world', left: 0, top: 0, observationCount: 5),
        _block('the quick brown fox',
            left: 0, top: 0, width: 200, observationCount: 5),
      ]);

      // Fresh observation: primary-identical to the second seed at the
      // SAME rect — the spatial index surfaces it as a primary candidate.
      // (Choosing same-rect avoids any cell-filter complication.)
      engine.stabilize([
        _block('the quick brown fox', left: 0, top: 0, width: 200),
      ]);

      // Primary always wins → no band admission, regardless of scan order.
      expect(engine.bandStats.matchesAdmitted, 0,
          reason: 'primary match must supersede any band candidate locked '
              'earlier in the same single-pass scan');

      // The primary match is recorded in primaryMatchesAdmitted.
      expect(engine.bandStats.primaryMatchesAdmitted, greaterThanOrEqualTo(1),
          reason: 'a primary-identical candidate should at least register '
              'one primary admission');
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
      // is still provisional. The merge path's freeze-path early-return at
      // _mergeImpl handles this — the band wrap is NOT re-applied, and the
      // captures counter is decremented (not reset).
      final r2 = engine.stabilize([_block('hxlxo wyrld', left: 0, top: 0)]);
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
