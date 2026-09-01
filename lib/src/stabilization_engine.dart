import 'dart:math' show max, min;
import 'types/geometry.dart' show Offset, Rect;

import 'band_fallback_config.dart';
import 'band_fallback_stats.dart';
import 'block_key.dart';
import 'coherent_shift_event.dart';
import 'drift_tracker.dart';
import 'hierarchy_weight.dart';
import 'identity_turnover.dart';
import 'internal/confidence_validation.dart';
import 'merge_result.dart';
import 'observable_block.dart';
import 'overlap_resolver.dart';
import 'robust_stats.dart';
import 'spatial_block_index.dart';
import 'stabilization_result.dart';
import 'step_response.dart';
import 'submap_membership.dart';
import 'text_dedup_utils.dart';
import 'text_vote.dart';
import 'tracked_block.dart';
import 'types/absolute_rect.dart';
import 'types/confidence_types.dart';
import 'types/space_key.dart';

/// A decided coherent-shift plan (#116/#119), private to the engine.
///
/// `memberDrift` is the single source of truth for membership AND each
/// member's frozen drift snapshot (#116 finding C); `adopted` is the
/// subset of members carried along by `coherentShiftAdoptAgreeing`
/// (#119 item 2); `source` names the path that decided the plan. Both
/// collections are identity-keyed — `T` is the consumer's type and may
/// define value equality. `stabilize` summarises the plan's APPLIED
/// members into `StabilizationResult.coherentShift` (2.5.0).
typedef _ShiftPlan<T> = ({
  Offset translation,
  Map<T, Offset> memberDrift,
  Set<T> adopted,
  CoherentShiftSource source,
});

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

/// Jitter allowance multiplier for [PositionMergeModel.agreementWeighted]:
/// the agreement scale is this multiple of the existing (tracked) block's
/// OWN height (#75; was the region's median block height through 1.0.x — a
/// pooled median gets polluted by small siblings and needed a cold-region
/// default, see `_mergedPositionConfidence`). A residual equal to the full
/// allowance scores agreement 0; a residual well inside it scores partial
/// agreement.
///
/// Why not the drift margin? `driftMarginForKey` is a *median-of-drift* —
/// a systematic-offset measure, ~0 under symmetric jitter and sub-floor
/// numeric residue on stable streams — so a margin-derived scale is dead
/// or poisonous in every sampled production regime (#58, #70, #71). A
/// spread measure (MAD of drift residuals, see `RobustStats`) is the
/// documented option if a drift-adaptive scale is ever wanted; note #72
/// (the `madOrFallback` floor) becomes load-bearing first.
///
/// Why 3? Sweep-validated on production captures (#58, 2026-07-22):
/// at 1x, deep-chain OCR jitter is chased at 15.8 px/merge (worse than
/// legacy's 11.8); at 3x the confidence→weight anchoring loop engages and
/// damps it to 3.8 px/merge, while confidence stays regime-discriminating
/// (~1.0 stable / 0.85 reflow / 0.35 heavy jitter — never saturated-blind
/// like legacy). The 3x multiplier carried over unchanged to the per-block
/// base (#75, 2026-07-24): on uniform streams the two bases coincide (the
/// sweep's calibration transfers), and the six-capture validation showed
/// per-block ~30-60% better established-chain damping under OCR jitter
/// with every other regime within noise
/// (`doc/replay/validation/2026-07-perblock-scale/`). Calibrated against
/// ML-Kit-shaped noise; re-run the sweep (`tool/replay` ab-report) before
/// trusting it for a different OCR engine's residual distribution.
/// Cross-engine matrix (issue #94): Tesseract 5 and PaddleOCR entries
/// (synthetic low-amplitude corpora, 2026-08) show the default TRANSFERS
/// without retuning in the photometric-jitter regime — established-chain
/// damping and regime-discriminating confidence replicate on both. The
/// high-amplitude re-segmentation regime remains ML-Kit evidence, now
/// including a committed on-device stream
/// (`doc/replay/validation/2026-08-mlkit-on-device/`). All entries live
/// under `doc/replay/validation/`.
const double _kAgreementJitterAllowance = 3.0;

/// Maximum text vote entries per block to prevent OOM on noisy edges.
const int _kMaxTextVotes = 5;

/// Below this many pixels, a displacement component carries no direction
/// (#119). Used only by `StabilizationEngine.coherentShiftFloorPx`'s
/// direction-agreement check, so a group whose members agree on the axis
/// that actually moved is not broken up by sub-pixel disagreement on the
/// other one — real corpus movers report dx values like `-0.0` and `0.1`
/// on a purely vertical slab.
const double _kDirectionEpsilonPx = 1.0;

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
/// and observation history live on the consumer's [TrackedBlock]s, and
/// the shared [driftTracker] is the consumer's to reset or keep. Whether
/// an engine-wide reset() should exist instead is issue #95.
///
/// Generic parameters:
/// - [T] — concrete block type (must implement [ObservableBlock<P>])
/// - [P] — opaque payload type carried by the block
class StabilizationEngine<T extends ObservableBlock<P>, P> {
  final BlockMerger<T, P> _merger;

  /// Drift tracker shared with the app (the app may also feed observations).
  final DriftTracker driftTracker;

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

  /// Effective spatial confirmation predicate. Resolved at construction time:
  /// the consumer's [BandFallbackConfig.spatialConfirm] if non-null, otherwise
  /// a drift-aware closure that uses [_resolver] and [driftTracker] to compute
  /// `overlapRatio >= 0.80` against the candidate's space-keyed drift margin.
  late final BandSpatialPredicate _effectiveSpatialConfirm =
      bandFallback.spatialConfirm ?? _defaultSpatialConfirm;

  /// True iff the engine is running the consumer-supplied
  /// [BandFallbackConfig.spatialConfirm]. Captured at construction so the
  /// _findMatch loop can scope its predicate try/catch to consumer code only —
  /// engine-internal default-closure errors must propagate with their real
  /// type instead of being misattributed as [BandPredicateException].
  late final bool _consumerSpatialConfirmInUse =
      bandFallback.spatialConfirm != null;

