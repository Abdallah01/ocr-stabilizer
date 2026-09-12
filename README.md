# ocr_stabilizer

A real-time stabilization engine for live text-capture pipelines — OCR
overlays and DOM/text extraction alike. It tracks text-block identity
across noisy captures, corrects positional drift, and provides spatial
indexing for deduplication: temporal association + geometric
stabilization + spatial dedup of noisy text observations. Extraction
streams are a first-line use case, not an afterthought — identity
tracking, dedup and text voting are exactly what keeps an extraction
pipeline consistent across re-captures, while the position-merge
refinements matter most for rendered overlays.

Pure Dart — Flutter apps and server-side pipelines alike. No internal
clock, no warm-up: a block is usable from its **first** observation; later
captures only refine it ([timing model](doc/TIMING_MODEL.md)).

**The 2.x contract** — what the package guarantees, what it deliberately
does not do, and what is yours to configure — is one page:
[`doc/CONTRACT.md`](doc/CONTRACT.md).

## Installation

```yaml
dependencies:
  ocr_stabilizer: ^3.1.0 # OcrStabilizer arrived in 3.1.0
```

## Quick start — the whole basic integration

Copy this. It is everything a first integration needs.

```dart
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// Once, for the life of the capture stream. Defaults for everything.
final stabilizer = OcrStabilizer<MyPayload>();

// Every capture: wrap your OCR boxes, hand them over, render what comes back.
final observations = ocrResults.map((r) => DefaultTrackedBlock<MyPayload>(
  absoluteRect: AbsoluteRect(r.rect), // page coordinates, wrapped (see Level 1)
  originalText: r.text,
  payload: r.payload,                 // anything of yours; the engine never reads it
)).toList();

final result = stabilizer.stabilize(observations);

for (final block in result.stableBlocks) {
  renderText(text: block.originalText, rect: block.absoluteRect.raw);
}
```

