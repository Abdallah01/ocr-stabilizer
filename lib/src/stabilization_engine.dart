// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'dart:math' show max;
import 'types/geometry.dart' show Offset;

import 'band_fallback_config.dart';
import 'band_fallback_stats.dart';
import 'block_key.dart';
import 'coherent_shift_event.dart';
import 'drift_tracker.dart';
import 'hierarchy_weight.dart';
import 'identity_turnover.dart';
import 'internal/block_geometry.dart';
import 'internal/coherent_shift_detector.dart';
import 'internal/position_merger.dart';
import 'internal/retention_manager.dart';
import 'internal/transform_estimator.dart';
import 'internal/batch_dedup.dart';
import 'internal/block_matcher.dart';
import 'internal/contradiction_detector.dart';
import 'internal/confidence_validation.dart';
import 'merge_result.dart';
import 'track.dart';
import 'overlap_resolver.dart';
import 'spatial_block_index.dart';
import 'stabilization_result.dart';
import 'step_response.dart';
import 'stabilizer_config.dart';
import 'submap_membership.dart';
import 'text_dedup_utils.dart';
import 'text_vote.dart';
import 'observation.dart';
import 'types/absolute_rect.dart';
import 'types/confidence_types.dart';
import 'types/space_key.dart';

/// How the engine merges an existing block's position with a fresh
/// drift-corrected observation, and how merged position confidence is
/// derived (#58).
///
/// Selected via `StabilizationEngine(positionMergeModel: ...)`. The
/// default is [agreementWeighted] since 1.0 (#74 flip: the #58 regime
/// matrix plus the consumer final gate — paired same-stream ab-report on
/// two current consumer captures — showed equal young-block tracking,
/// halved established-block displacement, and informative confidence).
/// [legacy] preserves the 0.x numerics exactly and remains selectable:
/// consumers who tuned against 0.x confidence values (which saturate to
/// 1.0) should pin it until they re-validate.
enum PositionMergeModel {
  /// 0.x numerics, preserved exactly.
  ///
  /// Merge weight is the confidence ratio `fresh / (existing + fresh)`
  /// and merged confidence is the clamped sum
  /// `min(existing + fresh, 1.0)`. Two consequences the audit flagged
  /// (§1.7): confidence saturates to 1.0 after two ~0.5-confidence
  /// observations regardless of positional agreement, and the merge
  /// weight never decays — a long-observed block still moves ~33%
  /// toward every noisy rect, so jitter never fully damps.
  legacy,

  /// Agreement-weighted model — the 1.0 default.
  ///
  /// The merge weight anchors existing confidence by the block's
  /// `observationCount` (`fresh / (existing·n + fresh)`), so
  /// long-observed blocks become positionally sticky while young blocks
  /// still adapt quickly. Merged confidence is a running mean of
  /// positional *agreement* — how close each corrected observation
  /// lands to the tracked position, scaled by the block's own jitter
  /// allowance (3x the tracked block's height since 1.1 (#75); 3x the
  /// region-median height through 1.0.x — both sweep-validated on
  /// production captures, see #58/#75) — so
  /// disagreeing observations reduce confidence instead of saturating
  /// it, and `OverlapResolver.qualityScore`'s position term becomes
  /// informative again for well-observed blocks.
  agreementWeighted,
}

/// Well-observed threshold: blocks with this many observations signal
/// translation stability to the consumer.
const int _kWellObservedThreshold = 3;

/// Maximum text vote entries per block to prevent OOM on noisy edges.
const int _kMaxTextVotes = 5;

/// Core stabilization engine: answers "is this block the same as that block,
/// and what are its corrected coordinates?"
///
/// The engine owns SAR merge, dedup, drift propagation, and contradiction
/// detection. The app owns cache management (LRU, TTL, staging, UI).
///
/// Timing contract: render at first sight, refine on re-sight. A
/// first-sighting block is returned in [StabilizationResult.stableBlocks]
/// on the very [stabilize] call that observed it — observation counts are
/// evidence depth for position refinement and caching hints, never a
/// readiness gate.
///
/// ## Lifecycle
///
/// One engine instance serves ONE continuous visual session. Construction
/// is cheap; at a document boundary (navigation, content-source switch, a
/// layout-root change that makes identity continuity meaningless)
/// construct a fresh engine rather than reusing the old one: miss-count
/// retention and drift-propagation state carry the previous document
/// forward, and only [resetDriftPropagation] is individually resettable
/// today. Discard consumer-owned state at the same boundary — text votes
/// and observation history live on the consumer's [Observation]s, and
/// the shared [driftTracker] is the consumer's to reset or keep. Whether
/// an engine-wide reset() should exist instead is issue #95.
///
/// Generic parameters:
/// - [T] — the track type (must implement [Track<P>]); a fresh block is a
///   track at its first observation, and the engine only ever reads the
///   [Observation] half of a fresh one
/// - [P] — opaque payload type carried by the block
class StabilizationEngine<T extends Track<P>, P> {
  final BlockMerger<T, P> _merger;

  /// Every lever of this engine, grouped by stage (#149). The public
  /// getters below (`bandFallback`, `missedFrameRetention`,
  /// `coherentShiftMinBlocks`, …) report the EFFECTIVE values read from it
  /// and carry each lever's measured history.
  final StabilizerConfig config;

  /// Drift tracker shared with the app (the app may also feed observations).
  final DriftTracker driftTracker;

  /// The coherent-shift detector (#116/#119; its own class since #150).
  /// One per engine, over [config]'s coherent-shift levers and
  /// [driftTracker]; `stabilize` asks it for a plan only under
  /// [StepResponse.coherentShift] with the agreement-weighted model.
  late final CoherentShiftDetector<T> _coherentShiftDetector =
      CoherentShiftDetector<T>(
    config: config.stepResponse.coherentShift,
    driftTracker: driftTracker,
  );

  /// Spatial index rebuilt by the engine on each [stabilize] call; the app
  /// may query it between calls for rendering lookups.
  ///
  /// Read-only since 2.0.0 (#96): the historical "known seam" — a public
  /// mutable field whose `add(...)` bypassed the confidence-validation
  /// guards on [stabilize] and [merge] — is closed. Consumers holding
  /// only the engine can query, never mutate. Mutation remains available
  /// to whoever CONSTRUCTED the index and injected it through the engine
  /// constructor (the test-fixture pre-seeding pattern); the injector owns
  /// mutation and with it the guarded-construction responsibility
  /// (`PositionConfidence.from` / `TextConfidence.from`, or
  /// [DefaultTrackedBlock]'s validating constructor).
  SpatialIndexView<T> get spatialIndex => _spatialIndex;
  final SpatialBlockIndex<T> _spatialIndex;

  /// Optional context-change detector. When non-null, the engine calls this
  /// to determine if a fresh block's context has changed relative to the
  /// existing cached block (e.g. group signature changed). A `true` return
  /// triggers translation invalidation.
  final bool Function(T fresh, T existing)? _contextualCheck;

  /// Band-fallback configuration. Default: disabled (`mode: off`).
  final BandFallbackConfig bandFallback;

  /// Engine-side mutable counter surface. Exposed publicly via [bandStats]
  /// as the read-only supertype.
  final BandFallbackStatsInternal _internalStats = BandFallbackStatsInternal();

  /// Read-only counter view for the matching path. See [BandFallbackStats]
  /// for the per-counter semantics.
  BandFallbackStats get bandStats => _internalStats;

  /// The matcher (primary / band / nested; its own class since #150). One
  /// per engine, over [bandFallback], the spatial index, the band counters
  /// and — for the band branch's spatial confirmation — either the
  /// consumer's [BandFallbackConfig.spatialConfirm] (wrapped so a throw
  /// surfaces as [BandPredicateException]) or the engine's drift-aware
  /// default (`overlapRatio >= 0.80` against the candidate's space-keyed
  /// drift margin, whose own errors propagate with their real type).
  late final BlockMatcher<T> _matcher = BlockMatcher<T>(
    band: bandFallback,
    index: _spatialIndex,
    stats: _internalStats,
    spatialEvidence: switch (bandFallback.spatialConfirm) {
      null => DriftAwareSpatialEvidence(
          resolver: _resolver, driftTracker: driftTracker),
      final predicate => ConsumerSpatialEvidence(predicate),
    },
    regionCandidates: _retention.regionCandidates,
  );

  /// The position merger (weight, step response, lerp, confidence; its
  /// own class since #150) over [positionMergeModel], [stepResponse] and
  /// [snapThresholdMultiplier].
  /// Missed-frame retention + cross-frame supersession (its own class
  /// since #150) over [missedFrameRetention], the spatial index and the
  /// resolver; also the region query the matcher's nested path uses.
  /// The batch dedup pipeline (noise filter, key dedup, intra-batch NMS;
  /// its own class since #150). Its per-batch grid feeds the grouping
  /// contradiction scan (#55).
  late final BatchDedup<T> _batchDedup = BatchDedup<T>(
    index: _spatialIndex,
    resolver: _resolver,
    driftTracker: driftTracker,
  );

