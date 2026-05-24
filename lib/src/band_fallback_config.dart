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
///
/// **Null-sentinel contract**: passing `null` for
/// [BandFallbackConfig.spatialConfirm] tells the engine to substitute its
/// built-in drift-aware default at construction time
/// (`overlapRatio >= 0.80` against the candidate's space-keyed drift
/// margin). A non-null value is used as-is.
///
/// **Type-vs-capability note**: the parameters are typed [TrackedBlock]
/// for symmetry with the engine's other public predicates, but consumers
/// who need `observationCount` (or other [ObservableBlock] fields) can
/// downcast safely — every block reaching this predicate flows through
/// the engine's typed pipeline and is an `ObservableBlock<P>` at runtime.
/// The downcast idiom:
/// ```dart
/// (fresh, candidate) {
///   final freshObs = fresh as ObservableBlock<MyPos>;
///   final candObs = candidate as ObservableBlock<MyPos>;
///   return candObs.observationCount > 5 && myOverlap(freshObs, candObs);
/// }
/// ```
///
/// **Throwing contract**: predicates must not throw. If a consumer
/// predicate does throw, the engine wraps the error in a
/// [BandPredicateException] and rethrows out of `stabilize()` — predicate
/// failures are surfaced, not swallowed.
typedef BandSpatialPredicate = bool Function(
    TrackedBlock fresh, TrackedBlock candidate);

/// Thrown when a consumer-supplied [BandSpatialPredicate] raises an
/// exception during band-relaxed candidate evaluation inside
/// `StabilizationEngine.stabilize`. The engine catches the predicate's
/// error and rewraps it so consumers can distinguish predicate failures
/// from engine-internal errors:
///
/// ```dart
/// try {
///   engine.stabilize(...);
/// } on BandPredicateException catch (e) {
///   // your predicate threw — fix it
/// }
/// ```
///
/// [cause] preserves the original exception; [predicateStackTrace]
/// preserves the original predicate call-site stack so debugging is
/// not lost when this gets rethrown.
// `implements` (not `extends Error`) is intentional: extending Error would
// capture a new stack at construction time, discarding the predicate's
// original call-site trace that we want to surface.
class BandPredicateException implements Exception {
  /// The exception the consumer's predicate raised.
  final Object cause;

  /// Stack trace captured at the predicate call site. Named
  /// `predicateStackTrace` (not just `stackTrace`) so it doesn't shadow
  /// the `e.stackTrace` convention from `on X catch (e, s)` — the `s`
  /// parameter there is the rethrow-site stack provided by the runtime,
  /// which is a different (and complementary) trace.
  final StackTrace predicateStackTrace;

  /// Construct from the captured cause + predicate stack. Asserts the
  /// recursive-wrapping invariant: if a `BandPredicateException` ends up
  /// as someone else's cause, that's an engine bug or a re-entrant
  /// predicate call — fail loud in debug rather than nest silently.
  BandPredicateException(this.cause, this.predicateStackTrace)
      : assert(
            cause is! BandPredicateException,
            'cause must not itself be a BandPredicateException — '
            'double-wrapping indicates a re-entrant predicate or engine bug');

  /// Human-readable message. Mirrors [toString] so logging frameworks
  /// that probe `.message` (Sentry, FlutterError.reportError, etc.) get
  /// the same text as `print(e)`.
  String get message => toString();

  @override
  String toString() =>
      'BandPredicateException: consumer-supplied BandSpatialPredicate '
      'threw during band evaluation. Cause: $cause\n'
      'Predicate stack trace:\n$predicateStackTrace';
}

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
