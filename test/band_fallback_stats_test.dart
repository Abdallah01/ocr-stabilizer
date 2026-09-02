// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/band_fallback_stats.dart';

void main() {
  group('BandFallbackStats counters (#20)', () {
    test('all counters default to 0', () {
      final stats = BandFallbackStatsInternal();
      expect(stats.primaryMatchesAdmitted, 0);
      expect(stats.primaryMatchesRejected, 0);
      expect(stats.candidatesConsidered, 0);
      expect(stats.rejectedCandidateFloor, 0);
      expect(stats.rejectedSpatial, 0);
      expect(stats.rejectedTextBand, 0);
      expect(stats.bandMatchesIdentified, 0);
      expect(stats.matchesAdmitted, 0);
    });

    test('mutators tick the corresponding counter once each', () {
      final stats = BandFallbackStatsInternal();
      stats.recordPrimaryMatchAdmitted();
      stats.recordPrimaryMatchRejected();
      stats.recordCandidateConsidered();
      stats.recordRejectedCandidateFloor();
      stats.recordRejectedSpatial();
      stats.recordRejectedTextBand();
      stats.recordBandMatchIdentified();
      stats.recordMatchAdmitted();

      expect(stats.primaryMatchesAdmitted, 1);
      expect(stats.primaryMatchesRejected, 1);
      expect(stats.candidatesConsidered, 1);
      expect(stats.rejectedCandidateFloor, 1);
      expect(stats.rejectedSpatial, 1);
      expect(stats.rejectedTextBand, 1);
      expect(stats.bandMatchesIdentified, 1);
      expect(stats.matchesAdmitted, 1);
    });

    test('reset() zeroes every counter', () {
      final stats = BandFallbackStatsInternal();
      stats.recordPrimaryMatchAdmitted();
      stats.recordPrimaryMatchAdmitted();
      stats.recordRejectedTextBand();
      for (var i = 0; i < 5; i++) {
        stats.recordCandidateConsidered();
      }
      stats.reset();
      expect(stats.primaryMatchesAdmitted, 0);
      expect(stats.primaryMatchesRejected, 0);
      expect(stats.candidatesConsidered, 0);
      expect(stats.rejectedCandidateFloor, 0);
      expect(stats.rejectedSpatial, 0);
      expect(stats.rejectedTextBand, 0);
      expect(stats.bandMatchesIdentified, 0);
      expect(stats.matchesAdmitted, 0);
    });

    test('upcast to BandFallbackStats exposes getters', () {
      final BandFallbackStatsInternal internal = BandFallbackStatsInternal();
      internal.recordPrimaryMatchAdmitted();
      final BandFallbackStats view = internal; // upcast
      expect(view.primaryMatchesAdmitted, 1);
      // The static type `BandFallbackStats` does not have mutators —
      // attempting to call `view.recordPrimaryMatchAdmitted()` would be a
      // compile error. (Runtime downcast is possible — documented in spec
      // §7 risks as a convention-only protection.)
    });

    test(
        'BandFallbackStats has private constructor; only Internal can construct',
        () {
      // Compile-time test: BandFallbackStats() (the public ctor) does not exist —
      // BandFallbackStats has only a private constructor `._()`. The only public
      // construction path is via BandFallbackStatsInternal() which calls super._().
      final BandFallbackStats view = BandFallbackStatsInternal();
      expect(view, isA<BandFallbackStats>());
    });
  });
}