  /// Grouping / splitting contradiction detection (#49; its own class
  /// since #150) over the spatial index. [detectGroupingContradictions]
  /// and [detectSplittingContradictions] stay public and delegate.
  late final ContradictionDetector<T> _contradictions =
      ContradictionDetector<T>(index: _spatialIndex);

  late final RetentionManager<T> _retention = RetentionManager<T>(
    missedFrames: missedFrameRetention,
    index: _spatialIndex,
    resolver: _resolver,
  );

  late final PositionMerger<T> _positionMerger = PositionMerger<T>(
    model: positionMergeModel,
    stepResponse: stepResponse,
    snapThresholdMultiplier: snapThresholdMultiplier,
  );

  /// Creates a stabilization engine. The [merger] callback constructs an
  /// updated block from engine-computed merge data.
  ///
  /// Throws [ArgumentError] if [bandFallback] violates any invariant. This
  /// mirrors the `BandFallbackConfig` constructor's `assert`-only checks with
  /// a release-build `throw`, so a misconfigured engine fails fast at
  /// construction rather than producing surprising behavior later.
  /// ([BandFallbackConfig] uses `assert` to stay `const`-capable; the engine
  /// ctor is non-const, so a `throw` here is free.)
  StabilizationEngine({
    required BlockMerger<T, P> merger,
    DriftTracker? driftTracker,
    SpatialBlockIndex<T>? spatialIndex,
    SubmapMembership? submapMembership,
    bool Function(T fresh, T existing)? contextualCheck,
    this.config = const StabilizerConfig(),
  })  : _merger = merger,
        bandFallback = config.matching.bandFallback,
        missedFrameRetention = config.retention.missedFrames,
        positionMergeModel = config.merge.positionModel,
        stepResponse = config.stepResponse.mode,
        snapThresholdMultiplier = config.stepResponse.snapThresholdMultiplier,
        coherentShiftMinBlocks = config.stepResponse.coherentShift.minBlocks,
        coherentShiftMinShare = config.stepResponse.coherentShift.minShare,
        coherentShiftTolerance = config.stepResponse.coherentShift.tolerance,
        coherentShiftFloorPx =
            config.stepResponse.coherentShift.experimental.floorPx,
        coherentShiftReanchorMinBlocks =
            config.stepResponse.coherentShift.experimental.reanchorMinBlocks,
        coherentShiftAdoptAgreeing =
            config.stepResponse.coherentShift.adoptAgreeing,
        transformEstimateMinPairs =
            config.diagnostics.transformEstimateMinPairs,
        driftTracker =
            driftTracker ?? DriftTracker(submapMembership: submapMembership),
        _spatialIndex = spatialIndex ?? SpatialBlockIndex<T>(),
        _contextualCheck = contextualCheck {
    _validateBandFallbackConfig(bandFallback);
    if (missedFrameRetention < 0) {
      throw ArgumentError(
        'missedFrameRetention must be >= 0 (got $missedFrameRetention). '
        '0 disables retention; N keeps a not-re-observed block matchable '
        'for N further stabilize() calls.',
      );
    }
    _validateStepResponseConfig(
      snapThresholdMultiplier: snapThresholdMultiplier,
      coherentShiftMinBlocks: coherentShiftMinBlocks,
      coherentShiftMinShare: coherentShiftMinShare,
      coherentShiftTolerance: coherentShiftTolerance,
      coherentShiftFloorPx: coherentShiftFloorPx,
      coherentShiftReanchorMinBlocks: coherentShiftReanchorMinBlocks,
    );
    // #135: an integer COUNT, same class as `coherentShiftMinBlocks` —
    // below 3 `TransformEstimate.fit` refuses the floor: two pairs fit
    // any similarity exactly (residual 0, an arbitrary scale), so a
    // residual gate would have nothing to read.
    if (transformEstimateMinPairs < 3) {
      throw ArgumentError.value(
        transformEstimateMinPairs,
        'transformEstimateMinPairs',
        'must be >= 3 — two pairs fit any similarity exactly',
      );
    }
  }

  /// The fewest eligible matched pairs a capture needs before
  /// `StabilizationResult.transformEstimate` is reported (2.6.0, #135).
  /// Default 3. Eligibility is the coherent-shift detector's: ordinary
  /// primary matches only. Below the floor the result carries `null`
  /// rather than a fit over too few anchors. Must be >= 3 (two pairs fit
  /// any similarity exactly; the third is what a residual reads).
  final int transformEstimateMinPairs;

  /// How many consecutive [stabilize] calls a tracked block survives in
  /// [spatialIndex] without being re-observed (#46).
  ///
  /// `0` (the default) preserves the pre-0.6.0 behavior: the index is
  /// rebuilt from each call's `stableBlocks` only, so a block missed for
  /// a single capture (OCR glare, occlusion) loses its identity and
  /// re-enters as new. With `N > 0`, a missed block stays in the index as
  /// a match candidate for up to N calls; re-observation within the
  /// window merges into its accumulated history and resets the counter,
  /// and expiry evicts it. Retained blocks are **not** included in
  /// [StabilizationResult.stableBlocks] — the result remains "what this
  /// capture produced"; retention only affects future matching.
  ///
  /// Since 2.1.0 a retained block is also evicted early when one fresh
  /// block of THIS capture covers at least half of the retained block's
  /// own area without matching it (the resolver's per-script NMS
  /// threshold applies only where it is stricter, e.g. short Latin
  /// snippets): the region has visibly changed, and keeping the old box
  /// would have a consumer of the tracked state draw it on top of the new
  /// one for the rest of the window. This is a deliberate trade of
  /// identity for a clean frame — a wrongly placed fresh block (a lagged
  /// scroll stamp on the producer's side) evicts a correct retained one,
  /// which then re-enters as new. Blocks from different carousels, and
  /// viewport-relative vs page-absolute blocks, never supersede each
  /// other. With retention 0 nothing is retained, so default-configuration
  /// behavior is unchanged.
  final int missedFrameRetention;

  /// Position merge model (#58). Default [PositionMergeModel.agreementWeighted]
  /// since 1.0 (#74 flip, validated against production captures); pass
  /// [PositionMergeModel.legacy] to preserve the 0.x numerics exactly.
  final PositionMergeModel positionMergeModel;

  /// How the engine reacts to a residual far outside a block's normal
  /// jitter allowance (#116). Default [StepResponse.coherentShift] since
  /// 2.3.0 (the 17-stream A/B: 14/17 vs [StepResponse.snap]'s 11/17, zero
  /// false-triggered step events on any control stream — see
  /// `doc/replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md`'s "Step
  /// response A/B" section). Pass [StepResponse.damp] to restore the
  /// pre-2.3.0 numerics exactly. See [StepResponse] for [snap] and
  /// [coherentShift]'s own semantics, including the two documented blind
  /// spots tracked as #119.
  final StepResponse stepResponse;

  /// [StepResponse.snap] fires when a merge's residual exceeds this
  /// multiple of the block's own agreement scale (3x its own height, the
  /// same scale [PositionMerger.mergedConfidence] uses). Default `1.5` — half
  /// again the scale that already reads as full disagreement (residual ==
  /// scale scores agreement 0), so snap only fires on a residual the
  /// agreement math already treats as pure noise rather than partial
  /// jitter. Only meaningful under [PositionMergeModel.agreementWeighted]
  /// and [StepResponse.snap] — see [StepResponse]'s doc for the no-op
  /// under [PositionMergeModel.legacy].
  final double snapThresholdMultiplier;

  /// [StepResponse.coherentShift] requires an agreeing group of at least
  /// this many matched pairs before it treats their shared displacement as
  /// a batch shift. Default `3` — the #116 corpus measured pairs moving
  /// together in the dozens; three agreeing pairs is a low, sweep-friendly
  /// floor a consumer can raise for a noisier corpus.
  final int coherentShiftMinBlocks;

  /// [StepResponse.coherentShift] requires the agreeing group to be at
  /// least this share of ALL moved pairs in the batch (pairs whose
  /// residual exceeds their own agreement scale) — a group that is
  /// technically the largest but still a minority of what moved is more
  /// likely several small independent shifts than one coherent layout
  /// step. Default `0.5`.
  ///
  /// Neither #119 opt-in fallback applies this gate — that is their point:
  /// with [coherentShiftFloorPx] or [coherentShiftReanchorMinBlocks] set, a
  /// minority cluster CAN be re-anchored (its own members only) where the
  /// quorum would have damped it. Both are `null` by default, so the gate
  /// above is the whole story for the 2.3.0 configuration.
  final double coherentShiftMinShare;

