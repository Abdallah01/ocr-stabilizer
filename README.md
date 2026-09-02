# ocr_stabilizer

A real-time stabilization engine for live text-capture pipelines — OCR
overlays and DOM/text extraction alike. Tracks text block identity across
noisy captures, corrects positional drift, and provides spatial indexing
for deduplication. Extraction streams are a first-line use case, not an
afterthought: identity tracking, dedup, and text voting are exactly what
keeps an extraction pipeline consistent across re-captures, while the
position-merge refinements matter most for rendered overlays.

**The 2.x contract** — what the package guarantees, what it deliberately
does not do, and what is yours to configure — is one page:
[`doc/CONTRACT.md`](doc/CONTRACT.md). It is the release-stability promise
behind every 2.x version.

Pure Dart — usable in Flutter apps and server-side pipelines alike.
Built for event-driven OCR pipelines — e.g. screenshots captured on
scroll-settle at 1–2 Hz — where translated overlays must remain stable as
the user scrolls. The engine has no internal clock and no warm-up: a block
is returned usable from its **first** observation; later captures only
refine positions (see [Timing model](#timing-model)).

![Demo: raw per-frame ML Kit boxes jittering on the left; the same stream stabilized on the right](https://raw.githubusercontent.com/Abdallah01/ocr-stabilizer/9e8df3f/doc/media/stabilizer-demo-mlkit.gif)

*Real **ML Kit** output, captured on a Galaxy S25 over a synthetic page
(the committed [on-device corpus](doc/replay/validation/2026-08-mlkit-on-device/)):
14 captures over one viewport under scripted micro-scrolls (the stream's
last five captures are a momentum fling and are cut from the demo — see
the entry's correction note), 3-frame ghost trails, the same drawing rule
on both panels. Left: the boxes exactly as the production pipeline reports
them each frame, including the producer's scroll-stamp lag. Right: the
engine's tracked state (`StabilizationEngine` defaults — currently
`StepResponse.coherentShift` since 2.3.0 and `coherentShiftAdoptAgreeing`
since 2.4.0 — plus `missedFrameRetention: 2`),
replayed on the device viewport. Boxes still overlap on the right in the
last frames: the producer's lagged frames put different text over boxes
the engine rightly holds — the entry counts and explains them (15 pairs
over the 14 frames, from 32 in 2.0.0). These frames were rendered under
the pre-2.3.0 default (`StepResponse.damp`);
[#122](https://github.com/Abdallah01/ocr-stabilizer/issues/122)
re-dumped the same corpus under `coherentShift` and confirmed
byte-identical frames and counts, so the caption's "defaults" claim
still holds without a re-render.
Rendered from engine output by
[`tool/replay/dump_frames.dart`](tool/replay/dump_frames.dart) +
[`doc/media/render_demo_gif.py`](doc/media/render_demo_gif.py) — not an
illustration; `test/demo_gif_provenance_test.dart` pins the claim. A
[Tesseract twin](https://raw.githubusercontent.com/Abdallah01/ocr-stabilizer/6d6c04a/doc/media/stabilizer-demo.gif)
renders from the fully synthetic
[cross-engine corpus](doc/replay/validation/2026-08-tesseract-matrix/).*

## The Problem

Live OCR on scrollable content produces a stream of noisy, jittery observations.
The same paragraph appears at slightly different positions each capture. Without
a stabilization layer, overlays flicker, duplicate, and drift.

This is the same problem visual SLAM (Simultaneous Localization and Mapping)
solves in robotics: associate noisy sensor observations to persistent landmarks,
correct accumulated drift, and maintain a consistent map. `ocr_stabilizer`
adapts SLAM techniques to the OCR domain.

## Timing model

The contract is **render at first sight, refine on re-sight** — observation
counts are evidence depth, never a readiness ladder:

- `stabilize()` returns first-sighting blocks in
  `StabilizationResult.stableBlocks` on the very call that observed them.
  Nothing is withheld while evidence accrues, and nothing anywhere gates
  availability on time (the classifier reads a clock only for a
  capture-freshness term feeding position confidence).
- `observationCount` and the chain-depth bands in the validation tables
  (n1-2 … n11+) describe how much an **already-displayed** block's box moves
  per *re*-observation. Deep bands are the steady-state for blocks that stay
  in view (a user dwelling on a paragraph — where captures keep re-observing
  them); blocks scrolled past live their whole life at shallow depth, which
  is normal and costs nothing.
- `StabilizationResult.wellObservedTexts` fires from the **3rd**
  observation onward. It is a hint that a translation can be cached
  long-term — not a display gate.
- The refinement supply is demand-coupled: re-observations and jitter both
  come from captures (regional drift propagation included — it is sourced
  from neighbors' re-observations, never a timer). A stream that produces
  no re-observations also produces no wobble to damp; whenever the wobble
  exists, so does the evidence that suppresses it.

## Installation

```yaml
dependencies:
  ocr_stabilizer: ^2.6.0
```

> **What's new in 2.6.0** — every result reports a similarity-transform
> estimate over the capture's matched pairs, `result.transformEstimate`
> (a `TransformEstimate`: isotropic `scale`, `translation`, `fixedPoint`,
> `pairCount`, `rejectedPairs`, `residualPx`, `spanPx`,
> `largestGapShare`; `null` under three eligible pairs) — observed and
> never applied: the merge keeps
> its no-zoom model ([`doc/CONTRACT.md`](doc/CONTRACT.md) G11, U9). A
> layout layer that holds geometry the engine never sees can read a
> browser zoom or a DPR change from one value and rescale, instead of
> inspecting every block. The zoom corpus entry
> ([`doc/replay/validation/2026-09-zoom/`](doc/replay/validation/2026-09-zoom/EXPERIMENT.md))
> states the reading rule — `|scale − 1| ≥ 0.10`, `residualPx ≤ 10`,
> `largestGapShare ≤ 0.5`, `pairCount ≥ 6` — and its margins: a 1.25x
> and a 0.8x zoom read at 0.249 / 0.200 deviation with residuals under
> 4 px, and no control capture in the repository exceeds 0.010 under
> those bounds. Its limit is stated with it: matched lines that form
> two clusters fit a step and a zoom equally well, which the gap-share
> bound refuses. See
> [Observing the engine's decisions](#observing-the-engines-decisions).
> One new knob, `transformEstimateMinPairs` (default 3). Additive only —
> no numerics changed ([#135](https://github.com/Abdallah01/ocr-stabilizer/issues/135)).

> **What's new in 2.5.0** — the engine's decisions are observable on
> every result ([`doc/CONTRACT.md`](doc/CONTRACT.md) G10):
> `result.coherentShift` (a `CoherentShiftEvent` — the decided
> translation, how many merges applied it, how many of those were
> adopted, and whether the quorum, the floor or the re-anchor decided it;
> `null` when no shift was decided) and `result.identityTurnover` (an
> `IdentityTurnover` — merged / admitted / retained / dropped, with
> `admittedShare` as the rewrap detector's input). See
> [Observing the engine's decisions](#observing-the-engines-decisions).
> The contract now also states U9: the engine has no scale or zoom model
> ([#135](https://github.com/Abdallah01/ocr-stabilizer/issues/135)). Additive only — no numerics changed.

> **What's new in 2.4.0** — `coherentShiftAdoptAgreeing` is now the
> default ([#119](https://github.com/Abdallah01/ocr-stabilizer/issues/119) item 2): once a coherent shift IS decided, the matched
> pairs that sat under their own "moved" gate but agree with the decided
> translation follow it, instead of lagging by the damped fraction. The
> 17-stream A/B measured 16 streams byte-identical — every control
> included; a capture where no shift is decided is untouched by
> construction — and the one affected stream strictly better
> (`pushdown-150` lag at the move 68.3 -> 6.0 px, identity
> 0.821 -> 0.929, 15 extra merges retained) — on that seed's noise
> draw: the #136 variance entry finds the 150 px step forms no plan
> at all on 7 of 8 seed / noise configurations, where the lever is
> byte-identical to plain `coherentShift` (never worse, better on one
> in eight). Pass
> `coherentShiftAdoptAgreeing: false` for 2.3.x numerics bit-for-bit.
> Also new (both opt-in; `null` = the option stays off): the
> `coherentShiftFloorPx` absolute-pixel floor closing the large-slab
> blind spot — see [Calibrating `coherentShiftFloorPx`](#calibrating-coherentshiftfloorpx) —
> and `coherentShiftReanchorMinBlocks` (documented, not recommended —
> its doc comment measures why). The 2.x guarantees now live in one
> page: [`doc/CONTRACT.md`](doc/CONTRACT.md).

> **What's new in 2.3.0** — the default `StepResponse` is now
> `coherentShift` ([#116](https://github.com/Abdallah01/ocr-stabilizer/issues/116)): when a batch of blocks moves together (a real
> layout reflow), the engine now re-anchors that group instead of damping
> the move as if it were per-block jitter. A 17-stream A/B, re-derived
> independently from raw `ab-report` output, backs the switch —
> `coherentShift` 14/17 vs `snap` 11/17, with zero false-triggered step
> events on any control stream. Two blind spots are documented, not
> regressions, and tracked as [#119](https://github.com/Abdallah01/ocr-stabilizer/issues/119): a single-frame slab too large for the
> default quorum falls through to damp's numbers unchanged, and slabs of
> 50–150 px land inside or near the existing jitter allowance. Full table:
> `doc/replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md`. The
> `StepResponse` enum, `StabilizationEngine`'s `stepResponse` parameter and
> `MergeResult.stepResponseApplied` are all new, additive surface; existing
> callers that never named `stepResponse` inherit the new default and see
> the numerics change for the default configuration — pass
> `stepResponse: StepResponse.damp` explicitly to keep the previous (2.2.0
> and earlier) behavior exactly.

> **What's new in 2.2.0** — nested re-observation: when an engine's
> grouping flips and a paragraph comes back as one of its own lines, the
> line now confirms the paragraph (count up, box and text untouched)
> instead of being tracked as a second block inside it — the last
> box-in-box family the hero GIF showed. `MergeResult.isNestedFragment`
> marks such a confirmation. `updateBucketSizes` sets the spatial-index
> buckets directly for consumers whose policy is not the viewport
> formula, and the replay rig can now apply the buckets a stream recorded
> (`meta.bk`) or emulate the reference consumer's 2×-median rule
> (`--buckets=median`) — the committed entries report what that changes.
> Additive API only; the match path changes for the default
> configuration (a fragment inside a cached block merges instead of
> spawning), so re-read your overlap counts if you relied on that.

> **What's new in 2.1.0** — cross-frame supersession under
> `missedFrameRetention`: a retained box that one fresh box now covers by
> half or more of its own area (without matching it) is evicted at once
> instead of sitting out its retention window on top of the new one —
> the box-on-box overlaps the 2.0.0 hero GIF showed. A line reported
> inside a retained paragraph keeps the paragraph; blocks from different
> carousels never supersede each other. The default configuration
> (retention 0) is untouched, and a consumer that runs its own matching
> through `merge()` is unaffected. The replay rig now configures the
> engine with the producer's viewport (`meta.vp`, an additive
> capture-schema field) — the viewport-derived bucket geometry a consumer
> sets through `updateViewport` or on an injected index — and the
> committed validation numbers were regenerated on it. No API changes;
> safe upgrade from 2.0.x.

> **What's new in 2.0.0** — merge-decision diagnostics and a read-only
> spatial index. `ParagraphGrouper.onMergeDecision` streams a
> `MergeDecisionDiagnostic` — accepted or not, plus every rejection
> reason from the 9-value `MergeRejectReason` enum — for each boundary
> decision, at zero cost when unset ([#92](https://github.com/Abdallah01/ocr-stabilizer/issues/92)). **Breaking:**
> `engine.spatialIndex` is now a read-only `SpatialIndexView`; an app
> that evicts or restores blocks out-of-band injects its own
> `SpatialBlockIndex` through the constructor and mutates via its own
> reference ([#96](https://github.com/Abdallah01/ocr-stabilizer/issues/96)). Grouping and stabilization behavior are unchanged.
> Migration diff in the [CHANGELOG](CHANGELOG.md).

> **What's new in 1.2.0** — `ParagraphGrouper`: CJK-aware grouping of OCR
> blocks into paragraph-level units (Otsu-thresholded gap clustering,
> adaptive height-proportional thresholds, sentence-punctuation
> awareness, Tukey IQR height fences, noise guards, inline-peer
> detection), plus the exported `otsusThreshold` /
> `otsusThresholdWithFallback` 1-D gap-clustering utilities. See
> [ParagraphGrouper](#paragraphgrouper-v120) below.

> **What's new in 1.1.0** — the `agreementWeighted` agreement scale is now
> **per-block** (#75): 3× the tracked block's own height, replacing the
> region-median base that small siblings could dilute (a caption's height
> says nothing about how much a paragraph may jitter) and that needed a
> cold-region default. Six-capture validation
> (`doc/replay/validation/2026-07-perblock-scale/`): ~30–60% better
> established-chain damping under OCR jitter with informative confidence,
> no reflow lag regression, every other regime within noise. On uniform
> streams the bases coincide, so existing tuning carries over; `legacy` is
> unaffected.

> **What's new in 1.0.0** — `agreementWeighted` is now the DEFAULT
> position-merge model (#74), after the final consumer gate: a paired
> same-stream ab-report on two current consumer captures showed equal
> young-block tracking, roughly halved established-block displacement
> (n3-5 mean 0.44 vs 0.87 px), and informative position confidence where
> `legacy` saturates flat 1.0. **Breaking for consumers tuned against 0.x
> confidence numerics** — position confidence is no longer
> additive-saturating; pin
> `StabilizationEngine(positionMergeModel: PositionMergeModel.legacy)`
> for the exact 0.x behavior until you re-validate against a current
> capture. See the [CHANGELOG](CHANGELOG.md#100---2026-07-24).
>
> **What's new in 0.9.0** — `agreementWeighted` numerics validated on
> production captures and recalibrated: the agreement scale is now a
> jitter allowance (3× regional median block height, #73), replacing the
> drift-margin-derived scale that collapsed confidence on stable streams
> (#70) and was unreachable everywhere else. Deep-chain jitter now damps
> to 3.8 px/merge (legacy: 11.8) with regime-discriminating confidence.
> Opt-in only — `legacy` (the default) is untouched; the 1.0 default flip
> is tracked in #74. Sweep evidence:
> [`doc/replay/validation/2026-07-scale-sweep/`](doc/replay/validation/2026-07-scale-sweep/SWEEP.md).
> Also new: the consumer-capture replay rig (#68,
> [`tool/replay/`](tool/replay/) + [`doc/replay/capture_schema.md`](doc/replay/capture_schema.md)).
>
> **What's new in 0.8.0** — the package is now pure Dart (#59): no Flutter
> SDK dependency, usable server-side. `Rect`/`Offset`/`Size` now come from
> the package instead of `dart:ui` (member-compatible; see
> [Platform Support](#platform-support) for the two-line render-boundary
> conversion), and debug logging became an opt-in `debugLogger` parameter.
> See the [CHANGELOG](CHANGELOG.md#080---2026-07-22) Breaking section.
>
> **What's new in 0.7.0** — opt-in `PositionMergeModel.agreementWeighted`:
> observation-count-anchored merge weights (long-observed blocks stop
> chasing jitter) and agreement-derived position confidence (disagreement
> reduces confidence instead of saturating it). Default stays `legacy` —
> upgrade is a no-op until you opt in. See the
> [CHANGELOG](CHANGELOG.md#070---2026-07-22).

> **What's new in 0.6.0** — audit-driven release: opt-in
> `missedFrameRetention` keeps block identity across missed OCR frames,
> `updateViewport()` unifies the quantization knobs, viewport-relative
> blocks no longer receive page-scroll drift corrections or false
> contradiction events, and batch-NMS key handling is fixed. Behavioral
> changes — see the [CHANGELOG](CHANGELOG.md#060---2026-07-20) Breaking
> section before upgrading. 504 tests, verified down to Flutter 3.19.
>
> **What's new in 0.5.1** — bug-fix release, no API changes: spatial-index
> candidate de-duplication (band counters no longer double-tick for IC
> blocks), Jaccard-only primary matches are no longer dropped, `OcrBlock`
> NaN confidence is stored as null, and the CJK predicate now includes
> Extension B everywhere. See the [CHANGELOG](CHANGELOG.md#051---2026-07-20).
>
> **What's new in 0.5.0** — additive surface only; safe upgrade from 0.4.x:
> a typed `BandPredicateException` surfaces consumer-supplied predicate
> throws instead of swallowing them, a new `rejectedTextBand` counter
> makes the band funnel decomposable, and an internal
> `assertConfidenceRange` utility centralises the `[0.0, 1.0]` check
> across `DefaultTrackedBlock`, `MergeResult`, the engine guards, and
> the `PositionConfidence.from` / `TextConfidence.from` factories.
>
> **0.4.0 introduced the band-fallback path** — see
> [`BandFallbackConfig`](#bandfallback-the-band-relaxed-matching-path) below.
> Default `BandFallbackMode.off` keeps the upgrade backwards-compatible.
>
> **0.4.0 also tightened Confidence validation** — `stabilize()`, `merge()`,
> and `DefaultTrackedBlock`'s ctor now throw `ArgumentError` on NaN or
> out-of-`[0.0, 1.0]` confidences. Consumers going through `.from()`
> factories were already covered. See the
> [CHANGELOG](CHANGELOG.md#040---2026-05-23) for migration details.

## Getting Started

The fastest path is `DefaultTrackedBlock<T>` — a concrete reference
implementation with documented defaults for every required field, including
the load-bearing ones like `carouselIdVotes: {-1: 1}` that need careful
initialization.

```dart
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

final engine = StabilizationEngine<DefaultTrackedBlock<MyPayload>, MyPayload>(
  merger: (existing, fresh, merge) => existing.applyMerge(merge),
);

// Each capture:
final blocks = ocrResults.map((ocr) => DefaultTrackedBlock<MyPayload>(
  absoluteRect: ocr.absoluteRect,
  originalText: ocr.text,
  payload: ocr.payload,
  positionConfidence: PositionConfidence.from(ocr.posConf),
  textConfidence: TextConfidence.from(ocr.txtConf),
)).toList();

final result = engine.stabilize(blocks);
// stabilize() rebuilds engine.spatialIndex internally — no caller action.
```

See [`example/example.dart`](example/example.dart) for a runnable version.

For app-specific block types not covered by `DefaultTrackedBlock`, implement
`TrackedBlock<T>` directly — see the next section.

### BandFallback: the band-relaxed matching path

OCR jitter — one character flipped or one ligature mis-segmented — can drop a
stable block below the primary text-similarity floor for a single frame.
`BandFallbackConfig` opens a relaxed second-pass match path so spatially-
unambiguous blocks don't "blink off and back on."

```dart
final engine = StabilizationEngine<DefaultTrackedBlock<MyPayload>, MyPayload>(
  merger: (existing, fresh, merge) => existing.applyMerge(merge),
  // Opt in: start in observeOnly to read counters, then flip to admit.
  bandFallback: const BandFallbackConfig(mode: BandFallbackMode.observeOnly),
);

// After a few captures, inspect the counters before flipping to admit.
// Note: in admit mode, once a band candidate is locked for a fresh
// observation, subsequent candidates skip band evaluation — so
// candidatesConsidered is mode-variant (observeOnly will show a higher
// figure). The funnel terms (rejectedCandidateFloor + rejectedSpatial
// + rejectedTextBand + bandMatchesIdentified == candidatesConsidered)
// are themselves mode-invariant — every term ticks before the
// early-exit fires.
final s = engine.bandStats;
print('primary admits=${s.primaryMatchesAdmitted}, '
      'primary misses=${s.primaryMatchesRejected}, '
      'candidates considered=${s.candidatesConsidered}, '
      'band would-admit=${s.bandMatchesIdentified}, '
      'rejected obs-floor=${s.rejectedCandidateFloor}, '
      'rejected spatial=${s.rejectedSpatial}, '
      'rejected text-band=${s.rejectedTextBand}, '
      'matches admitted=${s.matchesAdmitted}');
```

Recommended adoption flow for callers that want band coverage: ship with
`off` (the default — a `^0.5.0` upgrade is a no-op), switch to
`observeOnly` to read the counters in production, then flip to `admit`
once the ratios justify it. Staying on `off` permanently is also valid —
it disables the band path entirely and pays no extra cost.

### Calibrating `coherentShiftFloorPx`

The floor admits a single surviving mover to the coherent-shift vote on its
own magnitude — the fix for slabs so large that too few matched movers
survive for the quorum to see. It is **a property of your capture
geometry, not a universal constant**, which is why it ships `null`
(disabled, always safe) instead of with a default:

1. **Lower bound:** measure the largest displacement ORDINARY scrolling
   produces between two consecutive captures on your device and capture
   cadence (replay your own captures, or read the largest per-frame move
   on a scroll-only session). The floor must sit ABOVE it, or scroll
   fires step events. On the validation corpus this bound is 377 px on
   the published streams (the tesseract-matrix scroll control's largest
   step); across the eight seed / noise configurations of the #136 entry
   it spans 220–377 px on the seven that measure it (one sits below the
   200 px search floor).
2. **Upper bound:** the smallest single-frame slab you need tracked. The
   floor must sit BELOW the displacement such a slab leaves on its
   surviving mover — 406 px on the published page's 600 px slab,
   240–406 px where a mover survives at all — and on two of the four
   synthetic pages the window is empty: on one no mover survives at any
   floor from 200 up, on the other the survivor (240 px) sits below that
   page's own scroll ceiling (359–364 px).
3. Pick inside the window and re-run your controls: the corpus ships at
   390 px with 0 step events on all 10 control streams (and on all 32
   control replays of the #136 entry) and the published page's 600 px
   slab's lag cut 30.7 -> 1.4 px; on the other three synthetic pages
   390 is a safe no-op — never inside their window, never firing. No
   single floor is inside every page's window, which is why this is a
   recipe and not a default. A consumer capturing less often, or
   scrolling faster, needs a HIGHER floor (ordinary between-capture moves
   are bigger); if your window is empty — your scrolling moves farther
   per capture than your smallest slab — leave it `null`.

A height-relative multiplier provably cannot replace this calibration: on
the corpus a scroll control reaches 3.63x its own scale while the real
slab's mover travels at only 2.64x, so NO multiplier admits one without
the other. Full derivation and the sensitivity table:
`doc/replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md`.

### Observing the engine's decisions

Since 2.5.0 every `StabilizationResult` carries two read-only summaries
of what the engine decided this capture, so a layout layer above the
engine can react without reverse-engineering `stableBlocks`:

```dart
final result = engine.stabilize(blocks);

final shift = result.coherentShift; // CoherentShiftEvent?
if (shift != null) {
  // The tracked content moved as a slab. Move any geometry you cache
  // OUTSIDE the engine for these identities by the same vector.
  overlay.translateAll(shift.translation);
  log('shift ${shift.decidedBy.name} ${shift.translation} '
      'members=${shift.memberCount} adopted=${shift.adoptedCount}');
}

final t = result.identityTurnover; // IdentityTurnover
final leftBehind = t.dropped + t.retained; // cached identities nothing matched
if (shift == null && leftBehind > 0 && t.admittedShare >= 0.5) {
  // Most fresh blocks are NEW identities, cached identities were left
  // unmatched, and nothing moved as a slab: the line boxes changed under
  // the same content (a font swap, a width change that rewraps). The engine reset
  // identity on purpose (contract U1). Cached geometry for the old
  // identities is stale — rebuild it rather than translate it.
  overlay.rebuildFrom(result.stableBlocks);
}
```

Reading rules:

- `coherentShift` is the coherent PLAN, counted at the merges that
  actually applied it: `memberCount` equals the number of
  `MergeResult.stepResponseApplied == coherentShift` your merger saw
  this capture. It is `null` on every capture where no plan was decided —
  every control capture, and always under `StepResponse.damp` / `snap`
  (snap re-anchors per block and reports only through `MergeResult`).
- `decidedBy` names the path: `quorum` (the majority vote), `floor`
  (`coherentShiftFloorPx`), `reanchor` (`coherentShiftReanchorMinBlocks`).
  `floor` events during ordinary scrolling mean the floor sits inside
  your scroll range — recalibrate it (recipe above).
- `identityTurnover.fresh` can be smaller than the batch you passed:
  intra-batch NMS removes duplicates first, and a nested fragment whose
  host already merged this capture is folded into that merge.
- The `leftBehind > 0` guard keeps a session's FIRST sighting (every
  block new, nothing cached) from reading as a rewrap. The 0.5 share is a
  starting point, not a calibrated constant: on the dynamic-reflow
  validation corpus the rewrap frame admits 23 of 30 lines (0.77) and the
  next frame merges 29 of 30, while a stationary re-sighting sits near
  0.0. Calibrate on your own captures.

Since 2.6.0 a third summary reads the capture's matched pairs as ONE
similarity transform — for the zoom `coherentShift` cannot model:

```dart
final z = result.transformEstimate; // TransformEstimate? (null under 3 pairs)
if (z != null &&
    (z.scale - 1).abs() >= 0.10 &&
    z.residualPx <= 10 &&
    z.largestGapShare <= 0.5 &&
    z.pairCount >= 6) {
  // The matched lines moved as one scale about one point — a zoom. The
  // engine did not rescale anything (contract U9): rescale the geometry
  // you hold outside it about the zoom origin, then let it converge.
  overlay.scaleAll(z.scale, about: z.fixedPoint ?? Offset.zero);
}
```

- Read `residualPx` before `scale`: a partial step over a ladder of
  lines also fits as a scale (0.18–0.22 on the corpus's 300 px slabs)
  but with a 58–87 px residual, a zoom with a residual of a few px.
  `spanPx` is the lever arm the scale was estimated over
  (`residualPx / spanPx` is its uncertainty).
- Read `largestGapShare` before trusting a small residual: when the
  matched lines form TWO CLUSTERS (two paragraphs, nothing matched
  between them — or a step whose boundary pairs the trim set aside), a
  translation of one cluster and a zoom about a point fit the same
  pairs equally well, and the residual is only the spread inside each
  cluster. Near 1 the estimate cannot tell them apart; the bound above
  refuses it. The four bounds are the zoom corpus entry's, with its
  margins table as their justification.
- The captures AFTER a zoom event read 0.92–1.08 with large residuals:
  the merged blocks are being damped toward the new geometry while the
  newly admitted ones already sit at it. The residual bound refuses
  them; rescale once, at the event capture.

## Core Components

### TrackedBlock\<T\>

The engine's central interface. Every block the engine processes implements this.

```dart
class MyBlock implements TrackedBlock<MyPayload> {
  @override final AbsoluteRect absoluteRect;
  @override final String originalText;
  @override final ContainerId? containerId;
  @override final bool isViewportRelative;
  @override final bool isInnerScrollerChild;
  @override final double innerScrollerTop;
  @override final bool isHorizontalScrollChild;
  @override final ScrollContext scrollContext;
  @override final bool isFromStickyElement;
  @override final StickyFallback stickyFallback;
  @override final PositionConfidence positionConfidence;
  @override final TextConfidence textConfidence;
  @override final int sourceQuality;
  @override final MyPayload payload;  // opaque — engine carries but never reads
}
```

For the stabilization pipeline (vote accumulation, provisional state,
SAR-merge history), implement `ObservableBlock<T>` instead — it extends
`TrackedBlock<T>` with 8 more getters. Most integrators want
`DefaultTrackedBlock<T>` rather than rolling their own.

The generic `T` carries app-specific data (translations, styles) without
coupling the engine to your domain types.

### DriftTracker

Tracks positional drift per coordinate-space region. OCR positions jitter
between captures due to scroll timing, viewport changes, and sensor noise.
DriftTracker accumulates observations and computes a robust median correction
per region.

```dart
final drift = DriftTracker();

// Record a drift observation
drift.addObservation(block, measuredDrift);

// Query the correction for a region
final correction = drift.medianDriftForKey(spaceKey);

// Apply correction to a fresh observation
final corrected = DriftTracker.applyCorrectedPosition(rect, correction);
```

**Key properties:**
- **Bounded corrections:** Drift is clamped to the median block height per
  region — the engine can never shift a block farther than a typical line
  of text.
- **Rolling window:** Keeps the last 20 observations per region, so drift
  adapts to changing conditions.
- **Submap isolation:** Normal page-scroll and inner-scroller containers
  track drift independently via `SpaceKey`.

### SpatialBlockIndex

Grid-cell spatial index for O(cells) overlap candidate lookup during
deduplication. Blocks are indexed by their center position into adaptive
grid cells.

```dart
final index = SpatialBlockIndex();
index.updateBucketSizes(viewportWidth: 1000, viewportHeight: 800);

index.add(block);
final nearby = index.candidates(queryBlock);
index.remove(block);
```

**Three coordinate-space namespaces** prevent cross-space false matches:
- Normal page-absolute blocks
- Viewport-relative (fixed/sticky) blocks (`vr:` prefix)
- Inner-scroller relative blocks (`ic:` prefix) — dual-indexed for
  both IC-to-normal and IC-to-IC comparisons.

### HierarchyWeightX

Extension on `TrackedBlock` computing hierarchy weight from coordinate-space
flags. Higher weight means more constrained coordinate space:

| Tier | Weight | Meaning |
|------|--------|---------|
| Viewport-relative | 40 | Fixed/sticky — no scroll drift |
| Nested IC+carousel | 30 | Compound coordinate space |
| IC or carousel | 20 | Single-axis constraint |
| Normal | 10 | Unrestricted page scroll |

### ParagraphGrouper (v1.2.0+)

**The boundary first: `StabilizationEngine` does not know what a paragraph
is. Consumers decide the unit of tracking** — lines, paragraphs, DOM
nodes; the engine tracks whatever you feed `stabilize()`. This grouper is
a downstream convenience for consumers that want translation-sized units,
not part of the engine's identity model, and its translation-request
defaults are not the engine's opinion about text structure
([#101](https://github.com/Abdallah01/ocr-stabilizer/issues/101); the
measured case for grouping AFTER tracking, not before, is in the
dynamic-reflow entry's pre-grouped addendum).

Groups engine-level OCR blocks into paragraph-level units — the step between
raw OCR output and translation/layout consumers. OCR engines return blocks
that rarely match visual paragraphs: wrapped lines arrive as separate blocks,
while unrelated UI elements (tag pills, toolbar items) sit close enough to
merge under fixed-pixel gap heuristics. `ParagraphGrouper` reconstructs
paragraph units with data-driven clustering instead:

- **Otsu-thresholded gap clustering** — finds the natural break between
  line-spacing and paragraph-spacing from each batch's own gap distribution
  (no fixed pixel constants; also exposed directly as `otsusThreshold` /
  `otsusThresholdWithFallback`).
- **Adaptive height-proportional threshold** — scales with font size and
  device pixel ratio, so high-DPR captures group identically to 1x.
- **CJK punctuation awareness** — a block ending in 。！？… gets a stricter
  merge threshold (the sentence is likely complete); multi-line blocks are
  exploded at sentence-ending lines.
- **Noise and identity guards** — Tukey IQR height fences, ICDAR aspect-ratio
  bounds, rune-density filtering, and inline-peer detection (side-by-side
  elements never merge).

```dart
final grouper = ParagraphGrouper(); // tuned defaults
final paragraphs = grouper.groupIntoParagraphs(blocks); // List<List<OcrBlock>>

// Knobs: gap floor/multiplier + merge caps
final custom = ParagraphGrouper(
  lineGapThreshold: 10.0,   // px floor for the adaptive threshold
  lineGapMultiplier: 0.75,  // × average block height
  maxParagraphBlocks: 3,    // blocks per merged paragraph
  maxParagraphRunes: 200,   // total runes per merged paragraph
);
```

Defaults were tuned on CJK novel pages (high-DPR mobile WebView captures);
they are sensible for CJK prose generally, and the caps are the first knobs
to revisit for Latin-script or dense-layout content.

### Extension Types

Zero-cost compile-time wrappers for coordinate safety:

- **`AbsoluteRect`** — wraps `Rect` for world-space coordinates. Spatial
  operations (`overlaps`, `expandToInclude`) only accept other `AbsoluteRect`
  values, preventing accidental coordinate-space mixing.
- **`ContainerId`** — wraps `String` for stable container identity hashes.
- **`SpaceKey`** — wraps `String` with typed constructors (`normal`, `ic`,
  `unknown`) for drift observation coordinate spaces.

## Six-Dimension Block Identity

A block's identity is a six-dimensional signature:

| Dimension | What It Answers | Package Support |
|-----------|----------------|-----------------|
| **Textual** | What does this text say? | `originalText` on TrackedBlock |
| **Spatial** | Where is it in the page? | `absoluteRect`, confidence scores |
| **Relative** | Which coordinate space? | `SpaceKey`, `ContainerId` |
| **Semantic** | What kind of element? | `hierarchyWeight` (extension) |
| **Temporal** | How much evidence? | `observationCount` (ObservableBlock) |
| **Contextual** | What context was it in? | `ContextualInvalidationCheck` (callback) |

## API Reference

### Interfaces

| Type | Purpose |
|------|---------|
| `TrackedBlock<T>` | Core block contract (14 getters including the opaque `payload`) |
| `ObservableBlock<T>` | Extends `TrackedBlock`; adds observation history (8 getters: counts, votes, provisional state) |
| `ClassificationInput` | Platform-agnostic viewport geometry |
| `CarouselInput` | Carousel-specific geometry |
| `SubmapMembership` | Strategy for coordinate-space partitioning |
| `ContextualInvalidationCheck` | Callback for context-change detection |
| `SpatialIndexView<T>` | Read-only spatial-index contract — the type of `engine.spatialIndex` (2.0.0+) |
| `MergeDecisionCallback` | Callback type of `ParagraphGrouper.onMergeDecision` (2.0.0+) |

### Components

| Type | Purpose |
|------|---------|
| `StabilizationEngine<T, P>` | SAR-merge, intra-batch dedup, contradiction detection |
| `DriftTracker` | Regional drift correction with submap isolation |
| `SpatialBlockIndex` | Grid-cell spatial index for overlap queries (implements `SpatialIndexView`) |
| `BlockClassifierService` | Classifies blocks into fixed / sticky / carousel / IC / normal |
| `OverlapResolver` | Spatial NMS with language-aware thresholds |
| `BlockKeyGenerator` | Position + text dedup keys with fuzzy neighbor matching |
| `CssSubmapMembership` | Default WebView submap partitioning |
| `ParagraphGrouper` | CJK-aware block→paragraph grouping (Otsu gap clustering + noise guards) |
| `otsusThreshold` / `otsusThresholdWithFallback` | Otsu bimodal threshold for 1-D gap distributions (function API) |
| `RobustStats` | Robust statistics (median, MAD, IQR) |
| `IqrOutlier` | Tukey-fence outlier detection |
| `TextDedupUtils` | Levenshtein, Jaccard, CJK detection helpers |

### BandFallback (v0.4.0+)

| Type | Purpose |
|------|---------|
| `BandFallbackConfig` | Configures the band-relaxed matching path. Default `mode: off`. |
| `BandFallbackMode` | `off` (no band loop) / `observeOnly` (counters only) / `admit` (production). |
| `BandFallbackStats` | Read-only per-capture telemetry exposed via `engine.bandStats`. |
| `BandSpatialPredicate` | Optional `bool Function(TrackedBlock fresh, TrackedBlock candidate)` injection. `null` → engine substitutes a drift-aware `overlapRatio >= 0.80` closure. |
| `BandPredicateException` | Typed wrapper for consumer-predicate throws (v0.5.0+) — caught and rewrapped by the engine so failures surface with a typed shape, never swallowed. Original predicate stack lives on `predicateStackTrace`. |

### Reference Implementations

| Type | Purpose |
|------|---------|
| `DefaultTrackedBlock<T>` | Concrete `ObservableBlock<T>` with documented defaults, `copyWith`, and `applyMerge(MergeResult)` — the fastest path for new integrators |

### Result Types

| Type | Purpose |
|------|---------|
| `StabilizationResult<T>` | Output of `engine.stabilize()` — stable blocks + bookkeeping |
| `MergeResult` | Exhaustive engine-computed delta passed to `BlockMerger` |
| `ClassificationResult` | Output of `BlockClassifierService` |
| `MergeDecisionDiagnostic` | One grouper boundary decision — verdict, reason set, gap/threshold context (2.0.0+) |
| `CoherentShiftEvent` | The coherent shift a capture applied — translation, member count, adopted count, deciding path (2.5.0+) |
| `IdentityTurnover` | Per-capture identity census — merged / admitted / retained / dropped, `admittedShare` (2.5.0+) |
| `TransformEstimate` | Per-capture similarity-transform fit over the matched pairs — `scale`, `translation`, `fixedPoint`, `residualPx`, `spanPx`, `pairCount`, `rejectedPairs`; observed, never applied (2.6.0+) |

### Value Types

| Type | Purpose |
|------|---------|
| `ScrollContext` | Scroll offsets and carousel identity at capture time |
| `StickyFallback` | Fallback coordinate context for demoted sticky elements |
| `TextVote` | Accumulated confidence evidence for one text variant |
| `MergeRejectReason` | 9-value enum naming every grouper rejection guard (2.0.0+) |
| `CoherentShiftSource` | 3-value enum naming the path that decided a coherent shift — quorum / floor / reanchor (2.5.0+) |

### Extension Types

| Type | Wraps | Purpose |
|------|-------|---------|
| `AbsoluteRect` | `Rect` | World-space coordinate safety |
| `ContainerId` | `String` | Stable container identity |
| `SpaceKey` | `String` | Typed drift observation keys |
| `PositionConfidence` | `double` | Position-accuracy confidence in [0, 1] |
| `TextConfidence` | `double` | OCR-text confidence in [0, 1] |

## Platform Support

The package is pure Dart (since 0.8.0) — no Flutter SDK required. It runs
anywhere Dart runs: Flutter apps on every platform, server-side Dart, and
CLI tools.

Geometry uses the package's own `Rect` / `Offset` / `Size` value types
(member-compatible with `dart:ui`'s). Flutter apps convert at the render
boundary — the extensions below are all that's needed:

```dart
import 'dart:ui' as ui;
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

extension RectToUi on Rect {
  ui.Rect toUi() => ui.Rect.fromLTRB(left, top, right, bottom);
}

extension UiToRect on ui.Rect {
  Rect toStabilizer() => Rect.fromLTRB(left, top, right, bottom);
}
```

Debug diagnostics are opt-in: pass `debugLogger: print` to
`BlockClassifierService` or `DriftTracker` to restore the pre-0.8.0
`debugPrint` output (default is silent). Since 1.0.1 the logger carries two
severities: chatty lines fire in debug builds only (tree-shaken elsewhere),
while anomaly-class events — non-finite input skips, a throwing
`positionLookup` callback — are delivered in every build mode (#78).

The `SubmapMembership` and `ClassificationInput` interfaces allow the engine
to support different input sources:

| Platform | SubmapMembership | ClassificationInput |
|----------|-----------------|-------------------|
| WebView | `CssSubmapMembership` (default) | `CaptureSnapshotAdapter` (app-side) |
| PDF | Custom (page-based submaps) | Custom (page geometry) |
| Camera | Custom (frame regions) | Custom (camera frame) |

## Design decisions and known limits

Deliberate trade-offs, each with a tracking issue for discussion:

- **Position model calibrated against ML Kit, first transfer point proven.**
  The agreement-weighted merge scale was swept on ML-Kit-shaped noise; a
  Tesseract 5 matrix entry (2026-08) shows the defaults transfer without
  retuning in the photometric-jitter regime
  (`doc/replay/validation/2026-08-tesseract-matrix/`). High-amplitude
  re-segmentation on other engines remains open: [#94](https://github.com/Abdallah01/ocr-stabilizer/issues/94).
- **No scale or zoom model in the merge — a transform estimate is
  reported instead.** `coherentShift` models a shared translation only.
  A zoom that keeps the line texts still matches (matching is
  text-first) and is absorbed as per-block displacement — damped toward
  the new boxes over several captures, no `coherentShift`; a zoom or
  width change that REWRAPS the lines takes the rewrap path (identity
  reset, which `identityTurnover` names). Since 2.6.0 every result
  carries `transformEstimate`, the similarity transform the matched
  pairs describe, for a consumer to read under the zoom entry's rule
  and apply to its own geometry; the engine never applies it. Its
  blind spot is named with it: matched lines that form two clusters
  (a slab between two paragraphs, or a step whose boundary pairs the
  trim set aside) fit a step and a zoom equally well — read
  `largestGapShare` before `scale`. One layout, one seed and two
  scale factors of evidence. Contract U9 / G11;
  [#135](https://github.com/Abdallah01/ocr-stabilizer/issues/135).
- **The dynamic-reflow evidence is one layout: four pages, two noise
  draws each.** The #136 entry of
  [`EXPERIMENT.md`](doc/replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md)
  ("Variance across seeds and repetitions") re-derives every
  step-response table on eight seed / noise configurations of the same
  synthetic layout: `coherentShift`'s 4/7 and the controls' zero hold on
  all eight; the `coherentShiftFloorPx` window and the adopt lever's
  150 px result are page- and noise-specific (see the calibration
  recipe). Other fonts, line heights and capture cadences remain
  unmeasured.
- **Paragraph grouping assumes a single text region.** The Otsu gap threshold
  is derived batch-globally; multi-column pages are handled by per-merge
  guards, not per-region statistics. [#91](https://github.com/Abdallah01/ocr-stabilizer/issues/91).
- **The engine does not know what a paragraph is — the unit of tracking is
  consumer-decided.** `ParagraphGrouper` is a downstream convenience whose
  "paragraphs" are translation units: `maxParagraphBlocks: 3` +
  `maxParagraphRunes: 200` size units for bounded translation requests, and
  sentence-end explosion of multi-line blocks is a hard boundary. Default
  semantics: [#100](https://github.com/Abdallah01/ocr-stabilizer/issues/100); punctuation modes: [#99](https://github.com/Abdallah01/ocr-stabilizer/issues/99); a named strategy API: [#101](https://github.com/Abdallah01/ocr-stabilizer/issues/101).
- **One engine instance per continuous visual session.** Construct fresh at
  document boundaries; there is no engine-wide reset today. [#95](https://github.com/Abdallah01/ocr-stabilizer/issues/95).
- **Out-of-band index mutation is injector-owned.** Since 2.0.0
  `engine.spatialIndex` is a read-only view; external eviction/restore
  goes through an injected `SpatialBlockIndex`. Such inserts still bypass
  confidence validation and survive only until the next `stabilize` call
  rebuilds the index. [#96](https://github.com/Abdallah01/ocr-stabilizer/issues/96).
- **Merge diagnostics shipped in 2.0.0** ([#92](https://github.com/Abdallah01/ocr-stabilizer/issues/92)):
  `ParagraphGrouper.onMergeDecision` streams a `MergeDecisionDiagnostic`
  per boundary decision. **Batch-size benchmarks and a long-session
  bounded-state replay** live in `benchmark/` and `doc/benchmarks/`
  ([#97](https://github.com/Abdallah01/ocr-stabilizer/issues/97)). **Dynamic-reflow replay scenarios**
  (push-down, re-wrap; [#93](https://github.com/Abdallah01/ocr-stabilizer/issues/93)) live in
  `doc/replay/validation/2026-08-dynamic-reflow/`: a push-down keeps block
  identity but the position model damps the move as jitter, so tracked
  positions lag it for several captures
  ([#116](https://github.com/Abdallah01/ocr-stabilizer/issues/116)). The
  same streams replayed as pre-grouped paragraphs (`tool/replay/pregroup.dart`)
  show that grouping BEFORE tracking imports the grouper's own instability
  into identity — one mis-read line re-chunks the rest of its paragraph — which
  is why grouping is the consumer's downstream concern
  ([#101](https://github.com/Abdallah01/ocr-stabilizer/issues/101)).

## Docs

The `doc/` tree has its own one-page map — validation entries (which
engine, which numbers), benchmarks, the replay tool, and the v0.5.0
audit: [`doc/README.md`](doc/README.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, conventions, and the
release flow.

