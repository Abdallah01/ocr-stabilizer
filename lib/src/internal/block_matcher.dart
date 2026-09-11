// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// Matching (primary / band-relaxed / nested re-observation), extracted from
// `StabilizationEngine` in #150 with no behaviour change (the differential
// replay harness holds every capture of every committed stream
// byte-identical across the move, band arms included).
//
// The band branch used to reach into `DriftTracker`, `SpaceKey` and
// `OverlapResolver` directly; it now asks a [SpatialEvidence] whether a
// candidate is spatially confirmed, and the two implementations below are
// the engine's drift-aware default and the consumer's own predicate (with
// the `BandPredicateException` rewrap scoped to consumer code only, as
// before).
//
// #143 (primary tie-break) lands here: the primary path keeps the
// highest-Levenshtein candidate with a strict `>`, so two equal scores
// resolve to whichever the index yielded first. A `MatchScore` comparator
// (text score, then spatial agreement, then a stable key) is a behaviour
// change and goes in its own PR with regenerated digests — see the issue.

import '../band_fallback_config.dart';
import '../band_fallback_stats.dart';
import '../drift_tracker.dart';
import '../observation.dart';
import '../overlap_resolver.dart';
import '../spatial_block_index.dart';
import '../text_dedup_utils.dart';
import '../track.dart';

/// The outcome of [BlockMatcher.find] for one fresh block: the cached block it
/// re-observes (null = a new block), and which path found it.
typedef MatchOutcome<T> = ({
  T? match,
  bool wasBandFallback,
  bool wasNestedFragment,
});

/// What the band-relaxed branch needs to know about space: is [candidate]
/// close enough to [fresh] for a weaker text match to be trusted? The
/// matcher never reads drift state itself; an implementation does.
abstract interface class SpatialEvidence {
  /// True when [candidate] is spatially confirmed for [fresh].
  bool confirms(Observation fresh, Observation candidate);
}

/// The engine's default: `overlapRatio >= 0.80` against the candidate's
/// space-keyed drift margin. Engine-internal — a throw from here
/// propagates with its real type so an engine regression is never
/// misattributed as a predicate failure.
final class DriftAwareSpatialEvidence implements SpatialEvidence {
  /// Creates the default evidence over the engine's [resolver] and
  /// [driftTracker].
  const DriftAwareSpatialEvidence({
    required this.resolver,
    required this.driftTracker,
  });

  /// The engine's overlap resolver.
  final OverlapResolver resolver;

  /// The engine's drift tracker (read for the candidate's drift margin).
  final DriftTracker driftTracker;

  @override
  bool confirms(Observation fresh, Observation candidate) =>
      resolver.overlapRatio(
        fresh,
        candidate,
        driftTracker.driftMarginForKey(driftTracker.spaceKeyFor(candidate)),
      ) >=
      0.80;
}

/// A consumer-supplied [BandSpatialPredicate]. Per that typedef's contract
/// predicates must not throw; if one does, the error is surfaced as a
/// typed [BandPredicateException] (a rewrap carrying the predicate's own
/// stack) so the consumer can tell predicate failures from engine errors.
/// No silent swallow. The catch is scoped to the consumer's code only.
final class ConsumerSpatialEvidence implements SpatialEvidence {
  /// Wraps [predicate].
  const ConsumerSpatialEvidence(this.predicate);

  /// The consumer's predicate.
  final BandSpatialPredicate predicate;

  @override
  bool confirms(Observation fresh, Observation candidate) {
    try {
      return predicate(fresh, candidate);
    } catch (error, stack) {
      throw BandPredicateException(error, stack);
    }
  }
}

/// Finds, for one fresh block, the cached block it re-observes.
///
/// Three paths, in order: the PRIMARY whole-string text match (highest
/// Levenshtein among the candidates that clear Lev 0.70 / Jaccard 0.80),
/// the BAND-relaxed match (weaker text floors, gated on observation
/// count and [SpatialEvidence]; only when [band]`.mode != off`), and the
/// NESTED re-observation (#112: a fresh block sitting inside an
/// established block whose text it is a fragment of). Ticks [stats] for
/// the band telemetry counters exactly as the engine did.
class BlockMatcher<T extends Track<Object?>> {
  /// Creates a matcher. [regionCandidates] is the engine's query for the
  /// cached blocks spanning a fresh block's whole rect plus the
  /// viewport-relative namespace (shared with cross-frame supersession);
  /// the nested path scans it for a host.
  BlockMatcher({
    required this.band,
    required this.index,
    required this.stats,
    required this.spatialEvidence,
    required Iterable<T> Function(T fresh) regionCandidates,
  }) : _regionCandidates = regionCandidates;