  /// [StepResponse.coherentShift] clustering tolerance: a moved pair
  /// joins a candidate group when its displacement is within this
  /// multiple of `min(the pair's own block height, the candidate
  /// group's median block height)` of the group's median displacement
  /// (#116 finding B, 2026-08-29: reworded from a pairwise "smaller of
  /// the two blocks' heights" comparison — the algorithm has always
  /// compared a candidate against a GROUP, never against one other pair,
  /// so this now says what the code does). Default `0.5`. See
  /// `CoherentShiftDetector.detect` for the exact clustering algorithm.
  final double coherentShiftTolerance;

  /// #119 — the ABSOLUTE-PIXEL floor that admits a large-slab mover the
  /// two count gates structurally cannot see. `null` (the default)
  /// disables it, reproducing 2.3.0 behaviour bit-for-bit.
  ///
  /// [StepResponse.coherentShift]'s quorum
  /// ([coherentShiftMinBlocks] / [coherentShiftMinShare]) reasons over the
  /// pairs that survived the PRIMARY SPATIAL MATCH. A single-frame slab
  /// big enough to push most lines out of the viewport is exactly the case
  /// that starves it: the lines that truly moved are admitted as NEW
  /// identities (no match, so no residual to vote with), and the one or
  /// two stragglers that do still match cannot reach
  /// [coherentShiftMinBlocks]. `CoherentShiftDetector.detect` then returns before
  /// it ever clusters, and the whole capture falls through to
  /// [StepResponse.damp] — measured, not inferred: on the validation
  /// corpus's 600px-slab stream the reflow capture leaves exactly ONE
  /// matched mover behind (12 eligible pairs, 10 unmatched admissions).
  ///
  /// When set, any moved pair whose drift-corrected displacement is at
  /// least this many pixels is admitted to the vote on its own magnitude,
  /// bypassing BOTH count gates and the [coherentShiftMinShare] gate.
  /// Floor-qualified movers must still agree in DIRECTION with each other
  /// (a slab translates its content one way; two movers heading opposite
  /// ways are not a shift and the median of their displacements is a
  /// translation neither made) AND in MAGNITUDE: they are clustered with
  /// the same tolerance rule as the quorum ([coherentShiftTolerance] x
  /// block height), a lone mover being its own cluster, and only the
  /// largest cluster is re-anchored, by its own median (PR #129 review
  /// C1). Every other pair in the batch — including a floor-qualified
  /// mover outside that cluster — damps exactly as before, so no member
  /// is ever re-anchored by a translation it did not make.
  ///
  /// The one exception is [coherentShiftAdoptAgreeing] (#119 item 2, on
  /// by default since 2.4.0): with it on, an under-gate pair whose
  /// displacement agrees with the decided cluster median (within the
  /// quorum's own tolerance) is carried along as well — still never a
  /// translation it did not, to within that tolerance, make. Off, the
  /// paragraph above is the whole story.
  ///
  /// **Why an absolute floor and not another height-relative multiplier.**
  /// A multiple of the block's own agreement scale ([agreementScale], 3x
  /// its height) cannot separate these two populations, because a SHORT
  /// block has a small scale and therefore reaches a high ratio at a
  /// modest absolute displacement. On the validation corpus the slab's
  /// surviving mover travels 406px at only 2.64x its own scale, while a
  /// continuous-scroll control stream's ordinary motion reaches 3.63x at
  /// 360px — the control out-ranks the real slab, so NO multiplier
  /// admits one without the other (measured in #119; that is why the
  /// earlier height-relative attempt was abandoned). Absolute pixels
  /// order the two populations correctly. The corollary is that this
  /// value is a PROPERTY OF THE CAPTURE GEOMETRY, not a universal
  /// constant: it must be at least the largest displacement ordinary
  /// scrolling produces between two consecutive captures on the
  /// consumer's own device and capture cadence, and below the smallest
  /// slab worth tracking. A consumer that captures less often, or scrolls
  /// faster, needs a higher floor. Leaving it `null` is always safe.
  final double? coherentShiftFloorPx;

  /// #119 — relax [StepResponse.coherentShift]'s quorum on the COUNT axis
  /// instead of the magnitude one. `null` (the default) disables it,
  /// reproducing 2.3.0 behaviour bit-for-bit.
  ///
  /// When set, and the ordinary quorum has declined, the same tolerance
  /// clustering runs again at this (lower) minimum size with the
  /// [coherentShiftMinShare] gate dropped entirely; the winning cluster's
  /// median displacement is applied to ITS OWN MEMBERS ONLY, leaving every
  /// other pair in the batch on [StepResponse.damp] — except, with
  /// [coherentShiftAdoptAgreeing] on (#119 item 2, the default since
  /// 2.4.0), an under-gate pair that agrees with the winning cluster's
  /// median, which is adopted for this fallback exactly as for the quorum.
  ///
  /// Unlike [coherentShiftFloorPx] this lever has no magnitude axis at
  /// all — it acts on agreement and quantity. That is also its measured
  /// weakness on the validation corpus, and the reason it is documented
  /// rather than recommended: the starved-quorum case is starved all the
  /// way down to ONE surviving mover, so only a value of 1 reaches it —
  /// and a single mover is equally what ordinary scroll and OCR jitter
  /// produce on the control streams, which then false-fire. Any value
  /// above 1 leaves the large-slab case exactly where it was. The count
  /// axis cannot separate the two populations; see
  /// [coherentShiftFloorPx], which can. Prefer it, and reach for this
  /// only where a consumer's own corpus shows large slabs that reliably
  /// leave several matched movers behind.
  final int? coherentShiftReanchorMinBlocks;

  /// #119 item 2 — once a coherent shift IS decided (by the quorum, the
  /// floor fallback or the re-anchor fallback), also carry along the
  /// matched pairs that sat UNDER the "moved" gate but agree with the
  /// decided translation. `true` (the default since 2.4.0; the 17-stream
  /// A/B measured 16 streams byte-identical, every control included, and
  /// the one affected stream strictly better — pushdown-150 lag at the
  /// move 68.3 -> 6.0 px, identity 0.821 -> 0.929). Pass `false` to
  /// reproduce 2.3.x numerics bit-for-bit.
  ///
  /// The "moved" gate is a multiple of each block's OWN height
  /// ([agreementScale], 3x): a 150 px slab step carries a 36 px line past
  /// its gate (108 px) but not a 60 px line past its gate (180 px). On the
  /// measured 150 px pushdown capture three short movers therefore form a
  /// valid group while 13 taller pairs that made the SAME step stay under
  /// their gate and damp — the translation reaches 3 of the 16 pairs that
  /// moved together, and the rest lag by the damped fraction.
  ///
  /// This lever does not touch who may VOTE (the gate, the quorum and the
  /// fallbacks are exactly as they were) or what the vote is; it widens who
  /// FOLLOWS a vote that was reached anyway. An eligible pair (the same
  /// filters as the movers — not provisional, not a band or nested match,
  /// not viewport-relative, not a carousel child) whose displacement is
  /// within `coherentShiftTolerance x min(its own height, the group's
  /// median height)` — the quorum's own clustering rule — of the decided
  /// translation is added to the group's members and merged with the
  /// translation applied, exactly like a voter. A capture where no group
  /// forms is untouched by construction, which is why a control stream
  /// that never fires cannot change under it.
  final bool coherentShiftAdoptAgreeing;

  /// Validate [BandFallbackConfig] invariants with release-safe [ArgumentError].
  ///
  /// [BandFallbackConfig] uses `assert` (debug-only, stripped in release) to
  /// remain `const`-capable. This static helper re-checks those same invariants
  /// with `throw` so production builds fail fast at engine construction time
  /// rather than producing unexpected behavior (e.g. a floor of `>= 0.70`
  /// that silently makes band admission unreachable, or `provisionalCaptures: 0`
  /// violating the `MergeResult` invariant that `isProvisional` implies
  /// `provisionalCapturesRemaining > 0`).
  static void _validateBandFallbackConfig(BandFallbackConfig cfg) {
    // IEEE 754 quirk: both `NaN < 0.0` and `NaN >= 0.70` are false, so the
    // range check alone lets NaN slip past in release builds (where the
    // const-ctor assert is stripped). Mirror the `Confidence.from`
    // hardening from #27 by short-circuiting on `!isFinite` first.
    if (!cfg.bandLevenshteinFloor.isFinite ||
        cfg.bandLevenshteinFloor < 0.0 ||
        cfg.bandLevenshteinFloor >= 0.70) {
      throw ArgumentError.value(
        cfg.bandLevenshteinFloor,
        'bandLevenshteinFloor',
        'must be a finite value in [0.0, 0.70)',
      );
    }
    if (!cfg.bandJaccardFloor.isFinite ||
        cfg.bandJaccardFloor < 0.0 ||
        cfg.bandJaccardFloor >= 0.80) {
      throw ArgumentError.value(
        cfg.bandJaccardFloor,
        'bandJaccardFloor',
        'must be a finite value in [0.0, 0.80)',
      );
    }
    if (cfg.candidateObservationFloor < 0) {
      throw ArgumentError.value(
        cfg.candidateObservationFloor,
        'candidateObservationFloor',
        'must be >= 0',
      );
    }
    if (cfg.provisionalCaptures < 1) {
      throw ArgumentError.value(
        cfg.provisionalCaptures,
        'provisionalCaptures',
        'must be >= 1',
      );
    }
  }

