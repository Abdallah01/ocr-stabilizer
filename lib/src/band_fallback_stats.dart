// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

/// Per-capture telemetry for the matching path inside `StabilizationEngine`.
///
/// **Core invariant**:
/// `primaryMatchesAdmitted + primaryMatchesRejected ==` total fresh
/// observations that reached `_findMatch` (i.e. every observation that the
/// engine evaluated for matching) **since the last [reset] call, or since
/// construction if [reset] was never called**. The two counters partition
/// the primary-path outcome, regardless of whether the band-fallback
/// path is enabled.
///
/// **Reset ownership**: all counters are cumulative until [reset] is
/// called. **The engine never calls [reset] automatically**; consumers own
/// per-capture bucketing — call `bandStats.reset()` between captures if
/// you want per-capture counter values, or leave it alone for cumulative
/// session totals.
///
/// Primary counters tick whether or not the band-fallback path is enabled —
/// they reflect the primary path's outcome. Band counters only tick when
/// `BandFallbackConfig.mode` is `BandFallbackMode.observeOnly` or
/// `BandFallbackMode.admit`.
///
/// **Do not downcast to a mutating subtype.** This package exposes a
/// concrete [BandFallbackStatsInternal] in the same library so the engine
/// can write counters; the supertype is the consumer-facing read-only
/// view. Reaching into `Internal` from consumer code is unsupported and
/// will be tightened in a future release.
class BandFallbackStats {
  BandFallbackStats._();

  /// Number of fresh observations that found a primary-path match.
  int get primaryMatchesAdmitted => _primaryMatchesAdmitted;
  int _primaryMatchesAdmitted = 0;

  /// Number of fresh observations that the primary path rejected.
  /// `primaryMatchesAdmitted + primaryMatchesRejected` equals the total
  /// number of fresh observations that reached `_findMatch`.
  int get primaryMatchesRejected => _primaryMatchesRejected;
  int _primaryMatchesRejected = 0;

  /// Number of candidates the band loop scanned. Only ticks when
  /// `mode != off`. Compare against [primaryMatchesRejected] to compute
  /// "candidates considered per primary miss."
  ///
  /// **Note (admit-mode early-exit semantics)**: in `admit` mode, once a
  /// band candidate has been locked for the current fresh observation,
  /// subsequent candidates skip band evaluation (observation floor +
  /// spatial confirm + text band floors) and do NOT tick this counter
  /// — but they STILL participate in the primary-path check in the same
  /// iteration. So this reflects "candidates the band loop actually
  /// scanned for THIS primary miss", not "total candidates the engine
  /// considered for THIS primary miss". For accounting that's invariant
  /// to admit-mode early-exit, sum `rejectedCandidateFloor +
  /// rejectedSpatial + rejectedTextBand + bandMatchesIdentified`
  /// instead — every term gates on the same early-exit, so the
  /// equality is mode-invariant.
  ///
  /// **Note (viewport-relativity skip)**: the band loop pre-filters
  /// candidates whose `isViewportRelative` differs from the fresh
  /// observation's; those candidates never enter the band loop and so
  /// do not tick any band counter. Rare in typical use, but worth knowing
  /// when interpreting low counter totals on visible-but-mismatched
  /// pages.
  int get candidatesConsidered => _candidatesConsidered;
  int _candidatesConsidered = 0;

  /// Number of candidates the band loop rejected because their
  /// `observationCount` was below `candidateObservationFloor`.
  int get rejectedCandidateFloor => _rejectedCandidateFloor;
  int _rejectedCandidateFloor = 0;

  /// Number of candidates the band loop rejected because `spatialConfirm`
  /// returned `false`.
  int get rejectedSpatial => _rejectedSpatial;
  int _rejectedSpatial = 0;