  /// Band-fallback configuration (`StabilizerConfig.matching.bandFallback`).
  final BandFallbackConfig band;

  /// The engine's spatial index, read for each fresh block's candidates.
  final SpatialIndexView<T> index;

  /// The engine's band counters, ticked by the band branch and the
  /// primary-outcome tally.
  final BandFallbackStatsInternal stats;

  /// Spatial confirmation for the band branch.
  final SpatialEvidence spatialEvidence;

  final Iterable<T> Function(T fresh) _regionCandidates;

  // ┌─── Nested re-observation (#112, 2.2.0) ───────────────────────────
  // An OCR engine's grouping can flip between frames: the same paragraph
  // comes back as one paragraph box in one capture and as one of its own
  // lines in the next. The line's text is a fragment of the paragraph's,
  // so the whole-string primary match fails and the line used to be
  // admitted as a NEW block — the same text tracked twice, drawn as a box
  // inside a box. When a fresh block sits inside an ESTABLISHED block and
  // its text is a fragment of that block's text, it is a re-observation of
  // the block: count up, geometry and text untouched.
  // One-directional on purpose: a fresh paragraph over an established
  // line is the whole-string path's case (from the other side) and is not
  // touched here — see the issue for the symmetric variant's open
  // questions.
  // └────────────────────────────────────────────────────────────────────

  /// Share of the FRESH block's own area that must lie inside the host.
  /// 0.8, measured: an engine's line box is not perfectly nested in its
  /// paragraph box — on the committed on-device ML Kit stream a second
  /// line hangs 3 px below the paragraph's bottom edge (14 of 17 px
  /// inside, 0.82) and a bar of 0.9 left it a separate block. The text
  /// condition is the guard; geometry only has to say "inside, not beside".
  static const double _kNestedContainment = 0.8;

  /// Fragments with fewer significant characters than this never nest —
  /// three characters match inside almost anything.
  static const int _kNestedMinSignificantChars = 4;

  /// Windowed-Levenshtein floor for the fragment against the host's text;
  /// the primary whole-string Levenshtein floor, reused deliberately.
  static const double _kNestedWindowSimilarity = 0.70;

  /// A host must be a cached, non-provisional block seen at least this
  /// many times. ONE on purpose, measured: on the committed on-device
  /// ML Kit dwell stream the grouping flips on consecutive frames, so a
  /// paragraph is re-observed as its own line before it can reach two
  /// observations — a bar of two never fired on the eight pairs the rule
  /// was written for. The geometry (≥ 80 % inside) and text (≥ 0.70
  /// windowed, ≥ 4 significant characters) conditions carry the guard;
  /// provisional hosts are excluded because they are frozen.
  static const int _kNestedEstablishedObservations = 1;

  /// Is [fresh] a nested fragment re-observation of [cached]?
  ///
  /// Geometry first (cheap): [cached] strictly larger, at least
  /// [_kNestedContainment] of the fresh block's area inside it, same
  /// coordinate contract (viewport-relative flag, carousel). Then text:
  /// [TextDedupUtils.bestWindowSimilarity] of the fresh text against the
  /// cached text at or above [_kNestedWindowSimilarity].
  bool isNestedFragmentOf(T fresh, T cached) {
    if (cached.isProvisional) return false;
    if (cached.observationCount < _kNestedEstablishedObservations) {
      return false;
    }
    if (fresh.isViewportRelative != cached.isViewportRelative) return false;
    if (fresh.isHorizontalScrollChild &&
        cached.isHorizontalScrollChild &&
        fresh.scrollContext.hzScrollerIndex !=
            cached.scrollContext.hzScrollerIndex) {
      return false;
    }
    final f = fresh.absoluteRect.raw;
    final c = cached.absoluteRect.raw;
    final freshArea = f.width * f.height;
    final cachedArea = c.width * c.height;
    if (!(freshArea > 0) || !(cachedArea > freshArea)) return false;
    final inter = f.intersect(c);
    if (inter.isEmpty) return false;
    if ((inter.width * inter.height) / freshArea < _kNestedContainment) {
      return false;
    }
    return TextDedupUtils.bestWindowSimilarity(
          fresh.originalText,
          cached.originalText,
          minFragmentChars: _kNestedMinSignificantChars,
        ) >=
        _kNestedWindowSimilarity;
  }