  /// Validate the #116 [StepResponse] tunables with release-safe
  /// [ArgumentError], the same treatment [_validateBandFallbackConfig] gives
  /// [BandFallbackConfig].
  ///
  /// Two failure classes matter here specifically because they are SILENT
  /// rather than merely permissive: a non-finite [snapThresholdMultiplier]
  /// or [coherentShiftTolerance] makes every downstream comparison false
  /// (the same IEEE-754 hazard `_validateBandFallbackConfig`'s own comment
  /// documents), so the option looks configured but its `StepResponse`
  /// permanently never fires; a [coherentShiftMinBlocks] < 1 makes the
  /// winning group's own size gate (`bestGroup.length < coherentShiftMinBlocks`)
  /// permanently false, i.e. unreachable rather than merely lenient.
  static void _validateStepResponseConfig({
    required double snapThresholdMultiplier,
    required int coherentShiftMinBlocks,
    required double coherentShiftMinShare,
    required double coherentShiftTolerance,
    required double? coherentShiftFloorPx,
    required int? coherentShiftReanchorMinBlocks,
  }) {
    if (!snapThresholdMultiplier.isFinite || snapThresholdMultiplier <= 0.0) {
      throw ArgumentError.value(
        snapThresholdMultiplier,
        'snapThresholdMultiplier',
        'must be a finite double > 0',
      );
    }
    if (coherentShiftMinBlocks < 1) {
      throw ArgumentError.value(
        coherentShiftMinBlocks,
        'coherentShiftMinBlocks',
        'must be >= 1',
      );
    }
    if (!coherentShiftMinShare.isFinite ||
        coherentShiftMinShare < 0.0 ||
        coherentShiftMinShare > 1.0) {
      throw ArgumentError.value(
        coherentShiftMinShare,
        'coherentShiftMinShare',
        'must be a finite value in [0.0, 1.0]',
      );
    }
    if (!coherentShiftTolerance.isFinite || coherentShiftTolerance < 0.0) {
      throw ArgumentError.value(
        coherentShiftTolerance,
        'coherentShiftTolerance',
        'must be a finite value >= 0.0',
      );
    }
    // #119: same silent-NaN class as the four above — an unchecked NaN
    // floor makes `displacement >= floor` permanently false, so the
    // option would look configured while never firing. `null` is exempt
    // by design: that is the documented disabled state, not a hazard.
    if (coherentShiftFloorPx != null &&
        (!coherentShiftFloorPx.isFinite || coherentShiftFloorPx <= 0.0)) {
      throw ArgumentError.value(
        coherentShiftFloorPx,
        'coherentShiftFloorPx',
        'must be null (disabled) or a finite double > 0',
      );
    }
    // #119: an integer COUNT, so the hazard is not NaN but a value < 1 —
    // which would let its own window search accept an empty group, the
    // same unreachable-vs-lenient class `coherentShiftMinBlocks` guards.
    if (coherentShiftReanchorMinBlocks != null &&
        coherentShiftReanchorMinBlocks < 1) {
      throw ArgumentError.value(
        coherentShiftReanchorMinBlocks,
        'coherentShiftReanchorMinBlocks',
        'must be null (disabled) or >= 1',
      );
    }
  }

  /// Current bucket width for dedup key generation.
  ///
  /// Setting a non-finite or non-positive value throws [ArgumentError].
  /// Prefer [updateViewport], which also keeps [spatialIndex]'s buckets in
  /// sync (#52).
  double get bucketWidth => _bucketWidth;
  set bucketWidth(double value) {
    _validatePositiveFinite('bucketWidth', value);
    _bucketWidth = value;
  }

  double _bucketWidth = BlockKeyGenerator.kDefaultBucketSize;

  /// Current bucket height for dedup key generation.
  ///
  /// Setting a non-finite or non-positive value throws [ArgumentError].
  /// Prefer [updateViewport] (#52).
  double get bucketHeight => _bucketHeight;
  set bucketHeight(double value) {
    _validatePositiveFinite('bucketHeight', value);
    _bucketHeight = value;
  }

  double _bucketHeight = BlockKeyGenerator.kDefaultBucketSize;

  /// Current visual viewport scale for dedup key generation.
  ///
  /// Setting a non-finite or non-positive value throws [ArgumentError].
  double get scale => _scale;
  set scale(double value) {
    _validatePositiveFinite('scale', value);
    _scale = value;
  }

  double _scale = 1.0;

  /// Update every viewport-derived quantization knob in one call.
  ///
  /// Before 0.6.0 the engine had three uncoordinated quantization systems
  /// — the dedup-key buckets here, [SpatialBlockIndex.updateBucketSizes],
  /// and [DriftTracker.regionSize] — and an app that updated one but not
  /// the others silently degraded matching. This method is the single
  /// entry point: it recomputes [spatialIndex]'s adaptive buckets from the
  /// viewport and adopts the same bucket dimensions for dedup keys, so
  /// the two quantizations cannot drift apart. ([DriftTracker.regionSize]
  /// is intentionally not touched — it is a fixed CSS-pixel constant from
  /// [SubmapMembership], not a viewport-derived value.)
  ///
  /// [scale] (the visual viewport scale for dedup keys) is only changed
  /// when passed. Throws [ArgumentError] on non-finite or non-positive
  /// arguments; no state is modified when validation fails.
  ///
  /// The index's stored blocks are re-keyed under the new bucket
  /// geometry before this method returns: cell keys are a function of
  /// bucket size, so changing the size without a rebuild would leave
  /// every cached block filed under stale cells — unfindable by the
  /// next [stabilize] at any scroll depth where old and new cell
  /// coordinates diverge by more than the ±1-neighbor scan
  /// (PR #61 review). Since 2.2.0 the index performs that re-key itself
  /// whenever its sizes change.
  ///
  /// 2.2.0: once [updateBucketSizes] has set the sizes directly, this
  /// method no longer re-derives them from the viewport — a consumer
  /// whose bucket policy is not the viewport formula would otherwise
  /// have its policy silently reverted by the next rotation or keyboard
  /// event (PR #114 review). Pass [resetBucketPolicy] to return to the
  /// formula; [scale] is applied either way.
  void updateViewport({
    required double viewportWidth,
    required double viewportHeight,
    double? scale,
    bool resetBucketPolicy = false,
  }) {
    _validatePositiveFinite('viewportWidth', viewportWidth);
    _validatePositiveFinite('viewportHeight', viewportHeight);
    if (scale != null) _validatePositiveFinite('scale', scale);
    if (scale != null) _scale = scale;
    if (resetBucketPolicy) _bucketsPinned = false;
    if (_bucketsPinned) return;
    _spatialIndex.updateBucketSizes(
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    );
    _bucketWidth = _spatialIndex.bucketWidth;
    _bucketHeight = _spatialIndex.bucketHeight;
  }

  /// Whether [updateBucketSizes] has pinned the bucket sizes, so that
  /// [updateViewport] leaves them alone until called with
  /// `resetBucketPolicy: true`.
  bool get bucketsPinned => _bucketsPinned;
  bool _bucketsPinned = false;

  /// Set the spatial-index bucket sizes directly (2.2.0, #113), for a
  /// consumer whose bucket policy is not [updateViewport]'s viewport
  /// formula — e.g. 2× the median block height, the spatial-hashing
  /// convention under which any box overlaps at most four cells — and
  /// for the replay rig applying the buckets a stream recorded.
  ///
  /// Same contract as [updateViewport]: the stored blocks are re-keyed
  /// under the new geometry before this returns (the index re-keys
  /// itself), and the dedup-key quantization follows the index. Pins
  /// the sizes: a later [updateViewport] keeps them until it is called
  /// with `resetBucketPolicy: true` (see [bucketsPinned]). Throws
  /// [ArgumentError] on non-finite or non-positive values; no state
  /// changes on failure.
  void updateBucketSizes({
    required double bucketWidth,
    required double bucketHeight,
  }) {
    _validatePositiveFinite('bucketWidth', bucketWidth);
    _validatePositiveFinite('bucketHeight', bucketHeight);
    _spatialIndex.setBucketSizes(
      bucketWidth: bucketWidth,
      bucketHeight: bucketHeight,
    );
    _bucketWidth = _spatialIndex.bucketWidth;
    _bucketHeight = _spatialIndex.bucketHeight;
    _bucketsPinned = true;
  }