  // Engine-owned default predicate. Lives as a separate method so the
  // _findMatch try/catch can scope itself to consumer code only (engine
  // bugs in this default closure must surface with their real type).
  bool _defaultSpatialConfirm(TrackedBlock fresh, TrackedBlock candidate) =>
      _resolver.overlapRatio(
        fresh,
        candidate,
        driftTracker.driftMarginForKey(driftTracker.spaceKeyFor(candidate)),
      ) >=
      0.80;

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
    this.bandFallback = const BandFallbackConfig(),
    this.missedFrameRetention = 0,
    this.positionMergeModel = PositionMergeModel.agreementWeighted,
    this.stepResponse = StepResponse.coherentShift,
    this.snapThresholdMultiplier = 1.5,
    this.coherentShiftMinBlocks = 3,
    this.coherentShiftMinShare = 0.5,
    this.coherentShiftTolerance = 0.5,
    this.coherentShiftFloorPx,
    this.coherentShiftReanchorMinBlocks,
    this.coherentShiftAdoptAgreeing = true,
  })  : _merger = merger,
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
  }

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

  /// Consecutive-miss counter per retained block (identity-keyed; block
  /// instances persist across frames precisely when unmatched).
  final Map<T, int> _missCounts = Map<T, int>.identity();

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
  /// same scale [_mergedPositionConfidence] uses). Default `1.5` — half
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
  /// `_detectCoherentShift` for the exact clustering algorithm.
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
  /// [coherentShiftMinBlocks]. `_detectCoherentShift` then returns before
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
  /// A multiple of the block's own agreement scale ([_agreementScale], 3x
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
  /// ([_agreementScale], 3x): a 150 px slab step carries a 36 px line past
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

  /// Lerp weight toward the fresh (drift-corrected) observation.
  double _positionMergeWeight(T fresh, T existing) {
    final freshConf = fresh.positionConfidence.raw;
    final existingConf = existing.positionConfidence.raw;
    switch (positionMergeModel) {
      case PositionMergeModel.legacy:
        // 0.x behavior: confidence ratio only. Locks near
        // fresh/(1+fresh) once existing confidence saturates, so even a
        // 100-times-observed block moves ~33% toward every noisy rect.
        final totalConf = existingConf + freshConf;
        return totalConf > 0 ? freshConf / totalConf : 0.5;
      case PositionMergeModel.agreementWeighted:
        // Existing confidence is anchored by its observation count —
        // a 1/n-style decay, so long-observed blocks become
        // positionally sticky while a twice-seen block still adapts.
        // The count is clamped to >= 1: a consumer block with a zero or
        // negative count (invalid, but reachable via the public index
        // seam) must not drive the weight past 1.0 and extrapolate the
        // lerp (PR #65 review).
        final anchored = existingConf * max(1, existing.observationCount);
        final total = anchored + freshConf;
        return total > 0 ? freshConf / total : 0.5;
    }
  }

  /// The block's own jitter-allowance scale — [_kAgreementJitterAllowance]
  /// (3x) times its own height ([_blockHeight], which floors a degenerate
  /// 0/negative/non-finite rect at 16px). Shared by
  /// [_mergedPositionConfidence]'s agreement computation and
  /// [StepResponse.snap]'s threshold check (both must reference literally
  /// the same scale, per #116's spec) so the two can never drift apart.
  double _agreementScale(T existing) =>
      _blockHeight(existing) * _kAgreementJitterAllowance;

  /// THE definition of a block's height for the coherent-shift machinery:
  /// the "moved" gate (through [_agreementScale]), the movers' median
  /// height the clustering tolerance scales with, and the adoption
  /// tolerance (#119 item 2) all read this one function, so they cannot
  /// drift apart (PR #132 review C3 — the 16 px fallback used to be
  /// written out at each site). A non-finite or non-positive rect counts
  /// as 16 px.
  double _blockHeight(T block) {
    final h = block.absoluteRect.raw.height;
    return (!h.isFinite || h <= 0) ? 16.0 : h;
  }

  /// Merged position confidence for the current [positionMergeModel].
  ///
  /// [baselineRect] is the position the residual is measured FROM —
  /// defaults to `existing.absoluteRect.raw`. [StepResponse.coherentShift]
  /// passes the existing rect already translated by the batch shift, so
  /// the residual reflects how well this pair agreed with the GROUP's
  /// shift rather than with the untranslated tracked position.
  /// [residualOverride], when non-null, is used in place of the computed
  /// residual outright — [StepResponse.snap] passes `0.0`: a full
  /// re-anchor is agreement with the new position, not disagreement with
  /// the old one.
  double _mergedPositionConfidence(
    T fresh,
    T existing,
    Rect correctedRect, {
    Rect? baselineRect,
    double? residualOverride,
  }) {
    switch (positionMergeModel) {
      case PositionMergeModel.legacy:
        // 0.x behavior: additive with clamp — saturates to 1.0 after two
        // ~0.5-confidence observations regardless of agreement (#58).
        final totalConf =
            existing.positionConfidence.raw + fresh.positionConfidence.raw;
        return min(totalConf, 1.0);
      case PositionMergeModel.agreementWeighted:
        // Confidence is a running mean of positional AGREEMENT: how
        // close the corrected fresh observation landed to the tracked
        // position, scaled by the block's OWN jitter allowance
        // ([_kAgreementJitterAllowance] x the existing block's height,
        // #75): tolerance proportional to the block's own text size. A
        // region-median scale gets polluted by small siblings (a caption's
        // height says nothing about how much a paragraph may jitter — F2)
        // and cold regions fell to the 16 px height default (F4); the
        // existing (tracked) block's height is jitter-stable and needs no
        // default. Disagreeing observations REDUCE confidence instead of
        // saturating it.
        final residual = residualOverride ??
            (correctedRect.topLeft -
                    (baselineRect ?? existing.absoluteRect.raw).topLeft)
                .distance;
        final scale = _agreementScale(existing);
        final agreement =
            scale > 0 ? (1.0 - residual / scale).clamp(0.0, 1.0) : 0.0;
        // Clamped for the same reason as the merge weight: n <= -1
        // would zero or invert the running-mean denominator
        // (PR #65 review).
        final n = max(1, existing.observationCount);
        return ((existing.positionConfidence.raw * n) + agreement) / (n + 1);
    }
  }

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
  /// violation. Catches any [ObservableBlock] implementor — `DefaultTrackedBlock`
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
    // Engine-entry Confidence validation (#27). Catches any ObservableBlock
    // implementor at one seam, complementing MergeResult's engine-output guard.
    for (var i = 0; i < freshBlocks.length; i++) {
      _assertValidConfidence(freshBlocks[i], index: i);
    }

    // 1. Dedup pipeline (also yields the per-batch spatial grid, reused
    //    below so grouping detection doesn't build a second throwaway
    //    index every capture, #55)
    final dedupResult = _dedup(freshBlocks);
    final deduped = dedupResult.blocks;

    // 2. Contradiction detection (before merge so contradicted blocks
    //    can be signaled for eviction before fresh blocks enter)
    final contradictions = <ContradictionEvent<T>>[
      ..._detectGroupingContradictions(deduped, dedupResult.batchIndex),
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
    // be). `_detectCoherentShift` needs every match of this capture
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
    final coherentShiftPlan = stepResponse == StepResponse.coherentShift
        ? _detectCoherentShift([
            for (final fresh in deduped)
              (
                fresh: fresh,
                result: _findMatch(
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
    // behavior exactly (see `_findMatch`'s band branch and
    // `DriftTracker.addObservation`).
    // 2.5.0 — the per-capture identity census and the coherent-shift
    // summary (`StabilizationResult.identityTurnover` / `.coherentShift`)
    // are counted HERE, at the merges that actually happen, never from
    // the plan alone: a plan member whose real match differs from the dry
    // pre-pass's is not applied and must not be reported as one.
    var mergedCount = 0;
    var admittedCount = 0;
    var coherentMembers = 0;
    var coherentAdopted = 0;
    for (final fresh in deduped) {
      final matchResult = _findMatch(fresh);
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
      // #116 finding C: `frozenRegionDrift` threads the SAME drift
      // snapshot `_detectCoherentShift`'s dry pre-pass used for this
      // member's displacement into its real merge — see that method's
      // "Frozen drift snapshot" doc for why a live re-read here would be
      // order-dependent.
      final isCoherentMember = coherentShiftPlan != null &&
          coherentShiftPlan.memberDrift.containsKey(existing);
      if (isCoherentMember) {
        coherentMembers++;
        if (coherentShiftPlan.adopted.contains(existing)) coherentAdopted++;
      }
      final merged = _merge(
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
      stableBlocks.add(merged);
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
      ));
    }

    // Missed-frame retention (#46): cached blocks that were not matched
    // this capture stay in the index as match candidates for up to
    // [missedFrameRetention] further calls, so a single OCR miss does
    // not reset a block's accumulated identity. Matched blocks are
    // consumed (their history lives on in the merged result); expired
    // blocks are dropped along with their miss counter.
    //
    // The counter map is REBUILT from the current index contents each
    // call rather than mutated incrementally: [spatialIndex] is a queryable
    // field the app may rebuild, clear, or remove blocks from between
    // calls, and an incrementally-maintained map would keep strong
    // references (and stale counts) for every instance that left the
    // index externally. Rebuilding bounds the map to exactly the
    // currently-retained set (PR #61 review).
    final retained = <T>[];
    var droppedCount = 0;
    if (missedFrameRetention > 0) {
      // Cross-frame supersession (2.1.0): a cached block that was NOT
      // matched this capture, but whose region a fresh block now covers
      // (measured against the CACHED block's own area, so a single line
      // reported inside a retained paragraph does not evict the
      // paragraph), is not retained. The region has visibly changed — or
      // the old box sat in a lagged coordinate frame — and retaining it
      // makes a consumer of the tracked state draw the old box on top of
      // the new one for the whole retention window. This deliberately
      // trades identity for a clean frame: when the FRESH block is the
      // wrongly placed one (a lagged scroll stamp), a correct retained
      // block loses its history; the alternative is two boxes on screen.
      // Batch-scoped NMS in `_dedup` never sees cached blocks; this is the
      // only cross-frame rule. Retention 0 is untouched: nothing is
      // retained to evict.
      final superseded = Set<T>.identity();
      for (final fresh in stableBlocks) {
        for (final cached in _supersessionCandidates(fresh)) {
          if (matchedExisting.contains(cached)) continue;
          if (_coversRetained(fresh, cached)) superseded.add(cached);
        }
      }
      final nextMissCounts = Map<T, int>.identity();
      for (final cached in _spatialIndex.allBlocks) {
        if (matchedExisting.contains(cached)) continue;
        if (superseded.contains(cached)) {
          droppedCount++;
          continue;
        }
        final misses = (_missCounts[cached] ?? 0) + 1;
        if (misses <= missedFrameRetention) {
          nextMissCounts[cached] = misses;
          retained.add(cached);
        } else {
          droppedCount++;
        }
      }
      _missCounts
        ..clear()
        ..addAll(nextMissCounts);
    } else {
      _missCounts.clear();
      // Retention 0: every cached identity nothing matched leaves the
      // index at the rebuild below.
      for (final cached in _spatialIndex.allBlocks) {
        if (!matchedExisting.contains(cached)) droppedCount++;
      }
    }

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
    );
  }

  // ┌─── Coherent-shift detection (#116, StepResponse.coherentShift) ────
  // A per-batch translation vote: among this capture's ordinary text
  // matches, find the ones whose drift-corrected displacement exceeds
  // their own agreement scale ("moved"), cluster the moved displacements,
  // and — if a big-enough, big-enough-a-share group agrees — return its
  // median displacement as the batch shift every member's merge applies.
  // Where that quorum declines, the two #119 opt-in fallbacks (the
  // absolute-pixel floor, then the batch-level re-anchor; both off by
  // default) get a turn, each re-anchoring its own members only. Whatever
  // plan is decided, `coherentShiftAdoptAgreeing` (#119 item 2, ON by
  // default since 2.4.0) then carries along the eligible under-gate pairs
  // that agree with it — membership widens, the translation never changes.
  // └──────────────────────────────────────────────────────────────────

  /// Detect a per-batch coherent shift among [matchResults] (a DRY,
  /// primary-match-only pre-pass `stabilize` computes just for this call
  /// — see its doc for why that pre-pass is safe to run ahead of this
  /// capture's merges).
  ///
  /// Returns `null` when [positionMergeModel] is not
  /// [PositionMergeModel.agreementWeighted] (legacy has no residual/scale
  /// concept to detect "moved" against — documented no-op, see
  /// [StepResponse]), when fewer than [coherentShiftMinBlocks] pairs moved
  /// at all, or when the largest valid window fails either
  /// [coherentShiftMinBlocks] or [coherentShiftMinShare] — unless one of
  /// the #119 opt-in fallbacks ([coherentShiftFloorPx], then
  /// [coherentShiftReanchorMinBlocks]) admits a group at one of those three
  /// decline points. Both are `null` by default, so the plain statement
  /// holds for the 2.3.0 configuration.
  ///
  /// **Eligible pairs** — ordinary text matches only: excludes band
  /// admissions and nested fragments (never in `matchResults` as a
  /// primary/band match to begin with is fine, but a match's own
  /// `wasBandFallback`/`wasNestedFragment` flag is checked explicitly for
  /// clarity), provisional existing blocks (their merge freezes
  /// regardless), viewport-relative blocks (a different coordinate
  /// contract — see [TrackedBlock.isViewportRelative]), and
  /// horizontal-scroll children (carousel motion is not page-scroll
  /// motion).
  ///
  /// **"Moved"** — the pair's drift-corrected displacement
  /// (`correctedRect.topLeft - existing.absoluteRect.raw.topLeft`, exactly
  /// what `_mergeImpl` computes) exceeds the existing block's own
  /// agreement scale ([_agreementScale]).
  ///
  /// **Frozen drift snapshot** (#116 finding C): each accepted member's
  /// `driftTracker.medianDriftForKey(spaceKey)` — the SAME value used
  /// above to compute its "moved" displacement and, transitively, the
  /// group's translation — is captured into the returned map alongside
  /// membership. `stabilize` threads it back into that member's real
  /// merge as `frozenRegionDrift`, so the translation this method votes
  /// on and the residual/`driftCorrection` that merge reports are always
  /// read from ONE snapshot. Without this, `_mergeImpl`'s own step 2
  /// recomputes `driftTracker.medianDriftForKey` LIVE against a tracker
  /// already mutated by any earlier same-capture merge in the real
  /// interleaved loop — which member merges first (and therefore whether
  /// the space key has crossed the tracker's 3-observation floor by the
  /// time a given member's merge runs) depends on arrival order, so the
  /// reported residual/confidence could silently diverge across
  /// otherwise-identical orderings even though the vote itself (fixed by
  /// finding B) does not.
  ///
  /// **Adoption** (#119 item 2, [coherentShiftAdoptAgreeing]): once a plan
  /// is decided — by the quorum or either fallback — the eligible pairs
  /// that sat UNDER the "moved" gate but whose displacement is within the
  /// quorum's tolerance of the decided translation are added to the
  /// returned map too. They are members of the MERGE, not of the vote:
  /// their displacement never entered the translation's median. The
  /// snapshot rule above is the same for them — the drift their
  /// displacement was computed with is the one frozen for their merge.
  ///
  /// **Clustering** (#116 finding B, 2026-08-29 rewrite — the original
  /// dy-only sort plus a single greedy incremental-median pass was
  /// caller-arrival-order dependent: two pairs with equal or near-equal
  /// dy have no secondary sort key, so which one a greedy scan visited
  /// first — and therefore which running-median state a later candidate
  /// was compared against — depended on the order fresh blocks arrived
  /// in, not on their values) — sort moved pairs by a deterministic total
  /// order over their VALUES: `(dy, dx, existing.top, existing.left,
  /// height)`, original index last as an always-harmless final tiebreak
  /// (two value-identical pairs always land in the same window
  /// regardless of their relative order). Then search every contiguous
  /// window of that order, LARGEST size first, for one whose members are
  /// all within `coherentShiftTolerance x min(member's own height, the
  /// window's OWN median height)` of the window's OWN median displacement
  /// (both axes, Euclidean) — validated against the window's FINAL
  /// membership, never an incremental running state. The first (largest,
  /// then leftmost-start) valid window wins; ties within a size resolve
  /// to the same window every time because the search itself is a fixed,
  /// deterministic sweep. This is one reasonable instantiation of the
  /// spec's pairwise "smaller block height" tolerance for a
  /// group-vs-candidate comparison; see the #116 PR description for the
  /// alternative (per-pair, not per-group) reading.
  _ShiftPlan<T>? _detectCoherentShift(
    List<
            ({
              T fresh,
              ({T? match, bool wasBandFallback, bool wasNestedFragment}) result
            })>
        matchResults,
  ) {
    if (positionMergeModel != PositionMergeModel.agreementWeighted) {
      return null;
    }

    final movedExisting = <T>[];
    final movedDx = <double>[];
    final movedDy = <double>[];
    final movedHeight = <double>[];
    final movedRegionDrift = <Offset>[];
    // #119 item 2: eligible pairs that sat under the "moved" gate, kept only
    // when [coherentShiftAdoptAgreeing] is on (see `adoptAgreeing` below).
    final agreeingExisting = <T>[];
    final agreeingDisplacement = <Offset>[];
    final agreeingHeight = <double>[];
    final agreeingRegionDrift = <Offset>[];
    for (final entry in matchResults) {
      final fresh = entry.fresh;
      final r = entry.result;
      final existing = r.match;
      if (existing == null) continue;
      if (r.wasNestedFragment || r.wasBandFallback) continue;
      if (existing.isProvisional) continue;
      if (fresh.isViewportRelative) continue;
      if (fresh.isHorizontalScrollChild || existing.isHorizontalScrollChild) {
        continue;
      }

      final spaceKey = driftTracker.spaceKeyFor(fresh);
      final regionDrift = driftTracker.medianDriftForKey(spaceKey);
      final correctedRect = DriftTracker.applyCorrectedPosition(
        fresh.absoluteRect.raw,
        regionDrift,
      );
      final displacement =
          correctedRect.topLeft - existing.absoluteRect.raw.topLeft;
      if (displacement.distance <= _agreementScale(existing)) {
        // #119 item 2: remember the under-gate pair — `adoptAgreeing`
        // below may carry it along once a translation has been decided.
        // Same frozen drift snapshot as a voter (#116 finding C).
        if (coherentShiftAdoptAgreeing) {
          agreeingExisting.add(existing);
          agreeingDisplacement.add(displacement);
          agreeingHeight.add(_blockHeight(existing));
          agreeingRegionDrift.add(regionDrift);
        }
        continue;
      }

      movedExisting.add(existing);
      movedDx.add(displacement.dx);
      movedDy.add(displacement.dy);
      movedHeight.add(_blockHeight(existing));
      // #116 finding C: the SAME snapshot that produced this member's
      // displacement above, frozen for its real merge later this capture.
      movedRegionDrift.add(regionDrift);
    }

    // The #119 absolute-pixel floor fallback is defined below
    // `searchWindow`, whose clustering it reuses (PR #129 review C1).

    // Deterministic total order (#116, finding B fix): (dy, dx,
    // existing.top, existing.left, height), original index last as an
    // always-harmless final tiebreak. The OLD algorithm sorted by dy
    // ALONE, so two pairs with equal (or near-equal) dy had no defined
    // relative order — the greedy scan below then compared a later
    // candidate against whichever running state that undefined order
    // produced, making the result depend on caller arrival order. This
    // order depends only on the pairs' own VALUES: two value-identical
    // pairs always land in the same window regardless of their relative
    // order between themselves, so the index tiebreak never actually
    // changes which window search below finds.
    final order = List<int>.generate(movedExisting.length, (i) => i)
      ..sort((a, b) {
        var c = movedDy[a].compareTo(movedDy[b]);
        if (c != 0) return c;
        c = movedDx[a].compareTo(movedDx[b]);
        if (c != 0) return c;
        c = movedExisting[a]
            .absoluteRect
            .raw
            .top
            .compareTo(movedExisting[b].absoluteRect.raw.top);
        if (c != 0) return c;
        c = movedExisting[a]
            .absoluteRect
            .raw
            .left
            .compareTo(movedExisting[b].absoluteRect.raw.left);
        if (c != 0) return c;
        c = movedHeight[a].compareTo(movedHeight[b]);
        if (c != 0) return c;
        return a.compareTo(b);
      });

    // Find the LARGEST contiguous (in the deterministic order above)
    // window of at least [minSize] whose members all sit within
    // `coherentShiftTolerance x min(member's own height, the window's OWN
    // median height)` of the window's OWN median displacement — validated
    // against the window's FINAL membership, never an incremental running
    // state a scan order could bias (the old bug). Search sizes
    // largest-first so the first valid window found is the largest; ties
    // within a size break toward the leftmost (smallest start index)
    // window in the deterministic order, so the search is fully
    // reproducible.
    //
    // Parameterised on [minSize] (#119) purely so the re-anchor fallback
    // below can reuse the identical clustering at its own count — the
    // quorum path passes [coherentShiftMinBlocks] and is unchanged. The
    // optional [among] (PR #129 review C1) restricts the scan to a subset
    // of `order` — the floor fallback clusters only its floor-qualified
    // movers — and MUST already be in `order`'s sequence.
    List<int>? searchWindow(int minSize, {List<int>? among}) {
      final scan = among ?? order;
      for (var size = scan.length; size >= minSize; size--) {
        for (var start = 0; start + size <= scan.length; start++) {
          final window = scan.sublist(start, start + size);
          final wDx = RobustStats.median([for (final j in window) movedDx[j]]);
          final wDy = RobustStats.median([for (final j in window) movedDy[j]]);
          final wHeight =
              RobustStats.median([for (final j in window) movedHeight[j]]);
          // Only reachable if `window` were empty — `size` never goes
          // below `minSize`, which the constructor already enforces to be
          // >= 1 for both callers (finding E: explicit non-null handling
          // instead of a force-unwrap that would crash on this case).
          if (wDx == null || wDy == null || wHeight == null) continue;
          final valid = window.every((j) {
            final tol = coherentShiftTolerance * min(movedHeight[j], wHeight);
            final diff = Offset(movedDx[j] - wDx, movedDy[j] - wDy).distance;
            return diff <= tol;
          });
          if (valid) return window;
        }
      }
      return null;
    }

    // ┌─── #119: the absolute-pixel floor fallback ────────────────────
    // Tried ONLY where the ordinary quorum below declines (all three of
    // its `return null` sites route here instead). Ordering matters: when
    // a real group DOES qualify, the well-validated majority vote wins
    // untouched, so enabling the floor cannot perturb any capture the
    // quorum already handles — the floor is reachable only on captures
    // that were falling through to damp anyway. See
    // [coherentShiftFloorPx]'s doc for why the discriminating axis has to
    // be absolute pixels rather than another multiple of the block's own
    // height.
    _ShiftPlan<T>? floorFallback() {
      final floor = coherentShiftFloorPx;
      if (floor == null) return null;

      final qualified = <int>{};
      for (var i = 0; i < movedExisting.length; i++) {
        if (Offset(movedDx[i], movedDy[i]).distance >= floor) {
          qualified.add(i);
        }
      }
      if (qualified.isEmpty) return null;

      // Direction agreement. A slab translates its content ONE way; two
      // floor-qualified movers heading opposite ways are not a shift, and
      // their median is a translation neither of them made. Checked per
      // axis, ignoring components small enough to be jitter rather than
      // travel, so a pair agreeing on dy but disagreeing on a sub-pixel
      // dx is still a group. A single member is vacuously in agreement —
      // which is the whole point of this path, since the starved-quorum
      // case is precisely "only one mover survived the match".
      var sawPos = false, sawNeg = false;
      for (final j in qualified) {
        if (movedDy[j] > _kDirectionEpsilonPx) sawPos = true;
        if (movedDy[j] < -_kDirectionEpsilonPx) sawNeg = true;
      }
      if (sawPos && sawNeg) return null;
      sawPos = false;
      sawNeg = false;
      for (final j in qualified) {
        if (movedDx[j] > _kDirectionEpsilonPx) sawPos = true;
        if (movedDx[j] < -_kDirectionEpsilonPx) sawNeg = true;
      }
      if (sawPos && sawNeg) return null;

      // Magnitude agreement (PR #129 review C1 / C5). Direction alone let
      // a +35 mover be re-anchored by a +110 group median — 37.5 px PAST
      // its own observation, worse than damp — and let a purely
      // horizontal and a purely vertical mover "agree" and drag each other
      // diagonally. So the floor-qualified movers are clustered with the
      // SAME tolerance rule the quorum uses, at a minimum size of ONE (a
      // lone mover is its own cluster — the starved-quorum case this path
      // exists for), and only the winning cluster is re-anchored; every
      // other qualified mover stays on damp. A size-1 window always
      // validates (its member IS its median), so for a non-empty set the
      // search cannot come back empty — the null check is belt and braces.
      final group = searchWindow(1, among: [
        for (final j in order)
          if (qualified.contains(j)) j
      ]);
      if (group == null) return null;

      // Non-null by construction: `group` is non-empty, and
      // `RobustStats.median` returns null only on an empty list — the
      // same argument the quorum path's own force-unwraps rest on.
      final tx = RobustStats.median([for (final j in group) movedDx[j]])!;
      final ty = RobustStats.median([for (final j in group) movedDy[j]])!;
      // Identity-keyed for the same reason the quorum path's map is: `T`
      // is the CONSUMER's type and may define VALUE equality, and two
      // members in different drift regions must each keep their own
      // frozen snapshot.
      final memberDrift = Map<T, Offset>.identity();
      for (final j in group) {
        memberDrift[movedExisting[j]] = movedRegionDrift[j];
      }
      return (
        translation: Offset(tx, ty),
        memberDrift: memberDrift,
        adopted: Set<T>.identity(),
        source: CoherentShiftSource.floor,
      );
    }

    // ┌─── #119 candidate 2: the batch-level re-anchor ────────────────
    // The other axis the starved quorum could be relaxed on: keep the
    // tolerance clustering exactly as it is, drop the SHARE gate outright,
    // and lower only the COUNT required to act — then apply the winning
    // cluster's median displacement to its own members alone, leaving
    // every other pair in the batch on damp. No magnitude axis at all,
    // which is precisely what distinguishes it from
    // [coherentShiftFloorPx]. Tried after the floor, so a consumer that
    // sets both gets the magnitude-gated answer first.
    _ShiftPlan<T>? reanchorFallback() {
      final minN = coherentShiftReanchorMinBlocks;
      if (minN == null) return null;
      final group = searchWindow(minN);
      if (group == null) return null;
      // Non-null by construction, same argument as the quorum path's own
      // force-unwraps: `group` is a non-empty window (`minN >= 1` is
      // enforced at construction) and `RobustStats.median` returns null
      // only on an empty list.
      final tx = RobustStats.median([for (final j in group) movedDx[j]])!;
      final ty = RobustStats.median([for (final j in group) movedDy[j]])!;
      final memberDrift = Map<T, Offset>.identity();
      for (final j in group) {
        memberDrift[movedExisting[j]] = movedRegionDrift[j];
      }
      return (
        translation: Offset(tx, ty),
        memberDrift: memberDrift,
        adopted: Set<T>.identity(),
        source: CoherentShiftSource.reanchor,
      );
    }

    // ┌─── #119 item 2: adopt the agreeing under-gate pairs ─────────────
    // Runs on whatever plan the quorum or a fallback decided; a null plan
    // stays null. Membership only widens — no translation changes, and no
    // pair that could not vote gets a vote. The tolerance is the quorum's
    // own rule (`coherentShiftTolerance x min(own height, the group's
    // median height)`), measured against the DECIDED translation, so an
    // under-gate pair that merely moved a little (ordinary jitter) is left
    // on damp and is never pushed past its own observation. The adopted
    // pair's frozen drift snapshot is the one its displacement was computed
    // with (#116 finding C), like every voting member's.
    _ShiftPlan<T>? adoptAgreeing(_ShiftPlan<T>? plan) {
      if (plan == null || !coherentShiftAdoptAgreeing) return plan;
      if (agreeingExisting.isEmpty) return plan;
      final groupHeight = RobustStats.median(
          [for (final member in plan.memberDrift.keys) _blockHeight(member)]);
      // Null only for an empty group, which no path above produces.
      if (groupHeight == null) return plan;
      final t = plan.translation;
      for (var i = 0; i < agreeingExisting.length; i++) {
        final tol =
            coherentShiftTolerance * min(agreeingHeight[i], groupHeight);
        final diff = (agreeingDisplacement[i] - t).distance;
        if (diff > tol) continue;
        plan.memberDrift[agreeingExisting[i]] = agreeingRegionDrift[i];
        plan.adopted.add(agreeingExisting[i]);
      }
      return plan;
    }

    // Too few movers for the quorum to have anything to cluster. Kept
    // here (rather than before the deterministic ordering above, where it
    // sat pre-#119) so both fallbacks and `adoptAgreeing` — local closures
    // defined above — are in scope, and because `adoptAgreeing` must run
    // AFTER the match loop that fills the under-gate list it reads; the
    // ordering computation it now runs after is pure, so the quorum path's
    // behaviour is unchanged.
    if (movedExisting.length < coherentShiftMinBlocks) {
      return adoptAgreeing(floorFallback() ?? reanchorFallback());
    }

    final bestGroup = searchWindow(coherentShiftMinBlocks);

    if (bestGroup == null) {
      return adoptAgreeing(floorFallback() ?? reanchorFallback());
    }
    if (bestGroup.length / movedExisting.length < coherentShiftMinShare) {
      return adoptAgreeing(floorFallback() ?? reanchorFallback());
    }

    // #116 finding E: these two force-unwraps are safe by construction,
    // not merely by argument — `bestGroup` is non-null (checked above)
    // and non-empty: every window searched has `size >= coherentShiftMinBlocks`,
    // and the constructor rejects `coherentShiftMinBlocks < 1` (see
    // `StepResponse`'s validation), so `bestGroup.length >= 1` always.
    // `RobustStats.median` returns null ONLY on an empty list — never on
    // a non-empty one — so these two calls can never actually return
    // null here.
    final tx = RobustStats.median([for (final j in bestGroup) movedDx[j]])!;
    final ty = RobustStats.median([for (final j in bestGroup) movedDy[j]])!;
    // #116 finding C: one map carries both membership AND each member's
    // frozen drift snapshot -- a single source of truth `stabilize` reads
    // for both membership (`containsKey`) and `frozenRegionDrift` (the
    // value itself). Two parallel collections built from the same loop
    // could fall out of sync under a later edit; a missing key here
    // would silently fall back to a live tracker read in `_mergeImpl`
    // with nothing red.
    //
    // Identity-keyed like every other `T` collection in this engine
    // (`matchedExisting`, the classification/carousel vote maps, the
    // contradicted-hosts set, ...) -- `T` is the CONSUMER's type and may
    // define VALUE equality (an Equatable-style block keyed on
    // `originalText` only). Two coherent-shift members that are
    // `==`-equal but sit in DIFFERENT drift regions must each keep their
    // OWN frozen snapshot; a value-keyed map collapses them onto one
    // entry and silently overwrites one member's snapshot with the
    // other's.
    final memberDrift = Map<T, Offset>.identity();
    for (final j in bestGroup) {
      memberDrift[movedExisting[j]] = movedRegionDrift[j];
    }
    return adoptAgreeing((
      translation: Offset(tx, ty),
      memberDrift: memberDrift,
      adopted: Set<T>.identity(),
      source: CoherentShiftSource.quorum,
    ));
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

  // ── Dedup pipeline ──────────────────────────────────────────────────

  /// Filter noise and remove intra-batch duplicates.
  ///
  /// Pipeline:
  /// 1. Noise filter — skip empty/whitespace-only text
  /// 2. Key-based intra-batch dedup — same OCR frame producing identical
  ///    position+text twice
  /// 3. Spatial overlap NMS — when two batch blocks overlap, higher quality
  ///    or higher hierarchy weight wins
  ({List<T> blocks, SpatialBlockIndex<T> batchIndex}) _dedup(List<T> blocks) {
    final out = <T>[];
    final seenKeys = <String>{};
    // Key each *kept* block was registered under, so an evicted block's
    // key can be retired with it. Identity-keyed: consumer blocks may
    // implement value equality (#50).
    final keptKeys = Map<T, String>.identity();
    // Per-batch spatial grid mirroring `out` (#55): overlap lookup was a
    // linear scan of the whole output per fresh block — O(n²) with a
    // drift-margin computation per pair. The grid makes it O(cells).
    // Bucket sizes adopt the main index's so quantization stays uniform.
    // Note the grid's 3×3-neighborhood semantics: a pair whose centers
    // sit more than one cell apart is not considered overlapping — the
    // same locality contract the inter-capture matching path already
    // uses via [SpatialBlockIndex.candidates].
    final batchIndex = SpatialBlockIndex<T>()..adoptBucketSizes(_spatialIndex);

    for (final b in blocks) {
      // 1. Noise filter: skip blocks with empty/whitespace-only text
      if (b.originalText.trim().isEmpty) continue;

      // 2. Key-based intra-batch dedup
      final key = BlockKeyGenerator.keyFor(
        b,
        bucketWidth: bucketWidth,
        bucketHeight: bucketHeight,
        scale: scale,
      );
      if (seenKeys.contains(key)) continue;

      // Also check ±1 neighbor buckets for boundary-straddling duplicates
      if (_isKeySeenFuzzy(key, seenKeys, b)) continue;

      // 3. Spatial overlap NMS within the batch. Keys are registered
      // only for blocks that survive NMS — a dropped block's key must
      // not suppress later same-bucket blocks, and an evicted block's
      // key retires with it (#50).
      final overlapping = _findBatchOverlap(b, batchIndex);
      if (overlapping != null) {
        final result = _resolver.resolveOverlap(
          incoming: b,
          existing: overlapping,
          driftMargin: driftTracker.driftMarginForKey(
            driftTracker.spaceKeyFor(b),
          ),
          confidenceMad: 0.1,
        );
        switch (result) {
          case OverlapResult.evict:
            // Identity-based lookup: indexOf uses ==, which for
            // value-equal consumer blocks can hit a different element
            // than the one NMS resolved against (#50).
            final idx = _identityIndexOf(out, overlapping);
            out[idx] = b;
            batchIndex.remove(overlapping);
            batchIndex.add(b);
            final evictedKey = keptKeys.remove(overlapping);
            if (evictedKey != null) seenKeys.remove(evictedKey);
            seenKeys.add(key);
            keptKeys[b] = key;
          case OverlapResult.keep:
            out.add(b);
            batchIndex.add(b);
            seenKeys.add(key);
            keptKeys[b] = key;
          case OverlapResult.drop:
            // Discard incoming — key intentionally not registered.
            break;
        }
      } else {
        out.add(b);
        batchIndex.add(b);
        seenKeys.add(key);
        keptKeys[b] = key;
      }
    }
    return (blocks: out, batchIndex: batchIndex);
  }

  /// Index of [target] in [list] by object identity (never `==`).
  static int _identityIndexOf<E>(List<E> list, E target) {
    for (var i = 0; i < list.length; i++) {
      if (identical(list[i], target)) return i;
    }
    throw StateError(
      'NMS invariant: resolved overlap target not found in batch output — '
      'the existing block returned by _findBatchOverlap must be present '
      'in `out` by identity.',
    );
  }

  /// Check if [block] has a fuzzy key match (±1 bucket) in [seenKeys].
  bool _isKeySeenFuzzy(String key, Set<String> seenKeys, T block) {
    final neighbors = BlockKeyGenerator.neighborKeys(
      block,
      bucketWidth: bucketWidth,
      bucketHeight: bucketHeight,
      scale: scale,
    );
    return neighbors.any(seenKeys.contains);
  }

  /// Find an overlapping block among [batchIndex]'s grid-neighborhood
  /// candidates for [block] (#55 — replaces the O(n²) full-batch scan).
  T? _findBatchOverlap(T block, SpatialBlockIndex<T> batchIndex) {
    final threshold = _resolver.overlapThresholdFor(block);
    final dm = driftTracker.driftMarginForKey(driftTracker.spaceKeyFor(block));
    for (final existing in batchIndex.candidates(block)) {
      final match = _resolver.checkOverlap(
        block,
        block.absoluteRect,
        existing,
        threshold,
        dm,
      );
      if (match != null) return match;
    }
    return null;
  }

  /// Least share of a retained block's own area one fresh block must cover
  /// to supersede it. Script-independent on purpose: the resolver's
  /// per-script NMS threshold gives CJK-dominant text its LOOSEST value
  /// (0.35), which is right for matching jittery boxes of the same text
  /// and wrong here, where the texts differ — a sliver covering 40% of a
  /// CJK block must not evict it while an equal Latin block survives.
  static const double _kSupersessionCoverageFloor = 0.5;

  /// Cached blocks a fresh block could supersede: every block whose cell
  /// intersects the fresh block's RECT (plus the index's one-cell margin),
  /// not just the 3×3 cells around the fresh block's centre — a tall
  /// paragraph covers blocks whose cells sit far from its centre cell.
  /// [SpatialIndexView.candidates] is added for the viewport-relative
  /// namespace, which [SpatialIndexView.blocksInRegion] excludes.
  Iterable<T> _supersessionCandidates(T fresh) sync* {
    final seen = Set<T>.identity();
    for (final b in _spatialIndex.blocksInRegion(fresh.absoluteRect.raw)) {
      if (seen.add(b)) yield b;
    }
    for (final b in _spatialIndex.candidates(fresh)) {
      if (seen.add(b)) yield b;
    }
  }

  /// Cross-frame supersession test (2.1.0): does [fresh] cover enough of
  /// [cached]'s OWN area to say the cached region has been replaced?
  ///
  /// Deliberately not the smaller-area ratio `checkOverlap` uses for
  /// batch NMS: there a small fresh box inside a large cached one would
  /// score 1.0 and evict a paragraph because one of its lines was
  /// reported. The bar is [_kSupersessionCoverageFloor] (half of the
  /// cached block's own area), raised to the resolver's per-script NMS
  /// threshold only where that is stricter (short Latin snippets, 0.65).
  /// No drift margin is applied (a margin only makes eviction easier, and
  /// the fail-safe direction here is to retain). The two coordinate
  /// contracts `checkOverlap` refuses to compare are refused here too:
  /// viewport-relative vs page-absolute blocks, and blocks from different
  /// carousels.
  bool _coversRetained(T fresh, T cached) {
    if (fresh.isViewportRelative != cached.isViewportRelative) return false;
    if (fresh.isHorizontalScrollChild &&
        cached.isHorizontalScrollChild &&
        fresh.scrollContext.hzScrollerIndex !=
            cached.scrollContext.hzScrollerIndex) {
      return false;
    }
    final f = fresh.absoluteRect.raw;
    final c = cached.absoluteRect.raw;
    final cachedArea = c.width * c.height;
    if (!(cachedArea > 0)) return false;
    final inter = f.intersect(c);
    if (inter.isEmpty) return false;
    final covered = inter.width * inter.height;
    final scriptThreshold = _resolver.overlapThresholdFor(cached);
    final threshold = scriptThreshold > _kSupersessionCoverageFloor
        ? scriptThreshold
        : _kSupersessionCoverageFloor;
    return covered / cachedArea >= threshold;
  }

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
  bool _isNestedFragmentOf(T fresh, T cached) {
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
  T? _findNestedHost(T fresh) {
    T? best;
    var bestArea = double.infinity;
    for (final cached in _supersessionCandidates(fresh)) {
      if (!_isNestedFragmentOf(fresh, cached)) continue;
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
  /// [BandFallbackConfig.bandJaccardFloor]) in the same iteration. This
  /// eliminates the double `isTextSimilarWithScores` call that the old
  /// two-loop design incurred on primary misses.
  ///
  /// Primary path: highest-Levenshtein candidate that clears primary thresholds
  /// wins. Band path (only when [bandFallback.mode] != [BandFallbackMode.off]):
  /// first candidate that clears the observation-count floor, spatial confirm,
  /// AND band text floors is admitted ([BandFallbackMode.admit]) or tallied
  /// ([BandFallbackMode.observeOnly]).
  ///
  /// Nested re-observation (#112): only when BOTH the primary and the band
  /// path miss, a fresh block that is a nested fragment of an established
  /// block ([_findNestedHost]) matches that block with `wasNestedFragment`
  /// set, so the merge is a confirming observation only.
  ///
  /// [recordStats] / [allowBandFallback] / [allowNestedFallback] (#116,
  /// finding A fix): the DRY pre-pass `stabilize` runs to feed
  /// `_detectCoherentShift` a full-capture snapshot calls this with all
  /// three `false`. That pre-pass must never mutate [_internalStats] (the
  /// REAL, interleaved call below ticks every counter exactly once per
  /// fresh block) and must never evaluate the band branch (which reads
  /// `driftTracker` — see `stabilize`'s own doc for why only the PRIMARY
  /// check, which touches neither, is safe to run ahead of this capture's
  /// merges). Skipping the nested-fragment lookup too is a pure perf
  /// saving: `_detectCoherentShift` already discards `wasNestedFragment`
  /// matches, so computing one in the dry pass is wasted work, never a
  /// correctness difference. Every default reproduces today's single-mode
  /// behavior exactly.
  ({T? match, bool wasBandFallback, bool wasNestedFragment}) _findMatch(
    T fresh, {
    bool recordStats = true,
    bool allowBandFallback = true,
    bool allowNestedFallback = true,
  }) {
    final candidates = _spatialIndex.candidates(fresh);
    final shouldRunBand =
        allowBandFallback && bandFallback.mode != BandFallbackMode.off;

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
        // primary floors (Lev 0.70, Jacc 0.80) — engine-owned defaults,
        // matching the existing TextDedupUtils.isTextSimilar defaults.
      );

      // ── Primary check ──
      if (scores.match) {
        // Pick the highest Lev-scoring candidate (Jaccard is a parallel
        // metric for admission, not a primary ordering signal).
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
      if (bandFallback.mode == BandFallbackMode.admit && bandAdmitted != null) {
        continue;
      }

      _internalStats.recordCandidateConsidered();

      if (candidate.observationCount < bandFallback.candidateObservationFloor) {
        _internalStats.recordRejectedCandidateFloor();
        continue;
      }
      bool spatialOk;
      if (_consumerSpatialConfirmInUse) {
        try {
          spatialOk = _effectiveSpatialConfirm(fresh, candidate);
        } catch (error, stack) {
          // Consumer-supplied predicate threw. Per BandSpatialPredicate's
          // documented contract, predicates must not throw — but if one
          // does, surface it as a typed BandPredicateException so the
          // consumer can distinguish predicate failures from
          // engine-internal errors. No silent swallow.
          //
          // The catch is intentionally scoped to consumer code only: any
          // throw from _defaultSpatialConfirm (engine-internal default
          // closure that calls _resolver.overlapRatio + driftTracker
          // helpers) must propagate with its real type so engine
          // regressions are not misattributed as predicate failures.
          throw BandPredicateException(error, stack);
        }
      } else {
        spatialOk = _effectiveSpatialConfirm(fresh, candidate);
      }
      if (!spatialOk) {
        _internalStats.recordRejectedSpatial();
        continue;
      }
      // Test the same scores against the band thresholds directly — avoids a
      // second isTextSimilarWithScores call. Semantically equivalent to
      // calling isTextSimilarWithScores with levenshteinThreshold: bandLev,
      // jaccardThreshold: bandJacc (OR logic mirrors the primary check).
      final bandMatches =
          scores.levenshtein >= bandFallback.bandLevenshteinFloor ||
              scores.jaccard >= bandFallback.bandJaccardFloor;
      if (!bandMatches) {
        _internalStats.recordRejectedTextBand();
        continue;
      }
      _internalStats.recordBandMatchIdentified();
      if (bandFallback.mode == BandFallbackMode.admit) {
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
      if (recordStats) _internalStats.recordPrimaryMatchAdmitted();
      return (
        match: primaryMatch,
        wasBandFallback: false,
        wasNestedFragment: false,
      );
    }
    // Tick on every primary miss, including empty-candidate-set cases.
    // Holds the spec invariant:
    //   primaryMatchesAdmitted + primaryMatchesRejected
    //     == total fresh observations that reached _findMatch.
    // Consumers compute "band fires as % of primary misses" as
    // `bandMatchesIdentified / primaryMatchesRejected` — undercounting
    // here would skew that ratio. (Gated on [recordStats] — the dry
    // pre-pass calls this with `recordStats: false` and must not tick it;
    // the real, interleaved call always passes the default `true`.)
    if (recordStats) _internalStats.recordPrimaryMatchRejected();

    // ── Return band outcome ──
    if (shouldRunBand && bandAdmitted != null) {
      _internalStats.recordMatchAdmitted();
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
    final host = _findNestedHost(fresh);
    if (host != null) {
      return (match: host, wasBandFallback: false, wasNestedFragment: true);
    }
    return (match: null, wasBandFallback: false, wasNestedFragment: false);
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
  /// [wasBandFallback] flows through from `_findMatch`'s record return —
  /// `true` when the match came via the band-relaxed fallback path. When set,
  /// `_mergeImpl` marks the merged result as provisional with
  /// `bandFallback.provisionalCaptures` remaining (see `_mergeImpl` for the
  /// wrap semantics).
  ///
  /// [coherentShiftTranslation] — non-null only when [stepResponse] is
  /// [StepResponse.coherentShift] AND [existing] is a member of this
  /// batch's qualifying shift group (see `stabilize`'s
  /// `_detectCoherentShift` call). Threaded straight to `_mergeImpl`.
  ///
  /// [frozenRegionDrift] — (#116 finding C) non-null in lockstep with
  /// [coherentShiftTranslation]: the drift snapshot `_detectCoherentShift`
  /// used to compute THIS member's displacement, threaded through so
  /// `_mergeImpl` reads the same snapshot instead of re-reading (and
  /// potentially getting a different answer from) the live tracker.
  T _merge(
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
    return output.merged;
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
  /// SAME snapshot `_detectCoherentShift` used to vote the translation —
  /// never a tracker already mutated by an earlier same-capture merge in
  /// this capture's interleaved loop (see `_detectCoherentShift`'s
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
    // is never provisional (`_isNestedFragmentOf` requires an established
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
        updatedCarouselIdVotes: existing.carouselIdVotes,
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
        updatedCarouselIdVotes: existing.carouselIdVotes,
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
    // (the one `_detectCoherentShift` used to vote the translation) here
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
    //    [positionMergeModel], #58).
    //
    // Step response (#116): resolve the effective merge baseline and
    // weight before the lerp. Scoped to PositionMergeModel.agreementWeighted
    // (legacy has no residual/scale concept to gate either option on — see
    // StepResponse's doc) and to ordinary matches only: [wasBandFallback]
    // excludes a band admission (the freeze and nested-fragment paths
    // above already returned before this line for their own cases).
    var baselineRect = existing.absoluteRect.raw;
    var w = _positionMergeWeight(fresh, existing);
    double? residualOverride;
    StepResponse? appliedStepResponse;
    // #116 finding D: the VR/carousel-child exclusion mirrors
    // `_detectCoherentShift`'s own eligible-pairs filter exactly (see that
    // method's doc). Gating the SHARED flag rather than only the
    // coherentShift branch below also closes snap's exclusion — snap had
    // none before this fix, while coherentShift was already effectively
    // covered (a VR/carousel `existing` never enters
    // `_detectCoherentShift`'s `memberDrift` map in the first place, so
    // `coherentShiftTranslation` is already null for it regardless).
    final stepResponseEligible = !wasBandFallback &&
        positionMergeModel == PositionMergeModel.agreementWeighted &&
        !fresh.isViewportRelative &&
        !fresh.isHorizontalScrollChild &&
        !existing.isHorizontalScrollChild;

    if (stepResponseEligible && stepResponse == StepResponse.snap) {
      final residual = (correctedRect.topLeft - baselineRect.topLeft).distance;
      final scale = _agreementScale(existing);
      if (residual > snapThresholdMultiplier * scale) {
        w = 1.0;
        residualOverride = 0.0;
        appliedStepResponse = StepResponse.snap;
      }
    } else if (stepResponseEligible &&
        stepResponse == StepResponse.coherentShift &&
        coherentShiftTranslation != null) {
      baselineRect = baselineRect.translate(
        coherentShiftTranslation.dx,
        coherentShiftTranslation.dy,
      );
      appliedStepResponse = StepResponse.coherentShift;
    }

    final mergedRaw = Rect.lerp(baselineRect, correctedRect, w)!;

    // 4a. Classification vote accumulation
    final classVotes = Map<int, int>.from(existing.classificationVotes);
    classVotes[fresh.hierarchyWeight] =
        (classVotes[fresh.hierarchyWeight] ?? 0) + 1;
    final bestWeight =
        classVotes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final needsReclass = bestWeight != existing.hierarchyWeight;

    // 4b. Carousel ID vote accumulation
    final carouselVotes = Map<int, int>.from(existing.carouselIdVotes);
    final freshHzIdx = fresh.scrollContext.hzScrollerIndex;
    // Clear phantom non-carousel vote on first real carousel observation
    if (freshHzIdx != -1 &&
        carouselVotes.length == 1 &&
        carouselVotes[-1] == 1) {
      carouselVotes.remove(-1);
    }
    carouselVotes[freshHzIdx] = (carouselVotes[freshHzIdx] ?? 0) + 1;

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
      _mergedPositionConfidence(
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
      updatedCarouselIdVotes: Map.unmodifiable(carouselVotes),
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
    );
  }

  // ── Contradiction detection ───────────────────────────────────────

  /// Minimum observation count for a cached block to be considered
  /// well-observed (eligible for contradiction detection).
  static const int _kMinObsForContradiction = 3;

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
    // [stabilize] path passes the batch grid `_dedup` already built for
    // NMS instead of constructing a second one per capture (#55).
    if (freshBlocks.length < 2) return const [];
    final freshIndex = SpatialBlockIndex<T>()..adoptBucketSizes(_spatialIndex);
    freshIndex.rebuild(freshBlocks);
    return _detectGroupingContradictions(freshBlocks, freshIndex);
  }

  List<ContradictionEvent<T>> _detectGroupingContradictions(
    List<T> freshBlocks,
    SpatialBlockIndex<T> freshIndex,
  ) {
    if (freshBlocks.length < 2) return const [];

    final events = <ContradictionEvent<T>>[];

    // Scan all cached blocks via the engine's spatial index
    for (final cached in _spatialIndex.allBlocks) {
      if (cached.observationCount < _kMinObsForContradiction) continue;

      // VR blocks live in a different coordinate contract (viewport-
      // relative, not page-absolute) and blocksInRegion never returns VR
      // fresh blocks — so any "subdividers" found for a VR cached block
      // are numeric coincidences (e.g. near scroll offset 0, where the
      // two spaces coincide), not evidence. Same guard the matching path
      // and OverlapResolver.checkOverlap already apply (#49).
      if (cached.isViewportRelative) continue;

      final cRect = cached.absoluteRect.raw;
      if (cRect.width <= 0 || cRect.height <= 0) continue;

      // O(cells) spatial query against fresh index
      final nearby = freshIndex.blocksInRegion(cRect);

      // Height pre-filter: only blocks shorter than 70% of cached (subdivisions)
      // and overlap ≥30%.
      final cArea = cRect.width * cRect.height;
      final subdividers = <T>[];
      for (final fresh in nearby) {
        final fRect = fresh.absoluteRect.raw;
        if (fRect.height >= cRect.height * 0.7) continue;
        final intersection = cRect.intersect(fRect);
        if (intersection.isEmpty) continue;
        if ((intersection.width * intersection.height) / cArea < 0.3) continue;
        subdividers.add(fresh);
      }
      if (subdividers.length < 2) continue;

      // Sort by reading order before text comparison
      subdividers.sort(
        (a, b) => a.absoluteRect.raw.top.compareTo(b.absoluteRect.raw.top),
      );
      final sortedText = subdividers.map((b) => b.originalText).join(' ');

      final textSim = TextDedupUtils.normalizedLevenshtein(
        cached.originalText,
        sortedText,
      );
      if (textSim < 0.60) continue;

      events.add(
        ContradictionEvent<T>(
          type: ContradictionType.grouping,
          target: cached,
          evidence: subdividers,
        ),
      );
    }
    return events;
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
    if (freshBlocks.isEmpty) return const [];

    final events = <ContradictionEvent<T>>[];
    final alreadyTargeted = <T>{};

    for (final fresh in freshBlocks) {
      // VR fresh blocks carry viewport-relative coordinates; the cached
      // blocks returned by blocksInRegion are page-absolute (VR cached
      // blocks live in a separate cell namespace and are never returned).
      // Comparing across the two contracts can only produce false
      // "subsumed" evidence near scroll offset 0 (#49).
      if (fresh.isViewportRelative) continue;

      final fRect = fresh.absoluteRect.raw;
      if (fRect.width <= 0 || fRect.height <= 0) continue;

      // O(cells) query against existing cached spatial index
      final nearby = _spatialIndex.blocksInRegion(fRect);

      final subsumed = <T>[];
      for (final cached in nearby) {
        if (cached.observationCount < _kMinObsForContradiction) continue;
        if (alreadyTargeted.contains(cached)) continue;

        final cRect = cached.absoluteRect.raw;
        if (cRect.height >= fRect.height * 0.7) continue;
        final cArea = cRect.width * cRect.height;
        if (cArea <= 0) continue;

        final intersection = fRect.intersect(cRect);
        if (intersection.isEmpty) continue;

        final containment = (intersection.width * intersection.height) / cArea;
        if (containment >= 0.80) {
          subsumed.add(cached);
        }
      }
      if (subsumed.length < 2) continue;

      // Sort by reading order before text comparison
      subsumed.sort(
        (a, b) => a.absoluteRect.raw.top.compareTo(b.absoluteRect.raw.top),
      );
      final sortedText = subsumed.map((b) => b.originalText).join(' ');

      final textSim = TextDedupUtils.normalizedLevenshtein(
        fresh.originalText,
        sortedText,
      );
      if (textSim < 0.60) continue;

      alreadyTargeted.addAll(subsumed);
      events.add(
        ContradictionEvent<T>(
          type: ContradictionType.splitting,
          target: fresh,
          evidence: subsumed,
        ),
      );
    }
    return events;
  }
}