(`r.rect` is the package's own `Rect`; a Flutter `ui.Rect` becomes one with
`.toStabilizer()` from [Platform support](#platform-support).)

That is the whole basic integration. `result.stableBlocks` are the blocks to
draw for **this** capture: a block is drawable from its first observation,
and later captures only refine its box and text ([timing
model](doc/TIMING_MODEL.md)). Runnable version:
[`example/example.dart`](example/example.dart).

### Level 1 — I just want stabilization

- **The defaults are the product.** `OcrStabilizer<MyPayload>()` with no
  arguments is the measured configuration: every lever's default carries
  its own validation history in [`doc/`](doc/README.md), and an entry that
  overrides one says so in its caption (the demo below names its one
  override). Configuration is the escape hatch, not a setup step.
- **Two fields are required** on `DefaultTrackedBlock`: `absoluteRect` and
  `payload`. Confidences default to ground truth; pass
  `positionConfidence: PositionConfidence.from(x)` /
  `textConfidence: TextConfidence.from(x)` only if your OCR gives you them.
- **Coordinates: use the default.** `CoordinateContext.page()` is the
  default, so you can omit the field entirely. A horizontal carousel child
  stays in page coordinates too (`page(scroll: ...)` carries its carousel
  identity). Reach for `innerScroller(...)` only for a vertically
  scrolling container inside the page, and `viewport(...)` only for
  fixed-position content — the `CoordinateContext` row of the
  [API reference](doc/API_REFERENCE.md) lists the three constructors.
- **Capture rate.** Designed for event-driven capture pipelines (a
  screenshot on scroll-settle, a DOM re-extraction); validated extensively
  at about 1–2 captures per second. That is the design target, not an
  operating limit.
- **Why does this package have its own `Rect`?** It is pure Dart and runs
  outside Flutter, so its geometry types (`Rect`, `Offset`, `Size`, member-
  compatible with `dart:ui`'s) do not depend on `dart:ui`. Flutter apps
  convert at the render boundary — the two-line extensions are under
  [Platform support](#platform-support). `AbsoluteRect` is a zero-cost
  wrapper that marks a `Rect` as page-absolute: `AbsoluteRect(rect)` in,
  `.raw` out, `AbsoluteRect.fromLTWH(...)` to build one directly.

### Level 2 — what is happening

You give the engine **observations**; it keeps **tracks**.

- An `Observation<T>` is what you supply per capture: rect, text,
  coordinates, two confidences, source quality, payload (7 getters).
- A `Track<T>` is an observation plus the state the engine accumulates:
  observation count, text and classification votes, provisional status
  (8 more getters). The engine only ever reads the observation half of a
  fresh block and writes the state half through a merger.
- `DefaultTrackedBlock<T>` is a ready-made `Track<T>` with defaults for the
  state half. **You normally do not implement `Track`.** Give the engine
  fresh observations as `DefaultTrackedBlock`s and let it carry the state.

Each `stabilize()` call dedups the capture, matches each fresh block to a
tracked one, decides whether a group of blocks moved together (a real
layout reflow) or jittered individually, merges positions and votes, and
retains or drops what went unobserved — the five steps under [How it
works](#how-it-works).

Besides `stableBlocks`, a result carries optional signals for a layout
layer: `coherentShift` (a decided shared translation, applied to the
tracked blocks that followed it — a slab can move while other blocks stay
put), `identityTurnover` (how many fresh blocks were merged / admitted as
new, and how many cached identities were retained / dropped),
`transformEstimate` (a similarity transform over the matched pairs). Ignore them until you need
them: [observing the engine's decisions](doc/OBSERVING_DECISIONS.md).

### Level 3 — I need custom persistent state, or a lever

- **Your own block type.** Implement `Track<T>` and construct the general
  engine yourself: `StabilizationEngine<MyBlock, MyPayload>(merger: (existing,
  fresh, merge) => existing.copyWith(/* apply merge */))`. `OcrStabilizer`
  is exactly `StabilizationEngine<DefaultTrackedBlock<P>, P>` with that
  merger pre-wired — the differential test pins the two identical capture
  for capture — so moving up changes nothing about behaviour. See the
  [API reference](doc/API_REFERENCE.md).
- **A lever.** Every lever has a documented default and a measured history,
  grouped by stage:

  ```dart
  OcrStabilizer<MyPayload>(
    config: StabilizerConfig(retention: RetentionConfig(missedFrames: 2)),
  );
  ```

  Reach for one only with a measured reason ([contract](doc/CONTRACT.md)
  lists what is yours to configure).

![Demo: raw per-frame ML Kit boxes jittering on the left; the same stream stabilized on the right](https://raw.githubusercontent.com/Abdallah01/ocr-stabilizer/9e8df3f/doc/media/stabilizer-demo-mlkit.gif)

*Real **ML Kit** output on a Galaxy S25 over a synthetic page (the
committed [on-device corpus](doc/replay/validation/2026-08-mlkit-on-device/)),
14 captures under scripted micro-scrolls, the same drawing rule on both
panels. Left: the boxes as the production pipeline reports them each
frame. Right: the engine's tracked state under `StabilizationEngine`
defaults plus `missedFrameRetention: 2`. Engine output, not an
illustration — rendered by
[`tool/replay/dump_frames.dart`](tool/replay/dump_frames.dart) +
[`doc/media/render_demo_gif.py`](doc/media/render_demo_gif.py), and
`test/demo_gif_provenance_test.dart` pins the claim; the corpus entry
explains the remaining overlaps in the last frames. A
[Tesseract twin](https://raw.githubusercontent.com/Abdallah01/ocr-stabilizer/6d6c04a/doc/media/stabilizer-demo.gif)
renders from the fully synthetic
[cross-engine corpus](doc/replay/validation/2026-08-tesseract-matrix/).*

## How it works

```
   your app -- OCR boxes --> ocr_stabilizer (identity . matching . position . dedup . retention)
                                     |
                                     v  stable blocks (this capture)
                             ParagraphGrouper (optional; takes OcrBlocks)
                                     |
                                     v  translation / rendering
```

Live OCR on scrollable content produces a stream of noisy, jittery
observations: the same paragraph appears at slightly different positions
each capture, and without a stabilization layer overlays flicker,
duplicate and drift. Each `stabilize()` call:

1. **Dedups the capture** — noise filter, position+text key dedup, spatial
   non-maximum suppression within the batch.
2. **Matches** each fresh block to a tracked one — text similarity first,
   with an optional band-relaxed second pass for single-frame OCR flips
   ([band fallback](doc/BAND_FALLBACK.md)) and nested-fragment
   confirmation.
3. **Decides the step response** — when a batch of blocks moves together
   (a real layout reflow) the group re-anchors instead of being damped as
   per-block jitter (`StepResponse.coherentShift`, the default;
   [calibration](doc/COHERENT_SHIFT_CALIBRATION.md) for the optional floor).
4. **Merges** — drift-corrected, agreement-weighted position merge; text
   and classification votes; position and text confidence.
5. **Retains or drops** unmatched tracked blocks (`missedFrameRetention`)
   and rebuilds the spatial index.

Observation counts are evidence depth, never a readiness ladder: nothing
is withheld while evidence accrues ([timing model](doc/TIMING_MODEL.md)).

## Core components

The types on the basic path, in the order you meet them:

| Type | Purpose |
|------|---------|
| `OcrStabilizer<P>` | The common path: `stabilize(blocks)` per capture, defaults for everything, one generic parameter (your payload) |
| `DefaultTrackedBlock<P>` | The block you construct per OCR box: `absoluteRect` + `payload` required, defaults for the rest |
| `StabilizationResult<DefaultTrackedBlock<P>>` | What `stabilize()` returns: `stableBlocks` to draw, plus the optional `coherentShift` / `identityTurnover` / `transformEstimate` signals |
| `CoordinateContext` | `page()` (the default — omit it), `innerScroller(...)`, `viewport(...)` |

You might need `StabilizerConfig` (a lever with a measured reason) and
`ParagraphGrouper` (grouping stable blocks into translation-sized units —
downstream of the engine, not part of its identity model). Everything
else — `StabilizationEngine` for a custom `Track`, `DriftTracker`,
`SpatialBlockIndex`, `BandFallback`, the value types — is listed by tier
with a "do I normally instantiate this?" answer in the
[API reference](doc/API_REFERENCE.md).

## Platform support

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
`BlockClassifierService` or `DriftTracker` (default is silent). Chatty
lines fire in debug builds only; anomaly-class events — non-finite input
skips, a throwing `positionLookup` callback — are delivered in every build
mode (#78).

The `SubmapMembership` and `ClassificationInput` interfaces let the engine
support different input sources:

| Platform | SubmapMembership | ClassificationInput |
|----------|-----------------|-------------------|
| WebView | `CssSubmapMembership` (default) | `CaptureSnapshotAdapter` (app-side) |
| PDF | Custom (page-based submaps) | Custom (page geometry) |
| Camera | Custom (frame regions) | Custom (camera frame) |

## Docs

| Page | What it answers |
|---|---|
| [`doc/CONTRACT.md`](doc/CONTRACT.md) | The 2.x guarantees, intentionally unsupported cases, and consumer-configurable behaviours — each with its enforcing test or validation entry |
| [`doc/API_REFERENCE.md`](doc/API_REFERENCE.md) | Every public type, the six-dimension identity model, hierarchy weights |
| [`doc/OBSERVING_DECISIONS.md`](doc/OBSERVING_DECISIONS.md) | Reading `coherentShift`, `identityTurnover`, `transformEstimate` from a layout layer |
| [`doc/TIMING_MODEL.md`](doc/TIMING_MODEL.md) | Render at first sight, refine on re-sight |
| [`doc/BAND_FALLBACK.md`](doc/BAND_FALLBACK.md) | The band-relaxed second matching pass and its adoption flow |
| [`doc/COHERENT_SHIFT_CALIBRATION.md`](doc/COHERENT_SHIFT_CALIBRATION.md) | The `coherentShiftFloorPx` recipe |
| [`doc/DESIGN_DECISIONS.md`](doc/DESIGN_DECISIONS.md) | Deliberate trade-offs and known limits, each with its tracking issue |
| [`doc/RELEASE_NOTES.md`](doc/RELEASE_NOTES.md) | The narrative "what's new" per version; the exact record is [`CHANGELOG.md`](CHANGELOG.md) |
| [`doc/README.md`](doc/README.md) | Map of the validation entries (which engine, which numbers), benchmarks and the replay tool |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for dev setup, conventions, and the
release flow.
