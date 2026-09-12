<!-- Relocated from README.md in #144 (2026-09-08); restructured by tier
     in #173 (2026-09-12): the README keeps the quick start, this file is the
     reference. Mechanism sections are unchanged from #144. -->

# API reference

## Where each type sits — read this first

```
   your app -- OCR boxes --> ocr_stabilizer (identity . matching . position . dedup . retention)
                                     |
                                     v  stable blocks (this capture)
                             ParagraphGrouper (optional)
                                     |
                                     v  translation / rendering
```

The package has one job in that picture: turn each capture's noisy boxes
into stable blocks. Everything below is sorted by how likely you are to
touch it. **Public?** — exported from `package:ocr_stabilizer/ocr_stabilizer.dart`.
**Usually instantiate?** — *Yes* (you construct it on the basic path),
*Optional* (construct it only when you want the lever), *Usually no* (the
engine builds its own; inject one only to share it), *Returned by engine*
(you read it, never build it), *Returned by X* (a named producer other
than the engine), *No — static* (a helper with a private constructor).

### You need this

| Type | Public? | Usually instantiate? | Purpose |
|------|---------|----------------------|---------|
| `OcrStabilizer<P>` | Yes | **Yes** — one per capture stream | The common path: `stabilize(blocks)` per capture, defaults for everything, one generic parameter (your payload) |
| `DefaultTrackedBlock<P>` | Yes | **Yes** — one per OCR box, every capture | The block you construct: `absoluteRect` + `payload` required, defaults for the rest |
| `StabilizationResult<DefaultTrackedBlock<P>>` | Yes | Returned by engine | `stableBlocks` to draw, plus the optional `coherentShift` / `identityTurnover` / `transformEstimate` signals |
| `CoordinateContext` | Yes | Optional — `page()` is the default, so omit it | Which frame a rect is in: `page(scroll:)`, `innerScroller(...)`, `viewport(...)` |

### You might need this

| Type | Public? | Usually instantiate? | Purpose |
|------|---------|----------------------|---------|
| `StabilizerConfig` (+ `MatchingConfig`, `MergeConfig`, `StepResponseConfig`, `RetentionConfig`, `DiagnosticsConfig`) | Yes | Optional — only with a measured reason | Every engine lever, grouped by stage |
| `Observation<T>` / `Track<T>` | Yes | Usually no — `DefaultTrackedBlock` implements them | The contract a block satisfies; implement it yourself only for custom persistent state |
| `StabilizationEngine<T, P>` | Yes | Optional — only for a custom `Track` | The general engine; `OcrStabilizer` is its thin subclass |
| `ParagraphGrouper` | Yes | Optional — AFTER the engine | Groups stable blocks into translation-sized units; not part of the identity model |

### Advanced and specialized