  /// Throw [ArgumentError] unless [value] is a finite double > 0.
  static void _validatePositiveFinite(String name, double value) {
    if (!value.isFinite || value <= 0) {
      throw ArgumentError(
        '$name must be a finite double > 0 (got $value). Non-finite or '
        'non-positive quantization values silently corrupt dedup keys '
        'and spatial-cell assignment.',
      );
    }
  }

  /// Overlap resolver for spatial NMS.
  final OverlapResolver _resolver = const OverlapResolver();

  /// Validate that a block's confidence values are finite and in range.
  ///
  /// Engine *input* guard — symmetric to `MergeResult`'s 0.2.0 engine *output*
  /// guard at [merge_result.dart:107-124]. Together they bracket the pipeline:
  /// no NaN/out-of-range Confidence can enter or leave the engine.
  ///
  /// Called from two sites:
  /// - [stabilize] — loops over fresh blocks, passing [index] for context.
  /// - [merge] — validates [fresh] and [existing] individually, passing a
  ///   [role] string (e.g. `'fresh'` / `'existing'`) instead of an index.
  ///
  /// When [role] is non-null, the error prefix is `'<role>: '`.
  /// When [index] is non-null (and [role] is null), the prefix is
  /// `'observation at index <index>: '`.
  /// When both are null, no prefix is prepended.
  ///
  /// Throws [ArgumentError.value] naming the offending field on the first
  /// violation. Catches any [Track] implementor — `DefaultTrackedBlock`
  /// already early-fails at construction, but a hand-rolled implementor can
  /// still slip past the unchecked-`const` `PositionConfidence(double)` /
  /// `TextConfidence(double)` primary constructors documented at
  /// [confidence_types.dart:14-22].
  void _assertValidConfidence(T block, {int? index, String? role}) {
    final prefix =
        role ?? (index != null ? 'observation at index $index' : null);
    assertConfidenceRange(
      'positionConfidence',
      block.positionConfidence.raw,
      prefix: prefix,
    );
    assertConfidenceRange(
      'textConfidence',
      block.textConfidence.raw,
      prefix: prefix,
    );
  }

  /// Core entry point: stabilize a batch of fresh blocks against the model.
  ///
  /// [freshBlocks] — raw OCR observations for this frame (may contain
  /// duplicates, noise, or re-observations of known blocks; the dedup
  /// pipeline handles filtering).
  ///
  /// Returns a [StabilizationResult] containing:
  /// - [StabilizationResult.stableBlocks] — merged/new blocks
  /// - [StabilizationResult.contradictions] — detected contradictions
  /// - [StabilizationResult.invalidatedTexts] — texts needing re-translation
  /// - [StabilizationResult.wellObservedTexts] — texts at or past the
  ///   well-observed threshold (3 observations): a long-term-caching hint,
  ///   not a display gate — first-sighting blocks are already in
  ///   [StabilizationResult.stableBlocks]
  ///
  /// [spatialIndex] is rebuilt internally from the returned `stableBlocks`
  /// before this method returns — callers no longer rebuild it after each
  /// [stabilize] call (#13).
  ///
  /// **Index ownership:** the rebuild replaces the index with this call's
  /// `stableBlocks` plus, when [missedFrameRetention] > 0, cached blocks
  /// still inside their retention window. With the default retention of
  /// 0, a tracked block that is not re-observed in a capture (OCR miss,
  /// glare, occlusion) leaves the index and, if it reappears later, is
  /// treated as new — opt into retention to preserve identity across
  /// missed frames (#46). Blocks the app inserts into [spatialIndex]
  /// between calls are treated like any other cached block: dropped at
  /// the next [stabilize] unless retention keeps them — and, since 2.1.0,
  /// dropped even inside the retention window when a fresh block of that
  /// call covers them (supersession, see [missedFrameRetention]).
  ///
  /// Throws [ArgumentError] if any observation carries an invalid (NaN or
  /// out-of-range) [PositionConfidence] or [TextConfidence] value (#27).
  StabilizationResult<T> stabilize(List<T> freshBlocks) {
    // Engine-entry Confidence validation (#27). Catches any Track
    // implementor at one seam, complementing MergeResult's engine-output guard.
    for (var i = 0; i < freshBlocks.length; i++) {
      _assertValidConfidence(freshBlocks[i], index: i);
    }

    // 1. Dedup pipeline (also yields the per-batch spatial grid, reused
    //    below so grouping detection doesn't build a second throwaway
    //    index every capture, #55)
    final dedupResult = _batchDedup.run(
      freshBlocks,
      bucketWidth: bucketWidth,
      bucketHeight: bucketHeight,
      scale: scale,
    );
    final deduped = dedupResult.blocks;

    // 2. Contradiction detection (before merge so contradicted blocks
    //    can be signaled for eviction before fresh blocks enter)
    final contradictions = <ContradictionEvent<T>>[
      ..._contradictions.grouping(deduped, dedupResult.batchIndex),
      ...detectSplittingContradictions(deduped),
    ];
    // #112 × #49: a cached block the grouping detector just flagged as
    // SPLIT into two or more of this capture's blocks is withheld from
    // nested absorption. The contradiction is the stronger evidence (the
    // subdividers cover the host and reassemble its text) and is handed
    // to the consumer for eviction; silently confirming the same host
    // with one of those subdividers in the same call would contradict
    // it. The fragments enter as new blocks instead — the pre-2.2.0
    // outcome the consumer's eviction logic expects (PR #114 review).
    final contradictedHosts = Set<T>.identity()
      ..addAll([
        for (final c in contradictions)
          if (c.type == ContradictionType.grouping) c.target,
      ]);

    // 3. Merge or insert
    final invalidatedTexts = <String>[];
    final wellObservedTexts = <String>[];
    final stableBlocks = <T>[];

    final matchedExisting = Set<T>.identity();
    // Nested-fragment matches (#112) are resolved AFTER every full match
    // of this capture: an engine can report a paragraph AND one of its
    // lines in the same frame, and both would otherwise merge into the
    // same cached block — two merged copies of one paragraph (measured on
    // the committed ML Kit stream: three identical tracked boxes). A
    // fragment whose host was already confirmed this frame is redundant
    // evidence and is dropped; the first fragment of an otherwise-missed
    // host confirms it once, later fragments of the same host are dropped
    // too.
    final pendingNested = <(T fresh, T host)>[];

    // Dry pre-pass (#116, finding A fix): ONLY when [stepResponse] is
    // [StepResponse.coherentShift] — under [StepResponse.damp] or
    // [StepResponse.snap] this block does not run at all, so the match+
    // merge loop below is structurally identical to the pre-#116
    // interleaved design (byte-identical to main, not merely argued to
    // be). `CoherentShiftDetector.detect` needs every match of this capture
    // decided BEFORE any of this capture's merges (and their
    // `driftTracker.addObservation` side effects) — but it only ever
    // votes on ordinary PRIMARY matches (band admissions and nested
    // fragments are excluded from its eligible pairs). The primary check
    // alone reads only the (this-capture-immutable) spatial index and
    // text scores — never `driftTracker`, never `_internalStats` — so a
    // primary-only, non-mutating pass here is safe to run ahead of the
    // real loop. `recordStats: false` keeps every counter ticking exactly
    // once, in the real loop below; `allowBandFallback: false` and
    // `allowNestedFallback: false` skip the two branches that either
    // read same-capture-mutable state (band) or would recompute work the
    // real loop does anyway for a result this vote discards either way
    // (nested).
    // The model gate sits here, not in the detector: legacy has no
    // agreement scale to detect "moved" against (documented no-op, see
    // [StepResponse]); the detector itself is model-agnostic.
    final coherentShiftPlan = stepResponse == StepResponse.coherentShift &&
            positionMergeModel == PositionMergeModel.agreementWeighted
        ? _coherentShiftDetector.detect([
            for (final fresh in deduped)
              (
                fresh: fresh,
                result: _matcher.find(
                  fresh,
                  recordStats: false,
                  allowBandFallback: false,
                  allowNestedFallback: false,
                ),
              ),
          ])
        : null;

    // Real match+merge loop — interleaved exactly as main had it (#116
    // finding A): each fresh block's REAL match (full band-fallback +
    // nested-fragment logic, `_internalStats` ticked) is resolved and,
    // if it merges, immediately merged before the next fresh block is
    // matched. A same-capture band spatial-confirm therefore sees
    // `driftTracker` as mutated by every earlier same-capture merge in
    // THIS loop — not a pre-capture snapshot — matching cross-capture
    // behavior exactly (see `BlockMatcher.find`'s band branch and
    // `DriftTracker.addObservation`).
    // 2.5.0 — the per-capture identity census and the coherent-shift
    // summary (`StabilizationResult.identityTurnover` / `.coherentShift`)
    // are counted HERE, at the merges that actually happen, never from
    // the plan alone. Membership (`memberDrift.containsKey(existing)`) is
    // keyed on the CACHED block only; application is gated in
    // `_mergeImpl` on step-response eligibility (band admission,
    // viewport-relative, carousel child) that membership cannot see, and
    // nothing stops a second fresh block from reaching the same cached
    // member through such a path — so the count reads the merge's own
    // `stepResponseApplied`, never `isCoherentMember` (PR #138 review).
    var mergedCount = 0;
    var admittedCount = 0;
    var coherentMembers = 0;
    var coherentAdopted = 0;
    // 2.6.0 (#135): the cached -> fresh centre pairs the transform
    // estimate is fitted over. Collected HERE — the real loop, every
    // StepResponse — under the coherent-shift detector's eligibility
    // (no band admission, nested fragment, provisional cached block,
    // viewport-relative fresh block or carousel child), from RAW rects:
    // no drift correction, so the fit never depends on the tracker's
    // same-capture mutations (finding C's hazard does not arise).
    final transform =
        TransformEstimator<T>(minPairs: transformEstimateMinPairs);
    for (final fresh in deduped) {
      final matchResult = _matcher.find(fresh);
      final existing = matchResult.match;
      if (existing == null) {
        stableBlocks.add(fresh);
        admittedCount++;
        continue;
      }
      if (matchResult.wasNestedFragment) {
        pendingNested.add((fresh, existing));
        continue;
      }
      matchedExisting.add(existing);
      mergedCount++;
      transform.observe(fresh, existing,
          wasBandFallback: matchResult.wasBandFallback);
      // #116 finding C: `frozenRegionDrift` threads the SAME drift
      // snapshot `CoherentShiftDetector.detect`'s dry pre-pass used for this
      // member's displacement into its real merge — see that method's
      // "Frozen drift snapshot" doc for why a live re-read here would be
      // order-dependent.
      final isCoherentMember = coherentShiftPlan != null &&
          coherentShiftPlan.memberDrift.containsKey(existing);
      final output = _merge(
        fresh,
        existing,
        invalidatedTexts,
        wellObservedTexts,
        wasBandFallback: matchResult.wasBandFallback,
        coherentShiftTranslation:
            isCoherentMember ? coherentShiftPlan.translation : null,
        frozenRegionDrift:
            isCoherentMember ? coherentShiftPlan.memberDrift[existing] : null,
      );
      stableBlocks.add(output.merged);
      if (output.stepResponseApplied == StepResponse.coherentShift) {
        coherentMembers++;
        if (coherentShiftPlan != null &&
            coherentShiftPlan.adopted.contains(existing)) {
          coherentAdopted++;
        }
      }
    }
    for (final (fresh, host) in pendingNested) {
      if (contradictedHosts.contains(host)) {
        stableBlocks.add(fresh);
        admittedCount++;
        continue;
      }
      if (matchedExisting.contains(host)) continue;
      matchedExisting.add(host);
      mergedCount++;
      stableBlocks.add(_merge(
        fresh,
        host,
        invalidatedTexts,
        wellObservedTexts,
        wasNestedFragment: true,
      ).merged);
    }

    // Missed-frame retention (#46) and cross-frame supersession (2.1.0):
    // [RetentionManager.retain]. Matched blocks are consumed; unmatched
    // ones stay matchable for `missedFrameRetention` further calls unless
    // a fresh block now covers their region.
    final retention = _retention.retain(
      stableBlocks: stableBlocks,
      matchedExisting: matchedExisting,
    );
    final retained = retention.retained;
    final droppedCount = retention.dropped;

    // Rebuild the spatial index so callers cannot get it wrong (#13).
    _spatialIndex.rebuild([...stableBlocks, ...retained]);

    // 2.5.0: a plan that reached nobody (every member's real match
    // diverged from the dry pre-pass) is not an event — the consumer's
    // cached geometry did not move.
    final coherentShift = coherentShiftPlan != null && coherentMembers > 0
        ? CoherentShiftEvent(
            translation: coherentShiftPlan.translation,
            memberCount: coherentMembers,
            adoptedCount: coherentAdopted,
            decidedBy: coherentShiftPlan.source,
          )
        : null;

    return StabilizationResult<T>(
      stableBlocks: stableBlocks,
      contradictions: contradictions,
      invalidatedTexts: invalidatedTexts,
      wellObservedTexts: wellObservedTexts,
      coherentShift: coherentShift,
      identityTurnover: IdentityTurnover(
        merged: mergedCount,
        admitted: admittedCount,
        retained: retained.length,
        dropped: droppedCount,
      ),
      // 2.6.0 (#135): observed, never applied — nothing above read it.
      transformEstimate: transform.estimate(),
    );
  }

