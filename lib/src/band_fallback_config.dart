// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter/foundation.dart' show immutable;

import 'tracked_block.dart';

/// Operating mode for the band-relaxed fallback path inside
/// `StabilizationEngine._findMatch`.
enum BandFallbackMode {
  /// No band-fallback work runs. Primary path counters
  /// (`BandFallbackStats.primaryMatchesAdmitted` and
  /// `BandFallbackStats.primaryMatchesRejected`) still tick because they
  /// are populated by the primary path, not the band loop.
  off,

  /// The full band loop runs, every counter populates, but no candidate is
  /// ever returned. Use this mode to measure what `admit` *would* have
  /// done before flipping. The loop scans all candidates so per-stage
  /// counters reflect the full population, not just the first match.
  observeOnly,

  /// Production mode. The full band loop runs and returns the first
  /// candidate that clears every gate. Matches are admitted as
  /// provisional (see [BandFallbackConfig.provisionalCaptures]).
  admit,
}

/// Spatial confirmation predicate for a band-relaxed candidate.
///
/// Signature mirrors `ContextualInvalidationCheck` for consistency with
/// the engine's existing predicate-injection seam — two [TrackedBlock]
/// arguments, no engine-internal types (`SpaceKey`, `DriftTracker`)
/// leaked into public signatures.
typedef BandSpatialPredicate = bool Function(
    TrackedBlock fresh, TrackedBlock candidate);

/// Configuration for the band-relaxed fallback path inside
/// `StabilizationEngine._findMatch`.
///
/// Default is [BandFallbackMode.off]. Recommended adoption flow:
/// ship with `mode: off`, switch to `observeOnly` to read
/// `BandFallbackStats`, commit to `admit` once the counter ratios
/// justify it.
///
/// Primary-path floors (Lev 0.70 / Jaccard 0.80) are owned by the engine
/// and not configurable through this type — see
/// `TextDedupUtils.isTextSimilarWithScores` for those.
@immutable
class BandFallbackConfig {
  /// Operating mode. Default: [BandFallbackMode.off].
  final BandFallbackMode mode;

  /// Lower Levenshtein threshold for band-relaxed matches.
  /// Range: `[0.0, 0.70)` — the upper bound is exclusive because matches
  /// at `>= 0.70` go through the primary path.
  /// Default: `0.50`.
  final double bandLevenshteinFloor;

  /// Lower Jaccard threshold for band-relaxed matches.
  /// Range: `[0.0, 0.80)` — the upper bound is exclusive because matches
  /// at `>= 0.80` go through the primary path.
  /// Default: `0.60`.
  final double bandJaccardFloor;

  /// Minimum `observationCount` a candidate must have before it can be
  /// considered for band-relaxed admission. Filters candidates whose own
  /// existence is still provisional, preventing a provisional fresh
  /// observation from vouching for a provisional candidate.
  ///
  /// Must be `>= 0`. Default: `provisionalCaptures + 1` (= `4` with the
  /// default `provisionalCaptures`) — semantically "candidate has
  /// cleared its own provisional window."
  ///
  /// Consumers who want provisional-on-provisional admission (the
  /// existing provisional-decay path is self-cleaning eventually) can
  /// lower this to `1` or `2` explicitly.
  final int candidateObservationFloor;

  /// `provisionalCapturesRemaining` granted to a freshly band-admitted
  /// match. Must be `>= 1` (reflects `MergeResult`'s invariant that
  /// `isProvisional` implies `provisionalCapturesRemaining > 0`).
  ///
  /// Default: `3`. Picked to match the value already used by downstream
  /// consumers as a proven 3-capture grace window; the package owns the
  /// default thereafter — tune per deployment if the grace window is too
  /// generous or too tight.
  final int provisionalCaptures;

  /// Spatial confirmation predicate. `null` means the engine substitutes a
  /// drift-aware overlap-ratio closure at construction time
  /// (`overlapRatio >= 0.80` with the candidate's space-keyed drift margin).
  /// Default: `null`.
  final BandSpatialPredicate? spatialConfirm;

  /// Construct a config. All fields are optional; defaults are documented
  /// per-field above. The constructor uses `assert` (not `throw`) so it
  /// stays `const`-capable for default-parameter-value use sites. In debug
  /// builds an invariant violation fires `AssertionError`; release builds
  /// strip the checks. Invariants:
  /// - `bandLevenshteinFloor` must be in `[0.0, 0.70)`
  /// - `bandJaccardFloor` must be in `[0.0, 0.80)`
  /// - `candidateObservationFloor` must be `>= 0`
  /// - `provisionalCaptures` must be `>= 1`
  const BandFallbackConfig({
    this.mode = BandFallbackMode.off,
    this.bandLevenshteinFloor = 0.50,
    this.bandJaccardFloor = 0.60,
    int? candidateObservationFloor,
    this.provisionalCaptures = 3,
    this.spatialConfirm,
  })  : candidateObservationFloor =
            candidateObservationFloor ?? (provisionalCaptures + 1),
        assert(bandLevenshteinFloor >= 0.0 && bandLevenshteinFloor < 0.70,
            'bandLevenshteinFloor must be in [0.0, 0.70)'),
        assert(bandJaccardFloor >= 0.0 && bandJaccardFloor < 0.80,
            'bandJaccardFloor must be in [0.0, 0.80)'),
        assert(
            // `??` is required: in this init-list position
            // `candidateObservationFloor` refers to the nullable PARAMETER
            // (init-list scoping — parameters shadow fields), not the
            // non-null field of the same name. `int? >= int` is a compile
            // error under null safety.
            (candidateObservationFloor ?? (provisionalCaptures + 1)) >= 0,
            'candidateObservationFloor must be >= 0'),
        assert(provisionalCaptures >= 1, 'provisionalCaptures must be >= 1');
}
