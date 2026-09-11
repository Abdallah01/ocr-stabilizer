<!-- Relocated from README.md in #144 (2026-09-08): the README keeps the
     quick start; reference material lives here. Content unchanged. -->

# Design decisions and known limits

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
  [`EXPERIMENT.md`](replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md)
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

## Framing

An earlier README introduced the package by analogy: This is the same problem visual SLAM (Simultaneous Localization and Mapping) solves in robotics: associate noisy sensor observations to persistent landmarks, correct accumulated drift, and maintain a consistent map. `ocr_stabilizer` adapts SLAM techniques to the OCR domain.
The analogy imports more than the engine does (no pose, no map optimisation,
no loop closure); the precise framing is temporal association + geometric
stabilization + spatial deduplication of noisy text observations.