  /// Number of candidates the band loop rejected because their text
  /// similarity scores fell below BOTH band floors (Lev <
  /// `bandLevenshteinFloor` AND Jaccard < `bandJaccardFloor`). These are
  /// candidates that passed the observation-count floor AND spatial
  /// confirmation but couldn't clear even the relaxed text band.
  ///
  /// With this counter, the band funnel is decomposable:
  /// `rejectedCandidateFloor + rejectedSpatial + rejectedTextBand +
  /// bandMatchesIdentified == candidatesConsidered`. Every term gates
  /// on the same admit-mode early-exit (see [candidatesConsidered]) so
  /// the equality holds in both `admit` and `observeOnly`. The counter
  /// stays at 0 when `BandFallbackConfig.mode` is
  /// [BandFallbackMode.off] (the band loop is short-circuited entirely
  /// before any band counter ticks) and also for candidates filtered
  /// out by the viewport-relativity mismatch guard (see same note on
  /// [candidatesConsidered]).
  int get rejectedTextBand => _rejectedTextBand;
  int _rejectedTextBand = 0;

  /// Number of candidates that passed every gate (observation floor,
  /// spatial confirm, text band floors). In `admit` mode this also ticks
  /// [matchesAdmitted]; in `observeOnly` mode it ticks alone.
  ///
  /// **NaN-score invariant**: the band-floor check
  /// `levenshtein >= floor || jaccard >= floor` would treat NaN scores
  /// as misses (NaN never compares ≥ anything). The engine's score
  /// source (`TextDedupUtils.isTextSimilarWithScores`) cannot return NaN
  /// today — both metrics are bounded integer-DP / Jaccard with
  /// empty-string guards — so this is documented as an invariant rather
  /// than a runtime check. A future score source that can NaN must be
  /// guarded at its boundary, not here.
  int get bandMatchesIdentified => _bandMatchesIdentified;
  int _bandMatchesIdentified = 0;

  /// Number of band-relaxed matches actually returned by `_findMatch`.
  /// Always `<= bandMatchesIdentified`. In `observeOnly` mode this stays
  /// at zero by construction.
  int get matchesAdmitted => _matchesAdmitted;
  int _matchesAdmitted = 0;

  /// Zero every counter.
  void reset() {
    _primaryMatchesAdmitted = 0;
    _primaryMatchesRejected = 0;
    _candidatesConsidered = 0;
    _rejectedCandidateFloor = 0;
    _rejectedSpatial = 0;
    _rejectedTextBand = 0;
    _bandMatchesIdentified = 0;
    _matchesAdmitted = 0;
  }
}

/// Engine-side mutation surface. Lives in the same library as
/// [BandFallbackStats] so the underscore-private fields are accessible.
///
/// **Not part of the consumer API.** Consumers see only the
/// [BandFallbackStats] supertype via `StabilizationEngine.bandStats`. The
/// `Internal` suffix signals "package-internal API"; Dart has no
/// `internal` access modifier, so a determined consumer can downcast and
/// mutate — but this is unsupported and will break without notice. The
/// engine is the only intended writer. (`@visibleForTesting` was
/// considered, but the engine itself is the primary writer outside of
/// tests, which would trip the analyzer.)
class BandFallbackStatsInternal extends BandFallbackStats {
  /// Construct a fresh stats sink with every counter at zero.
  BandFallbackStatsInternal() : super._();

  /// Increment [BandFallbackStats.primaryMatchesAdmitted].
  void recordPrimaryMatchAdmitted() => _primaryMatchesAdmitted++;

  /// Increment [BandFallbackStats.primaryMatchesRejected].
  void recordPrimaryMatchRejected() => _primaryMatchesRejected++;

  /// Increment [BandFallbackStats.candidatesConsidered].
  void recordCandidateConsidered() => _candidatesConsidered++;

  /// Increment [BandFallbackStats.rejectedCandidateFloor].
  void recordRejectedCandidateFloor() => _rejectedCandidateFloor++;

  /// Increment [BandFallbackStats.rejectedSpatial].
  void recordRejectedSpatial() => _rejectedSpatial++;

  /// Increment [BandFallbackStats.rejectedTextBand].
  void recordRejectedTextBand() => _rejectedTextBand++;

  /// Increment [BandFallbackStats.bandMatchesIdentified].
  void recordBandMatchIdentified() => _bandMatchesIdentified++;

  /// Increment [BandFallbackStats.matchesAdmitted].
  void recordMatchAdmitted() => _matchesAdmitted++;
}
