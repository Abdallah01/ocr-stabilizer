# ocr_stabilizer

A real-time stabilization engine for live OCR overlays. Tracks text block
identity across noisy captures, corrects positional drift, and provides
spatial indexing for deduplication.

Built for Flutter. Designed for OCR pipelines where screenshots are captured
at 1-2 Hz and translated overlays must remain stable as the user scrolls.

## The Problem

Live OCR on scrollable content produces a stream of noisy, jittery observations.
The same paragraph appears at slightly different positions each capture. Without
a stabilization layer, overlays flicker, duplicate, and drift.

This is the same problem visual SLAM (Simultaneous Localization and Mapping)
solves in robotics: associate noisy sensor observations to persistent landmarks,
correct accumulated drift, and maintain a consistent map. `ocr_stabilizer`
adapts SLAM techniques to the OCR domain.

## Installation

```yaml
dependencies:
  ocr_stabilizer: ^0.2.2
```

> **0.2.0 was a breaking change** from 0.1.0 —
> `TrackedBlock.positionConfidence` and `textConfidence` switched from
> `double` to typed `PositionConfidence` / `TextConfidence`. See the
> [CHANGELOG](CHANGELOG.md#020) for the migration. 0.2.1 and 0.2.2 are
> docs/infra-only follow-ups — no further API change.

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

// Caller contract: rebuild the spatial index after each stabilize call.
// `rebuild` replaces the index atomically; using `add` in a real capture
// loop without removing prior versions would accumulate stale blocks.
engine.spatialIndex.rebuild(result.stableBlocks);
```

See [`example/example.dart`](example/example.dart) for a runnable version.

For app-specific block types not covered by `DefaultTrackedBlock`, implement
`TrackedBlock<T>` directly — see the next section.

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

### Components

| Type | Purpose |
|------|---------|
| `StabilizationEngine<T, P>` | SAR-merge, intra-batch dedup, contradiction detection |
| `DriftTracker` | Regional drift correction with submap isolation |
| `SpatialBlockIndex` | Grid-cell spatial index for overlap queries |
| `BlockClassifierService` | Classifies blocks into fixed / sticky / carousel / IC / normal |
| `OverlapResolver` | Spatial NMS with language-aware thresholds |
| `BlockKeyGenerator` | Position + text dedup keys with fuzzy neighbor matching |
| `CssSubmapMembership` | Default WebView submap partitioning |
| `RobustStats` | Robust statistics (median, MAD, IQR) |
| `IqrOutlier` | Tukey-fence outlier detection |
| `TextDedupUtils` | Levenshtein, Jaccard, CJK detection helpers |

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

### Value Types

| Type | Purpose |
|------|---------|
| `ScrollContext` | Scroll offsets and carousel identity at capture time |
| `StickyFallback` | Fallback coordinate context for demoted sticky elements |
| `TextVote` | Accumulated confidence evidence for one text variant |

### Extension Types

| Type | Wraps | Purpose |
|------|-------|---------|
| `AbsoluteRect` | `Rect` | World-space coordinate safety |
| `ContainerId` | `String` | Stable container identity |
| `SpaceKey` | `String` | Typed drift observation keys |
| `PositionConfidence` | `double` | Position-accuracy confidence in [0, 1] |
| `TextConfidence` | `double` | OCR-text confidence in [0, 1] |

## Platform Support

The package depends on `dart:ui` (for `Rect`, `Offset`) and therefore
requires the Flutter SDK. It has no platform-specific code — it works on
Android, iOS, macOS, Windows, Linux, and Web.

The `SubmapMembership` and `ClassificationInput` interfaces allow the engine
to support different input sources:

| Platform | SubmapMembership | ClassificationInput |
|----------|-----------------|-------------------|
| WebView | `CssSubmapMembership` (default) | `CaptureSnapshotAdapter` (app-side) |
| PDF | Custom (page-based submaps) | Custom (page geometry) |
| Camera | Custom (frame regions) | Custom (camera frame) |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, conventions, and the
release flow.