  // ── Drift propagation ────────────────────────────────────────────────

  /// Last known median drift per space key, for detecting shifts.
  final Map<SpaceKey, Offset> _lastRegionalDrift = {};

  /// Check if regional drift shifted enough to warrant propagating
  /// corrections to uncorrected neighbors.
  ///
  /// Returns a list of `(spaceKey, driftDelta)` pairs where the median
  /// drift shifted beyond the threshold. The app should:
  /// 1. For each affected space key, find blocks with observationCount < 3
  /// 2. Shift their absoluteRect by `-driftDelta`
  /// 3. Rebuild the spatial index for affected regions
  ///
  /// Call this after processing [stabilize] results.
  List<({SpaceKey key, Offset delta})> checkDriftPropagation() {
    final results = <({SpaceKey key, Offset delta})>[];

    for (final spaceKey in driftTracker.observedKeys) {
      final newMedian = driftTracker.medianDriftForKey(spaceKey);
      final oldMedian = _lastRegionalDrift[spaceKey] ?? Offset.zero;
      final medianHeight = driftTracker.medianBlockHeightForKey(spaceKey);
      final propagationThreshold = max(2.0, medianHeight * 0.1);
      final deltaOffset = newMedian - oldMedian;

      if (deltaOffset.distance > propagationThreshold) {
        _lastRegionalDrift[spaceKey] = newMedian;
        driftTracker.recordPropagation(spaceKey);
        results.add((key: spaceKey, delta: deltaOffset));
      }
    }
    return results;
  }

  /// Identify blocks in [spaceKey] that are uncorrected (observationCount < 3)
  /// and should receive drift correction.
  ///
  /// Returns blocks from the spatial index matching the criteria. The app
  /// should shift each block's absoluteRect by `-delta` and rebuild.
  List<T> uncorrectedBlocksForKey(SpaceKey spaceKey) {
    return _spatialIndex.allBlocks
        .where(
          (b) =>
              driftTracker.spaceKeyFor(b) == spaceKey && b.observationCount < 3,
        )
        .toList();
  }

  /// Clear the regional-drift baseline so the next [checkDriftPropagation]
  /// call compares the current median against zero for every space key, as
  /// if no prior baseline existed. Recorded observations in [driftTracker]
  /// are not touched.
  ///
  /// For a full session reset (page navigation, context change), pair this
  /// with [DriftTracker.clear] — that discards the old context's
  /// observations, this discards the baseline. They govern different state:
  /// calling only [DriftTracker.clear] leaves a stale baseline that
  /// suppresses the new context's first real shift; calling only this
  /// leaves stale observations that still feed drift corrections.
  ///
  /// Calling this alone is also valid mid-session — it makes
  /// [checkDriftPropagation] re-emit the current drift so corrections reach
  /// newly-added uncorrected blocks, without discarding the observation
  /// window.
  void resetDriftPropagation() {
    _lastRegionalDrift.clear();
  }

  /// Perform SAR (Scan-Accumulate-Replace) merge of [fresh] into [existing].
  ///
  /// Public entry point for consumers that do their own block matching but
  /// want to delegate the merge math to the engine. Returns a [MergeOutput]
  /// containing the merged block and signals.
  ///
  /// Unlike [stabilize], `merge` does not touch [spatialIndex] — a consumer
  /// calling `merge` directly owns the spatial index lifecycle.
  ///
  /// When [trackDrift] is true (default), records drift observations.
  /// Existing drift correction is always applied regardless of this flag.
  /// Set to false for intra-batch merges where both blocks come from the
  /// same OCR frame (drift should only be learned from inter-capture
  /// observations).
  ///
  /// Throws [ArgumentError] if [fresh] or [existing] carries an invalid
  /// (NaN, infinite, or out-of-range) [PositionConfidence] or [TextConfidence]
  /// value (#27). Mirrors the same guard in [stabilize] — closing the
  /// public-API hole where NaN entering via `merge()` could propagate through
  /// merge arithmetic (e.g. `Rect.lerp(..., NaN)`) and escape undetected.
  MergeOutput<T> merge(T fresh, T existing, {bool trackDrift = true}) {
    _assertValidConfidence(fresh, role: 'fresh');
    _assertValidConfidence(existing, role: 'existing');
    return _mergeImpl(fresh, existing, trackDrift: trackDrift);
  }

