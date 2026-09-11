<!-- Relocated from README.md in #144 (2026-09-08): the README keeps the
     quick start; reference material lives here. Content unchanged. -->

# Release notes — what each version changed for a consumer

The narrative "What's new" entries that used to open the README, newest
first. The authoritative per-version record is [`../CHANGELOG.md`](../CHANGELOG.md).

**What's new in 3.0.0** — the adoption release: the same engine, a
surface a stranger can pick up in an hour. Four breaking, mechanical
changes, each with a migration table in the CHANGELOG:
`StabilizerConfig` replaces the engine's twelve lever parameters, grouped
by stage (the two calibration-dependent coherent-shift levers sit under
`CoherentShiftConfig.experimental`); `CarouselVotes` replaces the
`{-1: 1}` phantom-vote sentinel a block type had to default to;
`CoordinateContext` — `page(scroll:)`, `innerScroller(top:, containerId:,
scroll:)`, `viewport(stickyFallback:)` — replaces the eight coordinate
flags, so the combinations the engine never expected are unrepresentable
(the flags survive as derived views, and `fromFlags` adapts a flat-flag
block type); and the two block interfaces now say what they are —
`Observation<T>` (the 7 getters you supply per capture) and `Track<T>`
(an observation plus the engine's state). `DefaultTrackedBlock` needs
four arguments to feed a capture. No numerics changed: every committed
replay stream is byte-identical to 2.6.1
([#145](https://github.com/Abdallah01/ocr-stabilizer/issues/145)).

**What's new in 2.6.0** — every result reports a similarity-transform
estimate over the capture's matched pairs, `result.transformEstimate`
(a `TransformEstimate`: isotropic `scale`, `translation`, `fixedPoint`,
`pairCount`, `rejectedPairs`, `residualPx`, `spanPx`,
`largestGapShare`; `null` under three eligible pairs) — observed and
never applied: the merge keeps
its no-zoom model ([`doc/CONTRACT.md`](CONTRACT.md) G11, U9). A
layout layer that holds geometry the engine never sees can read a
browser zoom or a DPR change from one value and rescale, instead of
inspecting every block. The zoom corpus entry
([`doc/replay/validation/2026-09-zoom/`](replay/validation/2026-09-zoom/EXPERIMENT.md))
states the reading rule — `|scale − 1| ≥ 0.10`, `residualPx ≤ 10`,
`largestGapShare ≤ 0.5`, `pairCount ≥ 6` — and its margins: a 1.25x
and a 0.8x zoom read at 0.249 / 0.200 deviation with residuals under
4 px, and no control capture in the repository exceeds 0.010 under
those bounds. Its limit is stated with it: matched lines that form
two clusters fit a step and a zoom equally well, which the gap-share
bound refuses. See
[Observing the engine's decisions](OBSERVING_DECISIONS.md).
One new knob, `transformEstimateMinPairs` (default 3). Additive only —
no numerics changed ([#135](https://github.com/Abdallah01/ocr-stabilizer/issues/135)).

**What's new in 2.5.0** — the engine's decisions are observable on
every result ([`doc/CONTRACT.md`](CONTRACT.md) G10):
`result.coherentShift` (a `CoherentShiftEvent` — the decided
translation, how many merges applied it, how many of those were
adopted, and whether the quorum, the floor or the re-anchor decided it;
`null` when no shift was decided) and `result.identityTurnover` (an
`IdentityTurnover` — merged / admitted / retained / dropped, with
`admittedShare` as the rewrap detector's input). See
[Observing the engine's decisions](OBSERVING_DECISIONS.md).
The contract now also states U9: the engine has no scale or zoom model
([#135](https://github.com/Abdallah01/ocr-stabilizer/issues/135)). Additive only — no numerics changed.

**What's new in 2.4.0** — `coherentShiftAdoptAgreeing` is now the
default ([#119](https://github.com/Abdallah01/ocr-stabilizer/issues/119) item 2): once a coherent shift IS decided, the matched
pairs that sat under their own "moved" gate but agree with the decided
translation follow it, instead of lagging by the damped fraction. The
17-stream A/B measured 16 streams byte-identical — every control
included; a capture where no shift is decided is untouched by
construction — and the one affected stream strictly better
(`pushdown-150` lag at the move 68.3 -> 6.0 px, identity
0.821 -> 0.929, 15 extra merges retained) — on that seed's noise
draw: the #136 variance entry finds the 150 px step forms no plan
at all on 7 of 8 seed / noise configurations, where the lever is
byte-identical to plain `coherentShift` (never worse, better on one
in eight). Pass
`coherentShiftAdoptAgreeing: false` for 2.3.x numerics bit-for-bit.
Also new (both opt-in; `null` = the option stays off): the
`coherentShiftFloorPx` absolute-pixel floor closing the large-slab
blind spot — see [Calibrating `coherentShiftFloorPx`](COHERENT_SHIFT_CALIBRATION.md) —
and `coherentShiftReanchorMinBlocks` (documented, not recommended —
its doc comment measures why). The 2.x guarantees now live in one
page: [`doc/CONTRACT.md`](CONTRACT.md).

**What's new in 2.3.0** — the default `StepResponse` is now
`coherentShift` ([#116](https://github.com/Abdallah01/ocr-stabilizer/issues/116)): when a batch of blocks moves together (a real
layout reflow), the engine now re-anchors that group instead of damping
the move as if it were per-block jitter. A 17-stream A/B, re-derived
independently from raw `ab-report` output, backs the switch —
`coherentShift` 14/17 vs `snap` 11/17, with zero false-triggered step
events on any control stream. Two blind spots are documented, not
regressions, and tracked as [#119](https://github.com/Abdallah01/ocr-stabilizer/issues/119): a single-frame slab too large for the
default quorum falls through to damp's numbers unchanged, and slabs of
50–150 px land inside or near the existing jitter allowance. Full table:
`doc/replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md`. The
`StepResponse` enum, `StabilizationEngine`'s `stepResponse` parameter and
`MergeResult.stepResponseApplied` are all new, additive surface; existing
callers that never named `stepResponse` inherit the new default and see
the numerics change for the default configuration — pass
`stepResponse: StepResponse.damp` explicitly to keep the previous (2.2.0
and earlier) behavior exactly.

**What's new in 2.2.0** — nested re-observation: when an engine's
grouping flips and a paragraph comes back as one of its own lines, the
line now confirms the paragraph (count up, box and text untouched)
instead of being tracked as a second block inside it — the last
box-in-box family the hero GIF showed. `MergeResult.isNestedFragment`
marks such a confirmation. `updateBucketSizes` sets the spatial-index
buckets directly for consumers whose policy is not the viewport
formula, and the replay rig can now apply the buckets a stream recorded
(`meta.bk`) or emulate the reference consumer's 2×-median rule
(`--buckets=median`) — the committed entries report what that changes.
Additive API only; the match path changes for the default
configuration (a fragment inside a cached block merges instead of
spawning), so re-read your overlap counts if you relied on that.

**What's new in 2.1.0** — cross-frame supersession under
`missedFrameRetention`: a retained box that one fresh box now covers by
half or more of its own area (without matching it) is evicted at once
instead of sitting out its retention window on top of the new one —
the box-on-box overlaps the 2.0.0 hero GIF showed. A line reported
inside a retained paragraph keeps the paragraph; blocks from different
carousels never supersede each other. The default configuration
(retention 0) is untouched, and a consumer that runs its own matching
through `merge()` is unaffected. The replay rig now configures the
engine with the producer's viewport (`meta.vp`, an additive
capture-schema field) — the viewport-derived bucket geometry a consumer
sets through `updateViewport` or on an injected index — and the
committed validation numbers were regenerated on it. No API changes;
safe upgrade from 2.0.x.

**What's new in 2.0.0** — merge-decision diagnostics and a read-only
spatial index. `ParagraphGrouper.onMergeDecision` streams a
`MergeDecisionDiagnostic` — accepted or not, plus every rejection
reason from the 9-value `MergeRejectReason` enum — for each boundary
decision, at zero cost when unset ([#92](https://github.com/Abdallah01/ocr-stabilizer/issues/92)). **Breaking:**
`engine.spatialIndex` is now a read-only `SpatialIndexView`; an app
that evicts or restores blocks out-of-band injects its own
`SpatialBlockIndex` through the constructor and mutates via its own
reference ([#96](https://github.com/Abdallah01/ocr-stabilizer/issues/96)). Grouping and stabilization behavior are unchanged.
Migration diff in the [CHANGELOG](../CHANGELOG.md).

**What's new in 1.2.0** — `ParagraphGrouper`: CJK-aware grouping of OCR
blocks into paragraph-level units (Otsu-thresholded gap clustering,
adaptive height-proportional thresholds, sentence-punctuation
awareness, Tukey IQR height fences, noise guards, inline-peer
detection), plus the exported `otsusThreshold` /
`otsusThresholdWithFallback` 1-D gap-clustering utilities. See
[ParagraphGrouper](API_REFERENCE.md#paragraphgrouper-v120) below.

**What's new in 1.1.0** — the `agreementWeighted` agreement scale is now
**per-block** (#75): 3× the tracked block's own height, replacing the
region-median base that small siblings could dilute (a caption's height
says nothing about how much a paragraph may jitter) and that needed a
cold-region default. Six-capture validation
(`doc/replay/validation/2026-07-perblock-scale/`): ~30–60% better
established-chain damping under OCR jitter with informative confidence,
no reflow lag regression, every other regime within noise. On uniform
streams the bases coincide, so existing tuning carries over; `legacy` is
unaffected.

**What's new in 1.0.0** — `agreementWeighted` is now the DEFAULT
position-merge model (#74), after the final consumer gate: a paired
same-stream ab-report on two current consumer captures showed equal
young-block tracking, roughly halved established-block displacement
(n3-5 mean 0.44 vs 0.87 px), and informative position confidence where
`legacy` saturates flat 1.0. **Breaking for consumers tuned against 0.x
confidence numerics** — position confidence is no longer
additive-saturating; pin
`StabilizationEngine(positionMergeModel: PositionMergeModel.legacy)`
for the exact 0.x behavior until you re-validate against a current
capture. See the [CHANGELOG](../CHANGELOG.md#100---2026-07-24).

**What's new in 0.9.0** — `agreementWeighted` numerics validated on
production captures and recalibrated: the agreement scale is now a
jitter allowance (3× regional median block height, #73), replacing the
drift-margin-derived scale that collapsed confidence on stable streams
(#70) and was unreachable everywhere else. Deep-chain jitter now damps
to 3.8 px/merge (legacy: 11.8) with regime-discriminating confidence.
Opt-in only — `legacy` (the default) is untouched; the 1.0 default flip
is tracked in #74. Sweep evidence:
[`doc/replay/validation/2026-07-scale-sweep/`](replay/validation/2026-07-scale-sweep/SWEEP.md).
Also new: the consumer-capture replay rig (#68,
[`tool/replay/`](../tool/replay/) + [`doc/replay/capture_schema.md`](replay/capture_schema.md)).

**What's new in 0.8.0** — the package is now pure Dart (#59): no Flutter
SDK dependency, usable server-side. `Rect`/`Offset`/`Size` now come from
the package instead of `dart:ui` (member-compatible; see
[Platform Support](../README.md#platform-support) for the two-line render-boundary
conversion), and debug logging became an opt-in `debugLogger` parameter.
See the [CHANGELOG](../CHANGELOG.md#080---2026-07-22) Breaking section.

**What's new in 0.7.0** — opt-in `PositionMergeModel.agreementWeighted`:
observation-count-anchored merge weights (long-observed blocks stop
chasing jitter) and agreement-derived position confidence (disagreement
reduces confidence instead of saturating it). Default stays `legacy` —
upgrade is a no-op until you opt in. See the
[CHANGELOG](../CHANGELOG.md#070---2026-07-22).

**What's new in 0.6.0** — audit-driven release: opt-in
`missedFrameRetention` keeps block identity across missed OCR frames,
`updateViewport()` unifies the quantization knobs, viewport-relative
blocks no longer receive page-scroll drift corrections or false
contradiction events, and batch-NMS key handling is fixed. Behavioral
changes — see the [CHANGELOG](../CHANGELOG.md#060---2026-07-20) Breaking
section before upgrading. 504 tests, verified down to Flutter 3.19.

**What's new in 0.5.1** — bug-fix release, no API changes: spatial-index
candidate de-duplication (band counters no longer double-tick for IC
blocks), Jaccard-only primary matches are no longer dropped, `OcrBlock`
NaN confidence is stored as null, and the CJK predicate now includes
Extension B everywhere. See the [CHANGELOG](../CHANGELOG.md#051---2026-07-20).

**What's new in 0.5.0** — additive surface only; safe upgrade from 0.4.x:
a typed `BandPredicateException` surfaces consumer-supplied predicate
throws instead of swallowing them, a new `rejectedTextBand` counter
makes the band funnel decomposable, and an internal
`assertConfidenceRange` utility centralises the `[0.0, 1.0]` check
across `DefaultTrackedBlock`, `MergeResult`, the engine guards, and
the `PositionConfidence.from` / `TextConfidence.from` factories.

**0.4.0 introduced the band-fallback path** — see
[`BandFallbackConfig`](BAND_FALLBACK.md) below.
Default `BandFallbackMode.off` keeps the upgrade backwards-compatible.

**0.4.0 also tightened Confidence validation** — `stabilize()`, `merge()`,
and `DefaultTrackedBlock`'s ctor now throw `ArgumentError` on NaN or
out-of-`[0.0, 1.0]` confidences. Consumers going through `.from()`
factories were already covered. See the
[CHANGELOG](../CHANGELOG.md#040---2026-05-23) for migration details.