Everything else — the collaborators the engine builds for itself, the
derived views, the value types. The tables under [Types](#types) list each
one with the same two columns; the sections below explain the mechanisms
for the ones you might inject or observe.

## You need this

### OcrStabilizer\<P\> (3.1.0+)

**Do I normally instantiate this?** Yes — once, for the life of the
capture stream.

```dart
final stabilizer = OcrStabilizer<MyPayload>();           // defaults
final result = stabilizer.stabilize(observations);       // per capture
```

`OcrStabilizer<P>` is exactly
`StabilizationEngine<DefaultTrackedBlock<P>, P>` with the merger pre-wired
as `(existing, _, merge) => existing.applyMerge(merge)`; the differential
test pins the two identical capture for capture. Its optional constructor
arguments are the engine's: `config`, `driftTracker`, `spatialIndex`,
`submapMembership`, `contextualCheck`. Read back `driftTracker`,
`spatialIndex` (as a `SpatialIndexView`) and `bandStats` for observation.

### DefaultTrackedBlock\<T\>

**Do I normally instantiate this?** Yes — one per OCR box, every capture.

A concrete `Track<T>` with documented defaults, `copyWith`, and
`applyMerge(MergeResult)`. Required: `absoluteRect` (an `AbsoluteRect`,
i.e. `AbsoluteRect(rect)` or `AbsoluteRect.fromLTWH(...)`) and `payload`.
Confidences default to ground truth; `coordinates` defaults to
`CoordinateContext.page()`; the state half (observation count, votes,
provisional status) starts at "first observation" and the engine carries
it from there.

### StabilizationResult\<T\>

**Do I normally instantiate this?** No — returned by `stabilize()`.

`stableBlocks` are the blocks to draw for THIS capture. The optional
signals are for a layout layer: `coherentShift` (a decided shared
translation applied to the tracked blocks that followed it — a slab can
move while other blocks stay put), `identityTurnover` (merged / admitted /
retained / dropped, with `admittedShare`), `transformEstimate` (a
similarity-transform fit over the matched pairs; observed, never applied),
`contradictions`, `invalidatedTexts`, `wellObservedTexts`. Reading rules:
[observing the engine's decisions](OBSERVING_DECISIONS.md).

### CoordinateContext (3.0+)

**Do I normally instantiate this?** Optional — `page()` is the default.

One sealed value per block saying which frame its rect is in. A horizontal
carousel child is still a page block: `page(scroll: ...)` carries the
carousel index. `innerScroller(top:, containerId:, scroll:)` is for a
vertically scrolling container inside the page; `viewport(stickyFallback:)`
for fixed-position content. `fromFlags(...)` adapts the flat 2.x flags and
rejects combinations the engine never expected.

## You might need this

### StabilizerConfig (3.0+)

**Do I normally instantiate this?** Optional — reach for a lever only with
a measured reason ([contract](CONTRACT.md) lists what is yours to
configure).

```dart
OcrStabilizer<MyPayload>(
  config: StabilizerConfig(retention: RetentionConfig(missedFrames: 2)),
);
```

Groups: `MatchingConfig` (band fallback), `MergeConfig`
(position model), `StepResponseConfig` (+ `CoherentShiftConfig`,
`ExperimentalCoherentShiftOptions`), `RetentionConfig`, `DiagnosticsConfig`.
Every lever has a documented default and a measured history.

### Observation\<T\> and Track\<T\>

**Do I normally instantiate this?** Usually no. `DefaultTrackedBlock<T>` already implements `Track<T>`; implement it yourself only when your block needs custom persistent state, and then construct `StabilizationEngine` with your own merger.

`Observation<T>` is what a consumer supplies per capture; `Track<T>` is an
observation plus the state the engine accumulates (observation count, vote
histograms, provisional status). The engine stores and returns tracks; a
fresh block enters as a track at its first observation, and the engine
only ever reads the observation half of a fresh block.

```dart
class MyBlock implements Observation<MyPayload> {
  @override final AbsoluteRect absoluteRect;
  @override final String originalText;
  @override final CoordinateContext coordinates;  // page / innerScroller / viewport
  @override final PositionConfidence positionConfidence;
  @override final TextConfidence textConfidence;
  @override final int sourceQuality;
  @override final MyPayload payload;  // opaque — engine carries but never reads
}
```

`coordinates` (3.0, #147) is one sealed value — `CoordinateContext.page()`
(the default; a carousel child is a page block whose scroll context carries
the carousel index), `.innerScroller(top:, containerId:, scroll:)` or
`.viewport(stickyFallback:)`. The eight 2.x flags (`isViewportRelative`,
`isInnerScrollerChild`, `innerScrollerTop`, `isHorizontalScrollChild`,
`containerId`, `scrollContext`, `isFromStickyElement`, `stickyFallback`)
are derived views readable on every block; a consumer that still stores
them flat builds the frame with `CoordinateContext.fromFlags(...)`, which
rejects the combinations the engine never expected.

To feed the stabilization engine, implement `Track<T>` — it extends
`Observation<T>` with 8 state getters the engine writes through your
merger (`MergeResult` → `copyWith`). Most integrators want
`DefaultTrackedBlock<T>` rather than rolling their own: construct it with
the observation fields and let its defaults carry the state.

The generic `T` carries app-specific data (translations, styles) without
coupling the engine to your domain types.


### StabilizationEngine\<T, P\>

**Do I normally instantiate this?** Optional — only for a custom `Track<T>`.

```dart
final engine = StabilizationEngine<MyBlock, MyPayload>(
  merger: (existing, fresh, merge) => existing.copyWith(/* apply merge */),
);
```

Same constructor arguments as `OcrStabilizer` plus the required `merger`:
the engine computes a `MergeResult` and your merger writes it into your
block type. Behaviour is identical to `OcrStabilizer` for a
`DefaultTrackedBlock` (the differential test).

### ParagraphGrouper (v1.2.0+)

**Do I normally instantiate this?** Optional, and AFTER the engine: OCR → engine → ParagraphGrouper → translation. Construct it only if you want translation-sized units. It takes `OcrBlock`s (`boundingBox`, `text`, `lines`), not tracks: build one per stable block from `absoluteRect.raw` and `originalText` (a single line each) — the grouper never reads tracked state, so nothing is lost in that adapter.

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


## Advanced and specialized

### DriftTracker

**Do I normally instantiate this?** Usually no. The engine builds its own and exposes it as `engine.driftTracker`; pass one in only to share it between engines.

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

**Do I normally instantiate this?** Usually no. The engine builds its own; `engine.spatialIndex` exposes it read-only (`SpatialIndexView`). Pass one in only to share it.

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

**Do I normally instantiate this?** No — a derived view on every `Observation`; you read `hierarchyWeight`, you never set it.

Extension on `Observation` computing hierarchy weight from coordinate-space
flags. Higher weight means more constrained coordinate space:

| Tier | Weight | Meaning |
|------|--------|---------|
| Viewport-relative | 40 | Fixed/sticky — no scroll drift |
| Nested IC+carousel | 30 | Compound coordinate space |
| IC or carousel | 20 | Single-axis constraint |
| Normal | 10 | Unrestricted page scroll |


### Extension Types

Zero-cost compile-time wrappers for coordinate safety:

- **`AbsoluteRect`** — wraps `Rect` for world-space coordinates. Spatial
  operations (`overlaps`, `expandToInclude`) only accept other `AbsoluteRect`
  values, preventing accidental coordinate-space mixing.
- **`ContainerId`** — wraps `String` for stable container identity hashes.
- **`SpaceKey`** — wraps `String` with typed constructors (`normal`, `ic`,
  `unknown`) for drift observation coordinate spaces.


## How the engine decides two observations are the same block

Six dimensions take part. You do not configure all six: three you supply
on the observation (two of them with defaults), one the engine derives,
one the engine maintains, one is an optional callback.

| Dimension | What it answers | Where it comes from | Who supplies it |
|-----------|-----------------|---------------------|-----------------|
| **Textual** | What does this text say? | `originalText` on `Observation` | consumer-supplied |
| **Spatial** | Where is it in the page? | `absoluteRect`, `positionConfidence` | consumer-supplied (confidence defaults to ground truth) |
| **Relative** | Which coordinate space? | `coordinates` (`page` / `innerScroller(containerId:)` / `viewport`); the engine derives its `SpaceKey` from it | consumer-supplied frame (defaults to `page()`), derived key |
| **Semantic** | What kind of element? | `hierarchyWeight` (extension) | derived |
| **Temporal** | How much evidence? | `observationCount` on `Track` | engine-maintained |
| **Contextual** | What context was it in? | `ContextualInvalidationCheck` | callback (optional) |

## Types

Every exported type, with the same two columns as the tier table.

### Interfaces

| Type | Public? | Usually instantiate? | Purpose |
|------|---------|----------------------|---------|
| `Observation<T>` | Yes | Usually no (implemented by `DefaultTrackedBlock`) | Core block contract (7 getters including the opaque `payload`; the 2.x coordinate flags are derived views) |
| `Track<T>` | Yes | Usually no (implemented by `DefaultTrackedBlock`) | Extends `Observation`; adds observation history (8 getters: counts, votes, provisional state) |
| `ClassificationInput` | Yes | Usually no | Platform-agnostic viewport geometry |
| `CarouselInput` | Yes | Usually no | Carousel-specific geometry |
| `SubmapMembership` | Yes | Usually no (default `CssSubmapMembership`) | Strategy for coordinate-space partitioning |
| `ContextualInvalidationCheck` | Yes | Optional (callback) | Callback for context-change detection |
| `SpatialIndexView<T>` | Yes | Returned by engine | Read-only spatial-index contract — the type of `engine.spatialIndex` (2.0.0+) |
| `MergeDecisionCallback` | Yes | Optional (callback) | Callback type of `ParagraphGrouper.onMergeDecision` (2.0.0+) |

### Components

| Type | Public? | Usually instantiate? | Purpose |
|------|---------|----------------------|---------|
| `StabilizationEngine<T, P>` | Yes | Optional (custom `Track`); `OcrStabilizer` otherwise | SAR-merge, intra-batch dedup, contradiction detection |
| `StabilizerConfig` | Yes | Optional | Every engine lever, grouped by stage: `MatchingConfig`, `MergeConfig`, `StepResponseConfig` (+ `CoherentShiftConfig`, `ExperimentalCoherentShiftOptions`), `RetentionConfig`, `DiagnosticsConfig` (3.0+) |
| `DriftTracker` | Yes | Usually no | Regional drift correction with submap isolation |
| `SpatialBlockIndex` | Yes | Usually no | Grid-cell spatial index for overlap queries (implements `SpatialIndexView`) |
| `BlockClassifierService` | Yes | Optional — standalone; the engine neither builds nor accepts one | Classifies blocks into fixed / sticky / carousel / IC / normal |
| `OverlapResolver` | Yes | Usually no (the engine builds its own) | Spatial NMS with language-aware thresholds |
| `BlockKeyGenerator` | Yes | Usually no (the engine builds its own) | Position + text dedup keys with fuzzy neighbor matching |
| `CssSubmapMembership` | Yes | Usually no | Default WebView submap partitioning |
| `HierarchyWeightX` (extension) | Yes | No — a derived view on every `Observation` | `hierarchyWeight` from the coordinate frame |
| `ParagraphGrouper` | Yes | Optional (after the engine) | CJK-aware block→paragraph grouping (Otsu gap clustering + noise guards) |
| `otsusThreshold` / `otsusThresholdWithFallback` | Yes | Optional (function) | Otsu bimodal threshold for 1-D gap distributions (function API) |
| `RobustStats` | Yes | No — static | Robust statistics (median, MAD, IQR) |
| `IqrOutlier` | Yes | No — static | Tukey-fence outlier detection |
| `TextDedupUtils` | Yes | No — static | Levenshtein, Jaccard, CJK detection helpers |

### BandFallback (v0.4.0+)

| Type | Public? | Usually instantiate? | Purpose |
|------|---------|----------------------|---------|
| `BandFallbackConfig` | Yes | Optional (inside `MatchingConfig`) | Configures the band-relaxed matching path. Default `mode: off`. |
| `BandFallbackMode` | Yes | Optional (value) | `off` (no band loop) / `observeOnly` (counters only) / `admit` (production). |
| `BandFallbackStats` | Yes | Returned by engine | Read-only per-capture telemetry exposed via `engine.bandStats`. |
| `BandSpatialPredicate` | Yes | Optional (callback) | Optional `bool Function(Observation fresh, Observation candidate)` injection. `null` → engine substitutes a drift-aware `overlapRatio >= 0.80` closure. |
| `BandPredicateException` | Yes | Returned by engine (thrown) | Typed wrapper for consumer-predicate throws (v0.5.0+) — caught and rewrapped by the engine so failures surface with a typed shape, never swallowed. Original predicate stack lives on `predicateStackTrace`. |

### Reference Implementations

| Type | Public? | Usually instantiate? | Purpose |
|------|---------|----------------------|---------|
| `DefaultTrackedBlock<T>` | Yes | **Yes** | Concrete `Track<T>` with documented defaults, `copyWith`, and `applyMerge(MergeResult)` — the fastest path for new integrators |

### Result Types

| Type | Public? | Usually instantiate? | Purpose |
|------|---------|----------------------|---------|
| `StabilizationResult<T>` | Yes | Returned by engine | Output of `engine.stabilize()` — stable blocks + bookkeeping |
| `MergeResult` | Yes | Returned by engine (to your merger) | Exhaustive engine-computed delta passed to `BlockMerger` |
| `CarouselVotes` | Yes | Optional — `none()` is the default; `seeded(index)` to count construction as an observation | Histogram of horizontal-scroller indices a block was observed under; `none()`, `seeded(index)`, `record(index)`, `hasObservedCarousel` (3.0+) |
| `ClassificationResult` | Yes | Returned by `BlockClassifierService` | Output of `BlockClassifierService` |
| `MergeDecisionDiagnostic` | Yes | Via `ParagraphGrouper.onMergeDecision` (optional callback) | One grouper boundary decision — verdict, reason set, gap/threshold context (2.0.0+) |
| `CoherentShiftEvent` | Yes | Returned by engine | The coherent shift a capture applied — translation, member count, adopted count, deciding path (2.5.0+) |
| `IdentityTurnover` | Yes | Returned by engine | Per-capture identity census — merged / admitted / retained / dropped, `admittedShare` (2.5.0+) |
| `TransformEstimate` | Yes | Returned by engine | Per-capture similarity-transform fit over the matched pairs — `scale`, `translation`, `fixedPoint`, `residualPx`, `spanPx`, `pairCount`, `rejectedPairs`; observed, never applied (2.6.0+) |

### Value Types

| Type | Public? | Usually instantiate? | Purpose |
|------|---------|----------------------|---------|
| `CoordinateContext` | Yes | Optional (`page()` default) | Sealed frame of a block's rect: `page(scroll:)`, `innerScroller(top:, containerId:, scroll:)`, `viewport(stickyFallback:)`; `fromFlags(...)` adapts flat flags (3.0+) |
| `ScrollContext` | Yes | Optional (inside `CoordinateContext`) | Scroll offsets and carousel identity at capture time |
| `StickyFallback` | Yes | Optional (inside `viewport(...)`) | Fallback coordinate context for demoted sticky elements |
| `TextVote` | Yes | Returned by engine | Accumulated confidence evidence for one text variant |
| `MergeRejectReason` | Yes | Via `ParagraphGrouper.onMergeDecision` (optional callback) | 9-value enum naming every grouper rejection guard (2.0.0+) |
| `CoherentShiftSource` | Yes | Returned by engine | 3-value enum naming the path that decided a coherent shift — quorum / floor / reanchor (2.5.0+) |

### Extension Types

| Type | Wraps | Public? | Usually instantiate? | Purpose |
|------|-------|---------|----------------------|---------|
| `AbsoluteRect` | `Rect` | Yes | **Yes** — wrap every rect you hand in | World-space coordinate safety |
| `ContainerId` | `String` | Yes | Optional — only with `innerScroller(...)` | Stable container identity |
| `SpaceKey` | `String` | Yes | Usually no (derived from `coordinates`) | Typed drift observation keys |
| `PositionConfidence` | `double` | Yes | Optional — defaults to ground truth | Position-accuracy confidence in [0, 1] |
| `TextConfidence` | `double` | Yes | Optional — defaults to ground truth | OCR-text confidence in [0, 1] |