  /// Internal merge used by [stabilize] — accumulates signals into lists.
  ///
  /// [wasBandFallback] flows through from `BlockMatcher.find`'s record return —
  /// `true` when the match came via the band-relaxed fallback path. When set,
  /// `_mergeImpl` marks the merged result as provisional with
  /// `bandFallback.provisionalCaptures` remaining (see `_mergeImpl` for the
  /// wrap semantics).
  ///
  /// [coherentShiftTranslation] — non-null only when [stepResponse] is
  /// [StepResponse.coherentShift] AND [existing] is a member of this
  /// batch's qualifying shift group (see `stabilize`'s
  /// `CoherentShiftDetector.detect` call). Threaded straight to `_mergeImpl`.
  ///
  /// [frozenRegionDrift] — (#116 finding C) non-null in lockstep with
  /// [coherentShiftTranslation]: the drift snapshot `CoherentShiftDetector.detect`
  /// used to compute THIS member's displacement, threaded through so
  /// `_mergeImpl` reads the same snapshot instead of re-reading (and
  /// potentially getting a different answer from) the live tracker.
  MergeOutput<T> _merge(
    T fresh,
    T existing,
    List<String> invalidatedTexts,
    List<String> wellObservedTexts, {
    bool wasBandFallback = false,
    bool wasNestedFragment = false,
    Offset? coherentShiftTranslation,
    Offset? frozenRegionDrift,
  }) {
    final output = _mergeImpl(
      fresh,
      existing,
      wasBandFallback: wasBandFallback,
      nestedFragment: wasNestedFragment,
      coherentShiftTranslation: coherentShiftTranslation,
      frozenRegionDrift: frozenRegionDrift,
    );
    if (output.textWasPromoted && output.promotedFromText != null) {
      invalidatedTexts.add(output.promotedFromText!);
    }
    if (output.contextInvalidated) {
      invalidatedTexts.add(existing.originalText);
    }
    if (output.isWellObserved) {
      wellObservedTexts.add(output.merged.originalText);
    }
    return output;
  }