  /// The established block [fresh] is a nested fragment of, or null. When
  /// several qualify (a page-wide block whose text repeats the paragraph,
  /// and the paragraph itself), the TIGHTEST host — smallest area — wins.
  /// Candidates span the fresh block's whole rect plus the
  /// viewport-relative namespace, as for supersession.
  T? findNestedHost(T fresh) {
    T? best;
    var bestArea = double.infinity;
    for (final cached in _regionCandidates(fresh)) {
      if (!isNestedFragmentOf(fresh, cached)) continue;
      final r = cached.absoluteRect.raw;
      final area = r.width * r.height;
      if (area < bestArea) {
        bestArea = area;
        best = cached;
      }
    }
    return best;
  }

  /// Find a matching existing block for [fresh] in the spatial index.
  ///
  /// Single-pass over candidates: scores are computed ONCE per candidate and
  /// evaluated against both primary thresholds (Lev 0.70 / Jaccard 0.80) and
  /// band thresholds ([BandFallbackConfig.bandLevenshteinFloor] /
  /// [BandFallbackConfig.bandJaccardFloor]) in the same iteration.
  ///
  /// Primary path: highest-Levenshtein candidate that clears primary
  /// thresholds wins. Band path (only when [band]`.mode` is not
  /// [BandFallbackMode.off]): first candidate that clears the
  /// observation-count floor, spatial confirm, AND band text floors is
  /// admitted ([BandFallbackMode.admit]) or tallied
  /// ([BandFallbackMode.observeOnly]).
  ///
  /// Nested re-observation (#112): only when BOTH the primary and the band
  /// path miss, a fresh block that is a nested fragment of an established
  /// block ([findNestedHost]) matches that block with `wasNestedFragment`
  /// set, so the merge is a confirming observation only.
  ///
  /// [recordStats] / [allowBandFallback] / [allowNestedFallback] (#116,
  /// finding A fix): the DRY pre-pass `stabilize` runs to feed the
  /// coherent-shift detector a full-capture snapshot calls this with all
  /// three `false`. That pre-pass must never mutate [stats] (the REAL,
  /// interleaved call ticks every counter exactly once per fresh block)
  /// and must never evaluate the band branch (whose [spatialEvidence]
  /// reads drift state that earlier same-capture merges mutate — only the
  /// PRIMARY check, which reads the this-capture-immutable index and text
  /// scores, is safe to run ahead of the capture's merges). Skipping the
  /// nested lookup too is a pure perf saving: the detector discards
  /// `wasNestedFragment` matches. Every default reproduces the
  /// single-mode behaviour exactly.
  MatchOutcome<T> find(
    T fresh, {
    bool recordStats = true,
    bool allowBandFallback = true,
    bool allowNestedFallback = true,
  }) {
    final candidates = index.candidates(fresh);
    final shouldRunBand =
        allowBandFallback && band.mode != BandFallbackMode.off;

    T? primaryMatch;
    // Seeded below any reachable score so a candidate admitted purely via
    // the Jaccard arm with Levenshtein 0.0 (e.g. short reordered CJK,
    // "北京" vs "京北") still registers as the primary match instead of
    // being silently dropped by the strict `>` comparison.
    double bestPrimarySim = -1.0;
    T? bandAdmitted;

    for (final candidate in candidates) {
      if (candidate.isViewportRelative != fresh.isViewportRelative) continue;

      // Compute scores ONCE per candidate — used by both the primary check
      // (Lev 0.70 OR Jaccard 0.80, engine-owned defaults) and the band check
      // (band floors from config, tested directly against the same scores).
      final scores = TextDedupUtils.isTextSimilarWithScores(
        fresh.originalText,
        candidate.originalText,
      );

      // ── Primary check ──
      if (scores.match) {
        // Pick the highest Lev-scoring candidate (Jaccard is a parallel
        // metric for admission, not a primary ordering signal). Strict
        // `>`: equal scores keep the first candidate the index yielded
        // (#143 — the tie-break comparator goes here).
        if (scores.levenshtein > bestPrimarySim) {
          bestPrimarySim = scores.levenshtein;
          primaryMatch = candidate;
        }
        // Primary hit — this candidate is not a band candidate.
        continue;
      }

      // ── Band check (primary missed for this candidate) ──
      if (!shouldRunBand) continue;
      // admit mode: once a band candidate is locked, later candidates still
      // need their primary check (done above via continue), but we skip
      // redundant band evaluation — the first qualifying admit wins.
      if (band.mode == BandFallbackMode.admit && bandAdmitted != null) {
        continue;
      }

      stats.recordCandidateConsidered();

      if (candidate.observationCount < band.candidateObservationFloor) {
        stats.recordRejectedCandidateFloor();
        continue;
      }
      if (!spatialEvidence.confirms(fresh, candidate)) {
        stats.recordRejectedSpatial();
        continue;
      }
      // Test the same scores against the band thresholds directly — avoids a
      // second isTextSimilarWithScores call. Semantically equivalent to
      // calling isTextSimilarWithScores with levenshteinThreshold: bandLev,
      // jaccardThreshold: bandJacc (OR logic mirrors the primary check).
      final bandMatches = scores.levenshtein >= band.bandLevenshteinFloor ||
          scores.jaccard >= band.bandJaccardFloor;
      if (!bandMatches) {
        stats.recordRejectedTextBand();
        continue;
      }
      stats.recordBandMatchIdentified();
      if (band.mode == BandFallbackMode.admit) {
        bandAdmitted = candidate;
        // recordMatchAdmitted() is deferred to the resolution block below
        // so it reflects "match actually returned" rather than
        // "candidate locked for band admission". This matters when a
        // later primary candidate in the same scan supersedes a band
        // candidate locked earlier (#34 T2): without the deferral,
        // matchesAdmitted would overcount and disagree with the
        // function's return value.
      }
      // observeOnly: keep scanning so all candidates contribute to counters.
    }

    // ── Tally primary outcome ──
    if (primaryMatch != null) {
      if (recordStats) stats.recordPrimaryMatchAdmitted();
      return (
        match: primaryMatch,
        wasBandFallback: false,
        wasNestedFragment: false,
      );
    }
    // Tick on every primary miss, including empty-candidate-set cases.
    // Holds the spec invariant:
    //   primaryMatchesAdmitted + primaryMatchesRejected
    //     == total fresh observations that reached find().
    // Consumers compute "band fires as % of primary misses" as
    // `bandMatchesIdentified / primaryMatchesRejected` — undercounting
    // here would skew that ratio. (Gated on [recordStats] — the dry
    // pre-pass calls this with `recordStats: false` and must not tick it;
    // the real, interleaved call always passes the default `true`.)
    if (recordStats) stats.recordPrimaryMatchRejected();

    // ── Return band outcome ──
    if (shouldRunBand && bandAdmitted != null) {
      stats.recordMatchAdmitted();
      return (
        match: bandAdmitted,
        wasBandFallback: true,
        wasNestedFragment: false,
      );
    }

    if (!allowNestedFallback) {
      return (match: null, wasBandFallback: false, wasNestedFragment: false);
    }

    // ── Nested re-observation (#112): primary AND band missed ──
    // Counted as a primary rejection above on purpose: the band ratio
    // consumers compute (`bandMatchesIdentified / primaryMatchesRejected`)
    // keeps its denominator; this is a separate, later rule.
    final host = findNestedHost(fresh);
    if (host != null) {
      return (match: host, wasBandFallback: false, wasNestedFragment: true);
    }
    return (match: null, wasBandFallback: false, wasNestedFragment: false);
  }
}
