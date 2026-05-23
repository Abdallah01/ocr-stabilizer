// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

/// Per-capture telemetry for the matching path inside `StabilizationEngine`.
///
/// All counters are cumulative until [reset] is called. The engine never
/// calls [reset] automatically; consumers reset between captures if they
/// want per-capture buckets.
///
/// Primary counters tick whether or not the band-fallback path is enabled —
/// they reflect the primary path's outcome. Band counters only tick when
/// `BandFallbackConfig.mode` is `BandFallbackMode.observeOnly` or
/// `BandFallbackMode.admit`.
///
/// Read-only public surface: consumers see this type via
/// `StabilizationEngine.bandStats`. The engine writes via
/// [BandFallbackStatsInternal], which lives in the same library and
/// reaches the underscore-private fields.
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

  /// Number of candidates that passed every gate (observation floor,
  /// spatial confirm, text band floors). In `admit` mode this also ticks
  /// [matchesAdmitted]; in `observeOnly` mode it ticks alone.
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
    _bandMatchesIdentified = 0;
    _matchesAdmitted = 0;
  }
}

/// Engine-side mutation surface. Lives in the same library as
/// [BandFallbackStats] so the underscore-private fields are accessible.
///
/// Public to the package — consumers see only the [BandFallbackStats]
/// supertype via `StabilizationEngine.bandStats`. The `Internal` suffix
/// signals "package-internal API"; a determined consumer can downcast and
/// mutate, but the convention is enforced socially, not by the language.
class BandFallbackStatsInternal extends BandFallbackStats {
  BandFallbackStatsInternal() : super._();

  void recordPrimaryMatchAdmitted() => _primaryMatchesAdmitted++;
  void recordPrimaryMatchRejected() => _primaryMatchesRejected++;
  void recordCandidateConsidered() => _candidatesConsidered++;
  void recordRejectedCandidateFloor() => _rejectedCandidateFloor++;
  void recordRejectedSpatial() => _rejectedSpatial++;
  void recordBandMatchIdentified() => _bandMatchesIdentified++;
  void recordMatchAdmitted() => _matchesAdmitted++;
}
