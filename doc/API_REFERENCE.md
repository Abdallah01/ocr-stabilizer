<!-- Relocated from README.md in #144 (2026-09-08): the README keeps the
     quick start; reference material lives here. Content unchanged. -->

# API reference

## Core components

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

## Six-dimension block identity

A block's identity is a six-dimensional signature:

| Dimension | What It Answers | Package Support |
|-----------|----------------|-----------------|
| **Textual** | What does this text say? | `originalText` on TrackedBlock |
| **Spatial** | Where is it in the page? | `absoluteRect`, confidence scores |
| **Relative** | Which coordinate space? | `SpaceKey`, `ContainerId` |
| **Semantic** | What kind of element? | `hierarchyWeight` (extension) |
| **Temporal** | How much evidence? | `observationCount` (ObservableBlock) |
| **Contextual** | What context was it in? | `ContextualInvalidationCheck` (callback) |

## Types

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
| `StabilizerConfig` | Every engine lever, grouped by stage: `MatchingConfig`, `MergeConfig`, `StepResponseConfig` (+ `CoherentShiftConfig`, `ExperimentalCoherentShiftOptions`), `RetentionConfig`, `DiagnosticsConfig` (3.0+) |
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
| `CarouselVotes` | Histogram of horizontal-scroller indices a block was observed under; `none()`, `seeded(index)`, `record(index)`, `hasObservedCarousel` (3.0+) |
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
