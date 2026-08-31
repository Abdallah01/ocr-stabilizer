# The 2.x contract

What `ocr_stabilizer` 2.x guarantees, what it deliberately does not do, and
what is yours to configure. This page is the release-stability promise: a
2.x consumer can hold the package to every line in the first section, must
not rely on anything in the second, and owns every decision in the third.

Each claim cites its enforcement — a test, a committed validation entry, or
a tracking issue. Where a default changed inside 2.x, an exact escape hatch
is named; that escape is itself part of the contract.

## 1. Guarantees

**G1 — Render at first sight, refine on re-sight.** `stabilize()` returns a
first-sighting block in `StabilizationResult.stableBlocks` on the very call
that observed it. Nothing is withheld while evidence accrues; observation
counts are evidence depth, never a readiness ladder. The engine has no
internal clock and no warm-up — the classifier reads time only for a
capture-freshness term feeding position confidence. (README "Timing
model"; first-sighting behavior exercised throughout
`test/stabilization_engine_test.dart`.)

**G2 — Identity survives jitter.** A re-observed block merges into its
tracked identity rather than spawning a duplicate, through the primary
match, the opt-in band-relaxed path (`BandFallbackConfig`), and nested
re-observation (a paragraph re-seen as one of its own lines confirms the
paragraph, 2.2.0). Intra-batch duplicates are resolved by spatial NMS.

**G3 — Corrections are bounded.** Drift correction is clamped to the median
block height per region (`DriftTracker`). A coherent-shift plan re-anchors
a block only by a translation that block itself made to within the
clustering tolerance — no member is ever pushed past its own observation,
adopted under-gate pairs included
(`test/stabilization_engine_coherent_shift_adopt_agreeing_test.dart`).

**G4 — State is bounded.** Engine state does not grow without limit under a
continuous capture stream: dismissal/vote/history structures are capped, and
a 900-capture continuous-scroll replay pins it
(`test/long_session_replay_test.dart`, `doc/benchmarks/`).

**G5 — Numerics changes ship with an exact escape.** Every behavioral
default change inside 2.x names a configuration that reproduces the prior
numerics bit-for-bit, and the claim is replay-verified on the committed
corpus, not asserted:

| Changed in | New default | Exact escape to prior numerics |
|---|---|---|
| 2.3.0 | `stepResponse: StepResponse.coherentShift` | `stepResponse: StepResponse.damp` (2.2.0 numerics) |
| 2.4.0 | `coherentShiftAdoptAgreeing: true` | `coherentShiftAdoptAgreeing: false` (2.3.x numerics) |

The two #119 fallbacks (`coherentShiftFloorPx`,
`coherentShiftReanchorMinBlocks`) default to `null` = disabled; leaving
them unset reproduces the un-floored quorum bit-for-bit.

**G6 — Defaults are evidence-backed and regeneratable.** Every default
numerics change is backed by a committed replay corpus and an A/B report
that a test can regenerate and compare byte-for-byte
(`test/replay/ab_report_committed_equivalence_test.dart`); the experiment
documents' result tables are parsed and checked against the committed
reports (`test/replay/experiment_doc_tables_test.dart`); the demo GIF's
frames are pinned to engine output (`test/demo_gif_provenance_test.dart`).

