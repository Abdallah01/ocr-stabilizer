# ocr_stabilizer

A real-time stabilization engine for live text-capture pipelines — OCR
overlays and DOM/text extraction alike. Tracks text block identity across
noisy captures, corrects positional drift, and provides spatial indexing
for deduplication. Extraction streams are a first-line use case, not an
afterthought: identity tracking, dedup, and text voting are exactly what
keeps an extraction pipeline consistent across re-captures, while the
position-merge refinements matter most for rendered overlays.

Pure Dart — usable in Flutter apps and server-side pipelines alike.
Built for event-driven OCR pipelines — e.g. screenshots captured on
scroll-settle at 1–2 Hz — where translated overlays must remain stable as
the user scrolls. The engine has no internal clock and no warm-up: a block
is returned usable from its **first** observation; later captures only
refine positions (see [Timing model](#timing-model)).

![Demo: raw per-frame OCR boxes jittering on the left; the same stream stabilized on the right](https://raw.githubusercontent.com/Abdallah01/ocr-stabilizer/main/doc/media/stabilizer-demo.gif)

*Real Tesseract output over 12 jittered captures of one viewport (the
committed [validation corpus](doc/replay/validation/2026-08-tesseract-matrix/)),
with 3-frame ghost trails under the same drawing rule on both panels.
Left: the boxes exactly as OCR reports them each frame. Right: the same
stream through `StabilizationEngine` defaults. Rendered from engine
output by [`tool/replay/dump_frames.dart`](tool/replay/dump_frames.dart)
+ [`doc/media/render_demo_gif.py`](doc/media/render_demo_gif.py) — not an
illustration.*

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
  ocr_stabilizer: ^2.0.0
```

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

### Value Types

| Type | Purpose |
|------|---------|
| `ScrollContext` | Scroll offsets and carousel identity at capture time |
| `StickyFallback` | Fallback coordinate context for demoted sticky elements |
| `TextVote` | Accumulated confidence evidence for one text variant |
| `MergeRejectReason` | 9-value enum naming every grouper rejection guard (2.0.0+) |

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
- **Paragraph grouping assumes a single text region.** The Otsu gap threshold
  is derived batch-globally; multi-column pages are handled by per-merge
  guards, not per-region statistics. [#91](https://github.com/Abdallah01/ocr-stabilizer/issues/91).
- **"Paragraphs" are translation units.** `maxParagraphBlocks: 3` +
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
  ([#97](https://github.com/Abdallah01/ocr-stabilizer/issues/97)). **No dynamic-reflow replay scenarios yet**
  ([#93](https://github.com/Abdallah01/ocr-stabilizer/issues/93)).

## Docs

The `doc/` tree has its own one-page map — validation entries (which
engine, which numbers), benchmarks, the replay tool, and the v0.5.0
audit: [`doc/README.md`](doc/README.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, conventions, and the
release flow.

