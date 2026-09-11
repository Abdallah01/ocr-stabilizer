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
  ocr_stabilizer: ^3.0.0
```

## Quick start

`DefaultTrackedBlock<T>` is the fastest path — a concrete block with
documented defaults for every field the engine reads.

```dart
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

final engine = OcrStabilizer<MyPayload>(
  // Every lever has a documented default; group overrides by stage:
  // config: StabilizerConfig(retention: RetentionConfig(missedFrames: 2)),
);
// Spelled out, this is StabilizationEngine<DefaultTrackedBlock<MyPayload>,
// MyPayload>(merger: (existing, fresh, merge) => existing.applyMerge(merge)).

// Each capture (e.g. a screenshot on scroll-settle, 1–2 Hz):
final blocks = ocrResults.map((ocr) => DefaultTrackedBlock<MyPayload>(
  absoluteRect: ocr.absoluteRect,
  originalText: ocr.text,
  payload: ocr.payload,                               // opaque to the engine
  positionConfidence: PositionConfidence.from(ocr.posConf),
  textConfidence: TextConfidence.from(ocr.txtConf),
)).toList();

final result = engine.stabilize(blocks);
for (final block in result.stableBlocks) {
  // Render at first sight; re-observations only refine the box and text.
}
```

Runnable version: [`example/example.dart`](example/example.dart). Your own
block type: implement `Track<T>` — an `Observation<T>` (rect, frame, text,
confidences, payload: 7 getters) plus the engine-owned state (count, votes,
provisional status: 8 getters) — see the [API reference](doc/API_REFERENCE.md).

Every `stabilize()` result also reports what the engine decided this
capture — a coherent shift, the identity turnover, a similarity-transform
estimate — so a layout layer can react without reverse-engineering
`stableBlocks`: [observing the engine's decisions](doc/OBSERVING_DECISIONS.md).

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

| Type | Purpose |
|------|---------|
| `StabilizationEngine<T, P>` | The pipeline above; `stabilize(blocks)` per capture, or `merge(fresh, existing)` when you run your own matching |
| `Observation<T>` / `Track<T>` | What you supply per capture / what the engine keeps and returns |
| `DefaultTrackedBlock<T>` | Reference block with defaults, `copyWith`, `applyMerge` |
| `StabilizationResult<T>` | `stableBlocks` + `coherentShift`, `identityTurnover`, `transformEstimate`, contradictions |
| `DriftTracker` | Per-region drift correction (bounded to a line height, rolling window, submap isolation) |
| `SpatialBlockIndex` | Grid-cell candidate lookup; three coordinate-space namespaces |
| `ParagraphGrouper` | Downstream grouping into translation-sized units — not part of the identity model |
| `AbsoluteRect`, `ContainerId`, `SpaceKey`, `PositionConfidence`, `TextConfidence` | Zero-cost typed wrappers for coordinate and confidence safety |

Full tables — interfaces, components, result and value types, the
six-dimension identity model, hierarchy weights:
[`doc/API_REFERENCE.md`](doc/API_REFERENCE.md).

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