**G7 — Consumer callbacks are never swallowed.** A throwing band predicate
surfaces as a typed `BandPredicateException` with the original stack; a
throwing `positionLookup` and non-finite inputs are delivered through the
`debugLogger` at anomaly severity in every build mode (1.0.1, #78). Input
validation throws (`ArgumentError` on NaN/out-of-range confidences) rather
than degrading silently.

**G8 — Pure Dart.** No Flutter SDK dependency (0.8.0+). Geometry uses the
package's own `Rect`/`Offset`/`Size`; the render-boundary conversion is
two extensions (README "Platform Support").

**G9 — API stability.** Within 2.x, API surface changes are additive.
Behavioral-default changes ride minor versions with a CHANGELOG entry and a
G5 escape — the repo's own convention (CONTRIBUTING.md). Compile-breaking
changes wait for 3.0.

## 2. Intentionally unsupported in 2.x

Relying on any of these is out of contract; each has a tracking issue where
the boundary is discussed.

**U1 — The engine does not know what a paragraph is.** The unit of tracking
is whatever the consumer feeds `stabilize()` — lines, paragraphs, DOM
nodes. `ParagraphGrouper` is a downstream convenience for consumers that
want translation-sized units; its defaults (`maxParagraphBlocks: 3`,
`maxParagraphRunes: 200`, sentence-end explosion) are translation-request
sizing, not the engine's identity model. Grouping BEFORE tracking imports
the grouper's instability into identity (measured:
`doc/replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md`, pre-grouped
addendum) — group downstream of the engine. ([#101], [#100], [#99])

**U2 — Multi-column pages have no per-region statistics.** The grouper's
Otsu gap threshold is batch-global; multi-column layouts are handled by
per-merge guards only. ([#91])

**U3 — Steps inside the jitter allowance damp.** A single-frame layout step
small enough to sit inside a block's own agreement scale (3x its height —
e.g. the 50 px corpus stream) is indistinguishable from jitter by design
and is damped, not re-anchored. This is the deliberate cost of zero false
step events on every control stream. ([#119], EXPERIMENT.md)

**U4 — Large slabs beyond the quorum need a calibrated floor.** A
single-frame slab so large that fewer movers survive matching than the
quorum requires falls through to damp unless the consumer calibrates
`coherentShiftFloorPx` (see the README recipe). The floor is a property of
the consumer's capture geometry; the package ships no universal value.
([#119])

**U5 — One engine instance per continuous visual session.** There is no
engine-wide reset; construct fresh at document boundaries. ([#95])

**U6 — Out-of-band index mutation is injector-owned.** `engine.spatialIndex`
is a read-only view (2.0.0). Mutating an injected `SpatialBlockIndex`
bypasses confidence validation and survives only until the next
`stabilize()` rebuilds the index. ([#96])

**U7 — Cross-engine transfer is proven for one regime.** Defaults were
calibrated on ML-Kit-shaped noise and transfer to Tesseract's
photometric-jitter regime without retuning
(`doc/replay/validation/2026-08-tesseract-matrix/`). High-amplitude
re-segmentation on other engines is open. ([#94])

**U8 — No wall-clock behavior.** Nothing decays, expires, or resolves on a
timer. A stream that stops producing captures stops changing. Consumers
needing time-based eviction implement it via the injected index (U6) or
their own layer above the engine.

## 3. Consumer-configurable behaviors

The stable recipe is the constructor defaults. Knobs, grouped by decision:

**Step response** — `stepResponse` (`coherentShift` default / `damp` /
`snap`); quorum shape `coherentShiftMinBlocks`, `coherentShiftMinShare`,
`coherentShiftTolerance`; `coherentShiftAdoptAgreeing` (default `true`,
2.4.0). Opt-in fallbacks where the quorum starves:
`coherentShiftFloorPx` — supported, but calibrate it to your own capture
cadence per the README recipe; `coherentShiftReanchorMinBlocks` —
documented, **not recommended**, and outside the stable recipe (its count
axis measurably cannot separate slabs from scroll; see its doc comment).

**Position model** — `positionMergeModel` (`agreementWeighted` default /
`legacy` for exact 0.x numerics).

**Identity retention** — `missedFrameRetention` (default 0),
`ContextualInvalidationCheck`, `SubmapMembership` strategy.

**Matching reach** — `bandFallback` (`off` default / `observeOnly` /
`admit`; adopt via the counter-reading flow in the README).

**Geometry** — `updateViewport()` or `updateBucketSizes()`; an injected
`SpatialBlockIndex` for out-of-band eviction/restore (with U6's caveats).

**Unit of tracking** — yours entirely (U1). If you want paragraph-shaped
units, run `ParagraphGrouper` downstream and size it yourself
(`lineGapThreshold`, `lineGapMultiplier`, `maxParagraphBlocks`,
`maxParagraphRunes`); its CJK-tuned defaults are a starting point for CJK
prose, not a recommendation for other scripts.

**Diagnostics** — `debugLogger` (opt-in), `ParagraphGrouper.onMergeDecision`,
`engine.bandStats`.

[#91]: https://github.com/Abdallah01/ocr-stabilizer/issues/91
[#94]: https://github.com/Abdallah01/ocr-stabilizer/issues/94
[#95]: https://github.com/Abdallah01/ocr-stabilizer/issues/95
[#96]: https://github.com/Abdallah01/ocr-stabilizer/issues/96
[#99]: https://github.com/Abdallah01/ocr-stabilizer/issues/99
[#100]: https://github.com/Abdallah01/ocr-stabilizer/issues/100
[#101]: https://github.com/Abdallah01/ocr-stabilizer/issues/101
[#119]: https://github.com/Abdallah01/ocr-stabilizer/issues/119