  /// Core merge implementation shared by [merge] and [_merge].
  ///
  /// [wasBandFallback] — when `true` AND `existing` is not already
  /// provisional, the merged result is marked provisional with
  /// `bandFallback.provisionalCaptures` remaining. Future captures of this
  /// now-provisional block flow through the freeze path at the top of
  /// this method. A band-fallback admission never receives a step
  /// response either (#116) — a band-admitted match is already the
  /// engine's least-confident matching path; layering an aggressive
  /// re-anchor or batch-shift onto it would compound two opt-in relaxation
  /// mechanisms without either being validated against the other.
  ///
  /// [coherentShiftTranslation] — non-null only when [stepResponse] is
  /// [StepResponse.coherentShift] and [existing] is a member of this
  /// batch's qualifying shift group. When set, the weighted merge and the
  /// confidence computation both run against `existing`'s rect translated
  /// by this offset instead of `existing`'s own rect.
  ///
  /// [frozenRegionDrift] — (#116 finding C) non-null in lockstep with
  /// [coherentShiftTranslation]. When set, step 2 below uses this value
  /// in place of a live `driftTracker.medianDriftForKey` read, so the
  /// residual/`driftCorrection` this merge reports is computed from the
  /// SAME snapshot `CoherentShiftDetector.detect` used to vote the translation —
  /// never a tracker already mutated by an earlier same-capture merge in
  /// this capture's interleaved loop (see `CoherentShiftDetector.detect`'s
  /// "Frozen drift snapshot" doc for why a live re-read would be
  /// arrival-order dependent).
  MergeOutput<T> _mergeImpl(
    T fresh,
    T existing, {
    bool trackDrift = true,
    bool wasBandFallback = false,
    bool nestedFragment = false,
    Offset? coherentShiftTranslation,
    Offset? frozenRegionDrift,
  }) {
    // ┌─── Nested fragment: confirming observation only (#112) ────────
    // The fresh block is one line of `existing` reported on its own. It
    // casts NO text vote (a fragment repeated over several flip frames
    // would otherwise outscore the paragraph text), pulls NO position (its
    // rect is a sub-box, not a jittered observation of the same box), and
    // feeds NO drift or classification vote for the same reason. The host
    // is never provisional (`BlockMatcher.isNestedFragmentOf` requires an established
    // block), so this sits above the freeze path without interacting.
    if (nestedFragment) {
      final result = MergeResult(
        mergedRect: existing.absoluteRect,
        positionConfidence: existing.positionConfidence,
        driftCorrection: Offset.zero,
        winningOriginalText: existing.originalText,
        textConfidence: existing.textConfidence,
        updatedTextVotes: existing.textVotes,
        textWasPromoted: false,
        updatedClassificationVotes: existing.classificationVotes,
        needsReclassification: existing.needsReclassification,
        updatedCarouselVotes: existing.carouselVotes,
        observationCount: existing.observationCount + 1,
        isProvisional: false,
        provisionalCapturesRemaining: 0,
        sourceQuality: max(existing.sourceQuality, fresh.sourceQuality),
        isNestedFragment: true,
      );
      return MergeOutput<T>(
        // The HOST is handed to the merger as `fresh` too: a fragment
        // carries nothing the host should adopt, and a merger written to
        // the 2.1 contract copies pass-through fields (scroll context,
        // translated text, payload) from `fresh` on every call — with the
        // line as `fresh` it would overwrite the paragraph's. Contract
        // documented on [BlockMerger] (PR #114 review).
        merged: _merger(existing, existing, result),
        // Same threshold as the full path: a paragraph confirmed only by
        // its own lines still becomes well-observed.
        isWellObserved:
            existing.observationCount + 1 >= _kWellObservedThreshold,
      );
    }
    // └──────────────────────────────────────────────────────────────
    // ┌─── Provisional freeze ─────────────────────────────────────────
    // DECIDED (#57, 2026-07-22; trigger fired and re-armed 2026-07-23):
    // frozen captures intentionally accrue NO evidence — no observation
    // count, no text votes, no position update. Validated against
    // production capture data (consumer streams replayed via tool/replay):
    // deterministic-rect streams carry zero freeze traffic, and the one
    // admit-mode counterfactual WITH traffic (a noisy-OCR dwell) showed
    // tail magnitude only — 1 provisional chain, 3 freezes, 2 discarded
    // high-confidence text votes per ~5-minute session. Revisit ONLY if
    // a consumer adopts BandFallbackMode.admit in production AND its
    // captures show recurring high-confidence text-vote loss; the bounded
    // change to evaluate then is text-vote-only accrual during freeze
    // (position stays frozen by design). Details: issue #57.
    if (existing.isProvisional) {
      final remaining = existing.provisionalCapturesRemaining - 1;
      final result = MergeResult(
        mergedRect: existing.absoluteRect,
        positionConfidence: existing.positionConfidence,
        driftCorrection: Offset.zero,
        winningOriginalText: existing.originalText,
        textConfidence: existing.textConfidence,
        updatedTextVotes: existing.textVotes,
        textWasPromoted: false,
        updatedClassificationVotes: existing.classificationVotes,
        needsReclassification: existing.needsReclassification,
        updatedCarouselVotes: existing.carouselVotes,
        observationCount: existing.observationCount,
        isProvisional: remaining > 0,
        provisionalCapturesRemaining: remaining,
        sourceQuality: existing.sourceQuality,
      );
      return MergeOutput<T>(merged: _merger(existing, fresh, result));
    }
    // └──────────────────────────────────────────────────────────────

    // 1. Track drift from RAW observation (before correction).
    //    Only for inter-capture merges (trackDrift=true); intra-batch
    //    duplicates from the same OCR frame should not feed drift.
    if (trackDrift) {
      final rawDrift = Offset(
        fresh.absoluteRect.left - existing.absoluteRect.left,
        fresh.absoluteRect.top - existing.absoluteRect.top,
      );
      driftTracker.addObservation(
        fresh,
        rawDrift,
        blockHeight: fresh.absoluteRect.height,
      );
    }

    // 2. Correct fresh observation for known regional drift.
    //
    // #116 finding C: a coherent-shift member reads its FROZEN snapshot
    // (the one `CoherentShiftDetector.detect` used to vote the translation) here
    // instead of re-reading the live tracker — see this method's
    // `frozenRegionDrift` doc.
    final spaceKey = driftTracker.spaceKeyFor(fresh);
    final regionDrift =
        frozenRegionDrift ?? driftTracker.medianDriftForKey(spaceKey);
    final correctedRect = DriftTracker.applyCorrectedPosition(
      fresh.absoluteRect.raw,
      regionDrift,
    );

    // 3. Weighted average against corrected position (weight per
    //    [positionMergeModel], #58) with the step response (#116) —
    //    [PositionMerger.resolve]; its eligibility rule (finding D) and
    //    the snap / coherentShift baselines are documented there.
    final position = _positionMerger.resolve(
      fresh: fresh,
      existing: existing,
      correctedRect: correctedRect,
      wasBandFallback: wasBandFallback,
      coherentShiftTranslation: coherentShiftTranslation,
    );
    final baselineRect = position.baselineRect;
    final residualOverride = position.residualOverride;
    final appliedStepResponse = position.stepResponseApplied;
    final mergedRaw = position.mergedRect;

    // 4a. Classification vote accumulation
    final classVotes = Map<int, int>.from(existing.classificationVotes);
    classVotes[fresh.hierarchyWeight] =
        (classVotes[fresh.hierarchyWeight] ?? 0) + 1;
    final bestWeight =
        classVotes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final needsReclass = bestWeight != existing.hierarchyWeight;

    // 4b. Carousel ID vote accumulation (#148: the value type owns the
    // histogram; a freshly constructed block carries no phantom vote to
    // clear).
    final carouselVotes =
        existing.carouselVotes.record(fresh.scrollContext.hzScrollerIndex);

    // 4c. Text vote accumulation
    final updatedTextVotes = Map<String, TextVote>.from(existing.textVotes);

    // Seed existing block's text on first merge (textVotes starts empty).
    if (updatedTextVotes.isEmpty) {
      final existingNormKey = String.fromCharCodes(
        TextDedupUtils.significantCharList(existing.originalText),
      );
      if (existingNormKey.isNotEmpty) {
        updatedTextVotes[existingNormKey] = TextVote(
          rawText: existing.originalText,
          score: existing.textConfidence.raw,
          bestConfidence: existing.textConfidence.raw,
        );
      }
    }

    final freshText = fresh.originalText;
    final normalizedKey = String.fromCharCodes(
      TextDedupUtils.significantCharList(freshText),
    );
    final existingVote = updatedTextVotes[normalizedKey];
    final bestRaw = (existingVote == null ||
            fresh.textConfidence.raw > existingVote.bestConfidence)
        ? freshText
        : existingVote.rawText;
    updatedTextVotes[normalizedKey] = TextVote(
      rawText: bestRaw,
      bestConfidence: max(
        fresh.textConfidence.raw,
        existingVote?.bestConfidence ?? 0.0,
      ),
      score: (existingVote?.score ?? 0.0) + fresh.textConfidence.raw,
    );
    // Bounded growth: cap at top entries
    if (updatedTextVotes.length > _kMaxTextVotes) {
      final entries = updatedTextVotes.entries.toList()
        ..sort((a, b) => b.value.score.compareTo(a.value.score));
      updatedTextVotes.removeWhere((key, _) => key == entries.last.key);
    }
    // Find the winner: highest accumulated score
    final winningVote = updatedTextVotes.values.reduce(
      (a, b) => a.score >= b.score ? a : b,
    );
    final winningText = winningVote.rawText;
    final winnerBestConf = winningVote.bestConfidence;
    final textWasPromoted = winningText != existing.originalText;

    // Text confidence: snap on promotion, blend when same text.
    double mergedTextConf;
    if (textWasPromoted) {
      mergedTextConf = winnerBestConf;
    } else if (existing.originalText == fresh.originalText) {
      final existingTC = existing.textConfidence.raw;
      final freshTC = fresh.textConfidence.raw;
      final totalTextConf = existingTC + freshTC;
      final tw = totalTextConf > 0 ? freshTC / totalTextConf : 0.5;
      mergedTextConf = (existingTC * (1 - tw) + freshTC * tw).clamp(0.0, 1.0);
    } else {
      mergedTextConf = existing.textConfidence.raw;
    }

    // 4d. Source quality: prefer higher tier
    final mergedSourceQuality = max(
      existing.sourceQuality,
      fresh.sourceQuality,
    );

    final newObservationCount = existing.observationCount + 1;

    // Build MergeResult. When this merge came from the band-relaxed fallback
    // path AND the existing block isn't already provisional, wrap the result
    // as provisional with bandFallback.provisionalCaptures remaining. Future
    // captures of this now-provisional block enter the freeze path above and
    // decrement the counter until it graduates.
    final mergedRectCalculated = AbsoluteRect(mergedRaw);
    final mergedPositionConf = PositionConfidence.from(
      _positionMerger.mergedConfidence(
        fresh,
        existing,
        correctedRect,
        baselineRect: baselineRect,
        residualOverride: residualOverride,
      ),
    );
    final mergedTextConfTyped = TextConfidence.from(mergedTextConf);

    // The provisional-freeze path above (line ~600) returns early when
    // `existing.isProvisional` is true, so `existing` is structurally
    // guaranteed non-provisional here. Lock that invariant with an
    // executable assert so a refactor of the freeze path can't silently
    // double-wrap a still-provisional block.
    assert(
        !existing.isProvisional,
        'provisional freeze path should have returned before reaching '
        'band-admit wrap');
    final bool admitAsProvisional = wasBandFallback;

    final result = MergeResult(
      mergedRect: mergedRectCalculated,
      positionConfidence: mergedPositionConf,
      driftCorrection: regionDrift,
      winningOriginalText: winningText,
      textConfidence: mergedTextConfTyped,
      updatedTextVotes: Map.unmodifiable(updatedTextVotes),
      textWasPromoted: textWasPromoted,
      updatedClassificationVotes: Map.unmodifiable(classVotes),
      needsReclassification: needsReclass,
      updatedCarouselVotes: carouselVotes,
      observationCount: newObservationCount,
      isProvisional: admitAsProvisional,
      provisionalCapturesRemaining:
          admitAsProvisional ? bandFallback.provisionalCaptures : 0,
      sourceQuality: mergedSourceQuality,
      stepResponseApplied: appliedStepResponse,
    );

    // Call consumer merger to construct the updated block
    final merged = _merger(existing, fresh, result);

    // Compute signals
    final contextInvalidated = !textWasPromoted &&
        _contextualCheck != null &&
        _contextualCheck(fresh, existing);

    return MergeOutput<T>(
      merged: merged,
      textWasPromoted: textWasPromoted,
      promotedFromText: textWasPromoted ? existing.originalText : null,
      contextInvalidated: contextInvalidated,
      isWellObserved: newObservationCount >= _kWellObservedThreshold,
      stepResponseApplied: appliedStepResponse,
    );
  }

  // ── Contradiction detection ───────────────────────────────────────

  /// Detect grouping contradictions in [freshBlocks] against the spatial
  /// index: ≥2 fresh blocks spatially subdivide a well-observed cached
  /// block.
  ///
  /// Returns [ContradictionEvent]s — the consumer decides whether to evict.
  ///
  /// Thresholds: height ratio < 0.70, overlap ratio ≥ 0.30, text similarity
  /// ≥ 0.60 (Levenshtein on space-joined subdivider texts).
  ///
  /// Public for consumers that run their own dedup pipeline but want to
  /// delegate contradiction detection to the engine.
  List<ContradictionEvent<T>> detectGroupingContradictions(
    List<T> freshBlocks,
  ) {
    // Public entry point: build the fresh-block index here. The internal
    // [stabilize] path passes the batch grid `BatchDedup.run` already built for
    // NMS instead of constructing a second one per capture (#55).
    if (freshBlocks.length < 2) return const [];
    final freshIndex = SpatialBlockIndex<T>()..adoptBucketSizes(_spatialIndex);
    freshIndex.rebuild(freshBlocks);
    return _contradictions.grouping(freshBlocks, freshIndex);
  }

  /// Detect splitting contradictions in [freshBlocks] against the spatial
  /// index: a single fresh block subsumes ≥2 well-observed cached blocks.
  ///
  /// Returns [ContradictionEvent]s — the consumer decides whether to evict.
  ///
  /// Thresholds: height ratio < 0.70, containment ≥ 0.80, text similarity
  /// ≥ 0.60 (Levenshtein on space-joined subsumed texts).
  ///
  /// Public for consumers that run their own dedup pipeline but want to
  /// delegate contradiction detection to the engine.
  List<ContradictionEvent<T>> detectSplittingContradictions(
    List<T> freshBlocks,
  ) {
    return _contradictions.splitting(freshBlocks);
  }
}
