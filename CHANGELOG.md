## Unreleased

### Added
- **`StabilizationEngine.coherentShiftFloorPx` (#119)** — an opt-in
  absolute-pixel floor that closes `StepResponse.coherentShift`'s
  large-slab blind spot. When a single-frame layout step is big enough
  that most lines leave the viewport, too few movers survive the primary
  spatial match for the `coherentShiftMinBlocks` / `coherentShiftMinShare`
  quorum to see (measured: on the 600 px validation stream the move
  capture leaves exactly ONE matched mover), so the whole capture fell
  through to damp. A moved pair clearing this absolute floor is now
  admitted on its own magnitude, bypassing both count gates, provided the
  floor-qualified movers agree in direction AND cluster within the
  quorum's own tolerance (the largest such cluster is re-anchored by its
  own median; a floor-qualified mover outside it stays on damp, so no
  member is ever pushed past its own observation) — and only where the
  ordinary quorum already declined, so captures the majority vote handles
  are untouched. `null` (the default) reproduces 2.3.0 numerics
  bit-for-bit.
  Evidence: the 17-stream A/B re-run at 390 px — 0 step events on all 10
  controls, 0.000 px regression on every stream, and the 600 px stream's
  lag at the move cut 30.7 -> 1.4 px. The floor must be calibrated to the
  consumer's own capture cadence; a height-relative multiplier
  provably cannot do this job (on the corpus a scroll control reaches
  3.63x its own scale while the real slab is only 2.64x). See
  `doc/replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md`'s
  "closing the large-slab blind spot" section.
- **`StabilizationEngine.coherentShiftReanchorMinBlocks` (#119)** — an
  opt-in relaxation of the same quorum on the COUNT axis instead
  (clustering unchanged, share gate dropped, the winning cluster
  re-anchored by its own median). `null` (the default) reproduces 2.3.0
  numerics bit-for-bit. Documented as **not recommended** and measured as
  such: only a count of 1 reaches the large-slab case, and a single mover
  is equally what ordinary scroll and OCR jitter produce, so it
  false-fires on 4 of 10 control streams; any higher count leaves the
  blind spot open. Kept for consumers whose own corpus has large slabs
  that do leave several matched movers behind.

### Internal
- **Provenance guard hardening (#125, #127, #128).** The dynamic-reflow
  originals `pushdown.ab.json` / `rewrap.ab.json` were regenerated from
  their committed streams and carry the full four-arm, eight-field schema
  (their `legacy` / `agreementWeighted` numerics are unchanged), so
  `ab_report_committed_equivalence_test.dart` now holds every committed
  report to the same full-schema equality with no lenient branch left. The
  guard's hand-written field list is checked against a live `abReport()`
  arm (a field added to the report and not to the list goes red instead of
  silently un-pinning it). A new `experiment_doc_tables_test.dart` parses
  the result tables of the four `EXPERIMENT.md` documents and checks every
  per-arm cell against the committed `.ab.json` — or a live replay for the
  `--coherent-floor=390` arm — at the document's display precision, so a
  regeneration that moves a figure goes red instead of leaving the prose
  stale (two such cells had rotted unnoticed before).

## 2.3.0 - 2026-08-29

### Changed
- **`StabilizationEngine`'s default `StepResponse` is now `coherentShift`
  (#116).** The engine now re-anchors a batch-wide coherent shift by
  default, instead of damping a genuine layout step as jitter;
  `StepResponse.damp` restores the previous (2.2.0 and earlier)
  numerics exactly, and `StepResponse.snap` remains available.
  Evidence: a 17-stream A/B (11 committed + 6 generated push-down/
  push-up variants), re-derived independently from raw `ab-report`
  output over all 17 streams against the `agreementWeighted` (damp)
  baseline — `coherentShift` 14/17 vs `snap` 11/17, with zero
  false-triggered step events on any control stream (`snap`
  false-triggered on 4 of 10). Two blind spots are documented, not
  regressions: a 600 px single-frame slab (no group meets the default
  quorum, so the merge falls through to damp's numbers unchanged) and
  slabs of 50–150 px (inside or near the 3×-height jitter allowance,
  so the cut is null or partial) — tracked as #119. Full table:
  `doc/replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md`'s "Step
  response A/B" section. The #120 review fan-out then hardened
  `_detectCoherentShift`'s clustering (deterministic ordering) and its
  member drift snapshot (frozen at vote time, no longer re-read live
  mid-capture); re-running the 17-stream A/B afterward reproduces the
  identical 14/17 vs 11/17 verdict and every PASS/FAIL cell, with three
  streams' `agreementCoherent` lag numbers re-derived by ≤0.1 px and
  their `.ab.json` regenerated to match — see the EXPERIMENT.md
  "Re-verified post-#120 review" note.

## 2.2.0 - 2026-08-29

### Added
- **Nested re-observation (#112).** An OCR engine's grouping can flip
  between frames: the same paragraph comes back as one paragraph box in
  one capture and as one of its own lines in the next. The line's text
  is a fragment of the paragraph's, so the whole-string match fails
  (17 vs 33 characters scores under 0.70) and the line was admitted as a
  NEW block — the same text tracked twice, drawn as a box inside a box
  until retention expired the paragraph (8 of the 23 residual overlap
  pairs in the 2.1.0 demo). Now, when both the primary and the band path
  miss, a fresh block at least 80 % of whose own area lies inside a
  cached, non-provisional block, and whose text scores ≥ 0.70 windowed
  Levenshtein against that block's text (on ≥ 4 significant characters),
  is a confirmation of that block: observation count up, geometry, text
  and votes untouched — a fragment casts no text vote and pulls no
  position. Fragments are resolved after every full match of the
  capture, so a paragraph reported together with one of its lines merges
  once, never twice. One-directional on purpose: a fresh paragraph over
  an established line stays on the whole-string path. The two bars were
  measured on the committed on-device stream, not chosen: the host only
  has to have been seen once (the grouping flips every frame there), and
  containment is 0.8 because a line box hangs a few px below its
  paragraph box. `MergeResult.isNestedFragment` (additive, default
  false) tells consumers and tools such a confirmation from a position
  merge. This runs on the match path, so retention 0 — the default — is
  affected; every committed `.ab.json` was regenerated (below).
- **`StabilizationEngine.updateBucketSizes` /
  `SpatialBlockIndex.setBucketSizes` (#113).** Set the spatial-index
  bucket sizes directly, with the same re-keying contract as
  `updateViewport`, for consumers whose bucket policy is not the
  viewport formula (the reference producer switches to 2× the median
  block height once it has enough blocks) and for the replay rig.
  `updateBucketSizes` PINS the sizes: a later `updateViewport` keeps them
  (a non-formula policy is not silently reverted by the next rotation)
  until it is called with `resetBucketPolicy: true`;
  `StabilizationEngine.bucketsPinned` reports the state. The index now
  re-keys its own blocks whenever its sizes change (`setBucketSizes`,
  `updateBucketSizes`) — the re-key is no longer a caller obligation.
- **Nested re-observation × grouping contradictions.** A cached block the
  grouping detector (#49) flags as split into two or more of the
  capture's blocks is withheld from nested absorption in that call: the
  contradiction is handed to the consumer and the fragments enter as new
  blocks, as before 2.2.0. On a nested confirmation the engine passes the
  HOST to the merger as `fresh` too, so a merger written to the 2.1
  contract (copy pass-through fields from `fresh`) cannot overwrite the
  paragraph's with the line's. `freeze-report` counts
  `nestedFragmentMerges` beside `totalMerges` and leaves them out of
  `frozenShare`'s denominator (they can never be freezes); one
  `BucketPolicyApplier` now drives both `replay()` and
  `dump_frames.dart`.
- **The replay rig models the consumer's bucket policy (#113).** Capture
  schema v1 gains an additive `meta.bk` = `[bucketW, bucketH]` — the
  buckets the consumer was actually using, written whenever they change
  and carried onto every later `obs`. `replay()`, `ab-report`,
  `freeze-report` and `dump_frames.dart` take `--buckets=auto|formula|
  median`: `auto` (default) applies the stream's `bk` exactly where the
  producer applied it and falls back to the viewport formula for a
  stream without it; `formula` is the 2.1.0 behaviour; `median` emulates
  the reference producer's rule (from the 4th tracked block on, both
  sides = clamp(2 × median tracked-block height, 80, 220)) from the
  stream alone. Reports record `input.bucketPolicy` and the sizes each
  arm applied (`bucketsApplied`).

- **`StepResponse` (#116, candidate fixes for the push-down-reflow lag).**
  The agreement-weighted position model damps every residual as jitter,
  including a genuine layout step — an ad/image finishing load pushes
  every line below it down by a fixed offset in one frame, and the model
  then draws tracked boxes 130-275px above the real text for several
  captures. `StabilizationEngine(stepResponse: ...)` adds two opt-in
  alternatives to the default `StepResponse.damp` (today's behaviour,
  unchanged): `StepResponse.snap` re-anchors a single block outright once
  its residual exceeds `snapThresholdMultiplier` (default 1.5) times the
  block's own agreement scale; `StepResponse.coherentShift` looks for a
  group of matched pairs in the same capture whose displacement agrees
  (within `coherentShiftTolerance`, default 0.5x the smaller block
  height) and, once the group clears `coherentShiftMinBlocks` (default 3)
  and `coherentShiftMinShare` (default 0.5), applies the group's median
  displacement as a batch shift before the normal weighted merge runs.
  Neither is ever applied to a provisional (frozen), nested-fragment, or
  band-fallback-admission merge, and both are a documented no-op under
  `PositionMergeModel.legacy` (which has no residual/scale concept to
  gate on). `MergeResult.stepResponseApplied` (additive, default null)
  tells consumers and replay tooling which `StepResponse`, if any, a
  merge received. **The default (`StepResponse.damp`) reproduces today's
  numerics exactly — no behaviour changes for an engine that does not
  pass `stepResponse`.**

### Changed
- **Reports separate nested confirmations from position merges.**
  `ab-report` arms gain `nestedFragmentMerges`; `mergeCount` counts every
  merge, the displacement buckets and the well-observed pconf stats run
  over `mergeCount − nestedFragmentMerges` only — a confirmation moves
  nothing by construction and would have pulled every mean toward 0
  without a box having moved. All eight committed `.ab.json` were
  regenerated: every displacement mean and count is unchanged; the two
  on-device ML Kit streams count 3 (dwell, 30→33 merges) and 6 (scroll,
  18→24) nested confirmations; the six synthetic streams count none.
- **Bucket-policy delta, measured (#113).** The committed streams predate
  `bk`, so their reports still run on the viewport formula
  (`bucketPolicy: viewportFormula` under `auto`). `--buckets=median` on
  the agreement arm: ML Kit dwell buckets ≈ 103 px instead of 80×88 —
  36 merges, n1-2 8.71→10.18, n6-10 0.19→4.30 over six merges (legacy
  0.79→20.74: the far matches the 2.1.0 note said production geometry
  loses come back at the consumer's real bucket size); ML Kit scroll
  103→171 px, n1-2 5.46→6.24; PaddleOCR scroll 80 px, n1-2 2.12→0.54,
  n3-5 1.08→0.14; Tesseract scroll 102–150 px, n1-2 2.87→1.30, n3-5
  1.08→0.64; the four synthetic dwell streams unchanged. The direction
  depends on the stream, which is why the field exists — a recorder
  that writes `bk` settles it per capture. Each entry carries a dated
  note. A first stream WITH `bk` (ML Kit dwell, 2026-08-29 addendum to
  the on-device entry) applied its own sizes beside the emulation: the
  consumer's sequence and the rig's median emulation agree on only two
  of the sizes applied (the consumer re-derives from a block set the rig
  has already trimmed), and on that still page neither moves a single merge.
- **Dynamic-reflow replay corpus (#93).** Two synthesized Tesseract
  scenarios in `doc/replay/validation/2026-08-dynamic-reflow/` (plus a
  unit-of-identity addendum: the same streams replayed as lines and as
  pre-grouped paragraphs, with `tool/replay/pregroup.dart`) — an image
  slab that pushes every line below it down 300 px, and a font swap that
  re-wraps every line — with the regime each lands in stated and pinned by
  `test/replay/dynamic_reflow_corpus_test.dart`: push-down keeps identity
  for most shifted lines but the position model damps the 300 px step as
  jitter, so tracked positions lag the move by 130–275 px for six-plus
  captures (tracked as #116); re-wrap resets 23 of 30 line identities and
  the new chains track from the next capture, as it should.
- Hero demo GIF re-rendered (captures 0–18, `missedFrameRetention: 2`):
  overlapping tracked-box pairs across the 14 frames drop from 23 to
  15, all 15 the producer's scroll-stamp lag placing different text (or
  a re-split of the same paragraph 23–31 px lower) over an established
  box. The README caption no longer lists the nested line as a visible
  overlap.

## 2.1.0 - 2026-08-29

### Added
- **Cross-frame supersession under `missedFrameRetention`.** A cached
  block that is not matched this capture, but half or more of whose own
  area ONE fresh block of this capture covers, is evicted instead of
  retained. The bar is measured against the CACHED block's area, so a
  single line reported inside a retained paragraph does not evict the
  paragraph; the resolver's per-script NMS threshold applies only where
  it is stricter (short Latin snippets, 0.65) — it is not reused as-is,
  because its CJK value (0.35) would let a sliver evict a CJK block that
  an equal Latin block survives. Blocks from different carousels, and
  viewport-relative vs page-absolute blocks, never supersede each other;
  the candidate search spans the fresh block's whole rect, not just the
  cells around its centre. Before this, the old box stayed in the
  tracked state for the whole retention window and a consumer drawing
  from `spatialIndex.allBlocks` painted it on top of the new one (the
  box-on-box overlaps in the 2.0.0 hero GIF). This is a deliberate trade
  of identity for a clean frame: a wrongly placed fresh block (a lagged
  scroll stamp) evicts a correct retained one, which re-enters as new.
  Retention 0 — the default — is untouched: the rule runs only inside
  the retention branch, so no default-configuration number moves because
  of it; a consumer that runs its own matching through `merge()` never
  reaches it.
- **The replay rig honours the producer viewport.** Capture schema v1
  gains an additive `meta.vp` = `[cssWidth, cssHeight]`; `replay()`,
  `freeze-report`, `ab-report` and `dump_frames.dart` call
  `updateViewport` with it — the viewport-derived bucket geometry a
  consumer configures through `updateViewport` or through
  `SpatialBlockIndex.updateBucketSizes` on an injected index — instead
  of replaying on the engine's 200 px default buckets. `--viewport=WxH`
  overrides (finite positive values only); with neither, the rig warns
  on stderr. Reports record the viewport actually applied under
  `input.viewport`. All eight committed streams carry `vp` and their
  `.ab.json` were regenerated: the dwell-only synthetic streams are
  unchanged; the ML Kit streams lose the cross-neighbourhood matches
  production geometry never offers (dwell 34→30 merges; n6-10 legacy
  20.74→0.79 px); the Tesseract and PaddleOCR scroll streams move by
  0.1–1.6 px per bucket. The synthetic corpora write `vp` from their
  `gen_corpus.py`; the two on-device ML Kit streams were recorded before
  the field existed and carry a value (360×587) read from the recording
  WebView during the capture session and stamped into the header
  afterwards — their entry says so, and the recorder-side writer is
  tracked by the producer's own tracker. The three validation
  entries carry a dated note. `tool/replay/src/replay_session.dart`
  lists what the rig still does not model: a consumer's own matching
  stage, bucket adaptation beyond the viewport formula, `contextualCheck`,
  a consumer-supplied `DriftTracker`.

### Changed
- Hero demo GIF re-rendered from the viewport-honouring dump (captures
  0–18, `missedFrameRetention: 2`): overlapping tracked-box pairs across
  the 14 frames drop from 32 to 23, counted by
  `doc/media/count_overlap_pairs.py` (any two tracked boxes with a
  positive intersection, per frame). Of the 23 that remain, 8 are a
  paragraph box with one of its own lines inside it (a grouping flip the
  rule keeps on purpose) and 14 are the producer's scroll-stamp lag
  placing different text over an established box, which no engine rule
  can tell from real new text.
- `test/long_session_replay_test.dart`: the text-churn modulus is now 23
  (divides the 69-capture pass) and the fixture asserts its own
  periodicity (period two passes, by parity); the flatness detector
  compares same-phase passes by equality. Supersession made the
  population phase-sensitive, which exposed that the old modulus (11)
  drifted ~3 captures per pass.

## 2.0.0 - 2026-08-24

### Breaking
- **`StabilizationEngine.spatialIndex` is now a read-only
  `SpatialIndexView`** (#96). The historical "known seam" — a public
  mutable field whose `add(...)` bypassed the confidence-validation guards
  on `stabilize`/`merge` — is closed. Consumers holding only the engine
  can query, never mutate. Pre-seeding and external eviction go through an
  index YOU construct and inject; the injector owns mutation (and the
  guarded-construction responsibility that comes with it).

  ```diff
  - engine.spatialIndex.add(block);
  + final index = SpatialBlockIndex<MyBlock>();
  + final engine = StabilizationEngine(..., spatialIndex: index);
  + index.add(block);   // mutate YOUR reference; the engine exposes a view
  ```

  Query call sites (`allBlocks`, `blocksInRegion`, `candidates`, bucket
  getters, cell keys) are unchanged.

### Added
- **`ParagraphGrouper.onMergeDecision`** (#92) — optional merge-decision
  diagnostics. Every candidate-vs-paragraph decision and every block drop
  is reported as a `MergeDecisionDiagnostic` carrying the FULL set of
  `MergeRejectReason`s that fired (no short-circuit masking) plus the
  numbers the guards compared (`gap`, `threshold`, `xTolerance`). Null
  (the default) is the zero-cost path; grouping output is identical with
  and without a callback.
- **`SpatialIndexView`** — the read-only query interface implemented by
  `SpatialBlockIndex` (#96).

### Documentation
- Confidence scalars are the API contract; the component signals that
  shape them are internal and refactorable (#98 decision, recorded in
  `types/confidence_types.dart`).

## 1.2.0 - 2026-07-29

### Added
- **`ParagraphGrouper`** — CJK-aware grouping of `OcrBlock`s into
  paragraph-level units, with an extensive oracle test suite.
  Otsu-thresholded gap
  clustering, adaptive height-proportional thresholds (DPR/font-size
  invariant), CJK sentence-ending punctuation awareness (。！？… — strict
  threshold + multi-line block explosion), Tukey IQR height fences (via
  `IqrOutlier`, the same fence utility `BlockClassifier` uses),
  ICDAR aspect-ratio + rune-density noise guards, and inline-peer
  detection so side-by-side UI elements (tag pills, toolbar items) never
  merge. Merge caps are constructor knobs:
  `maxParagraphBlocks` (default 3) and `maxParagraphRunes` (default 200),
  alongside `lineGapThreshold` (10.0) and `lineGapMultiplier` (0.75).
- **`otsusThreshold` / `otsusThresholdWithFallback`** — Otsu's method for
  1-D bimodal gap distributions with small-sample guards (N<5 → median
  heuristic, N<10 → max-gap heuristic) and a 20% inter-class-variance
  floor that rejects unimodal distributions. Accepts input in any order
  (already-sorted input avoids an internal defensive copy). Used by
  `ParagraphGrouper`; exported for standalone gap-clustering use (e.g.
  inline element splitting).

### Design notes (pre-release review hardening)
The pre-release adversarial review confirmed and closed the following in
this same release, so none of them ever shipped:
- The noise guard's char-height baseline (median) and the height fence
  are computed over density-passing blocks only — an OCR artifact cannot
  inflate the very statistics meant to reject it.
- Inline-peer detection is symmetric (candidate left OR right of the
  paragraph) and same-row blocks are tie-broken left-to-right, so
  grouping is deterministic regardless of the order the OCR engine emits
  blocks.
- The 2×-avg-height hard ceiling clamps the Docstrum/Otsu threshold too,
  not just the adaptive fallback — no gap distribution can push the merge
  threshold past it.
- `otsusThreshold` normalizes input ordering instead of silently
  returning wrong thresholds on unsorted input.

## 1.1.0 - 2026-07-24

### Changed
- **`agreementWeighted`'s agreement scale is now per-block** (#75): `3 ×`
  the existing (tracked) block's own height, replacing the region-median
  base. Tolerance becomes proportional to the block's own text size — a
  pooled median gets diluted by small siblings (a caption's height says
  nothing about how much a paragraph may jitter) and needed a cold-region
  16 px default; both defects disappear. Six-capture validation
  (`doc/replay/validation/2026-07-perblock-scale/`): established-chain
  OCR-jitter damping improves ~30-60% with informative confidence
  (0.62 vs 0.35 mean), a fresh physical-rotation reflow capture shows no
  lag regression (within 0.12 px of the old base, identical at depth),
  and every other regime is bit-identical or within noise. On uniform
  streams the two bases coincide, so the #58 3× calibration transfers
  unchanged — no pinned numerics moved. `legacy` is unaffected.
- README: extraction pipelines named as a first-line use case alongside
  rendered overlays.

## 1.0.2 - 2026-07-24

### Docs
- New README "Timing model" section + engine dartdoc stating the latency
  contract explicitly: **render at first sight, refine on re-sight**.
  First-sighting blocks are returned in `stableBlocks` on the call that
  observed them; observation counts and the chain-depth validation bands
  (n1-2 … n11+) are per-*re*-observation refinement stats, never a
  readiness ladder; `wellObservedTexts` fires at 3 observations as a
  caching hint, not a display gate. Previously the "captured at 1-2 Hz"
  framing plus the deep-band tables could read as "stable after ~11
  captures (≈11 s)" — no such warm-up exists.

## 1.0.1 - 2026-07-24

### Fixed
- Anomaly-class diagnostics now reach a wired `debugLogger` in ALL build
  modes (#78). Chatty lines stay debug-only (tree-shaken elsewhere), but
  the events a consumer wires a logger precisely to see — `DriftTracker`'s
  non-finite drift/top input skips (dropped before `dump()` or the
  observation log ever see them) and `BlockClassifierService`'s swallowed
  `positionLookup` callback throw — were invisible outside debug builds.
  Both `debugLogger` docs now state the severity split explicitly.

## 1.0.0 - 2026-07-24

The `agreementWeighted` position-merge model is now the default (#74),
per the #58 three-regime validation verdict and the final consumer gate:
a paired same-stream `tool/replay` ab-report on two current consumer
captures (2026-07-24) showed equal young-block tracking (n1-2 mean
0.96 vs 1.04 px), roughly halved established-block displacement (n3-5
0.44 vs 0.87 px; n6-10 0.28 vs 0.51 px), and informative position
confidence (0.92 on a healthy stream) where `legacy` saturates flat 1.0.

### Changed — BREAKING for consumers tuned against 0.x numerics
- **`StabilizationEngine` default `positionMergeModel` is now
  `agreementWeighted`.** Position confidence is no longer
  additive-saturating: values below 1.0 are the informative norm, so any
  consumer threshold or weighting tuned against 0.x confidence values
  (`OverlapResolver.qualityScore`'s position term, custom cutoffs on
  `positionConfidence`) must be re-validated against a current capture
  (`tool/replay` ab-report is the supported harness).
- **`legacy` remains available and unchanged** — pin
  `StabilizationEngine(positionMergeModel: PositionMergeModel.legacy)`
  to keep the exact 0.x numerics until you re-validate.
- The agreement jitter allowance is calibrated against ML-Kit-shaped
  residuals; consumers feeding a different OCR engine should re-run the
  scale sweep (`doc/replay/validation/2026-07-scale-sweep/`) on their own
  captures. Capture streams can carry per-capture engine attribution
  (`engine` records, `doc/replay/capture_schema.md`) to make such
  stratification possible.

### Fixed
- `RobustStats.madOrFallback` floors its MAD and IQR arms at `minSpread`
  (#72) — the `> 0` adoption sentinels let tiny numeric residue through
  unfloored (divisor-poisoning class; dormant, zero callers today).

## 0.9.0 - 2026-07-23

Validation release for the opt-in `agreementWeighted` model (#58 data
arc): production-capture replay across three stream regimes (stable /
reflow / heavy OCR jitter), two numerics fixes, and the replay tooling
that produced the evidence. Default behavior is unchanged — `legacy`
consumers can upgrade without review.

### Changed (opt-in `agreementWeighted` numerics only)
- **The agreement scale is now a jitter allowance: 3× the regional
  median block height** (#70, #73). The 0.7.0 drift-margin-derived scale
  was removed: median-of-drift is a systematic-offset measure — ~0 under
  symmetric jitter and pure numeric residue on stable streams — so it
  collapsed position confidence on unmoving blocks (1.0 → 0.34, fixed
  by the #70 floor) and was unreachable everywhere else. Separately, the
  sweep showed the un-tuned 1× fallback scale let the confidence-anchored
  merge weight chase deep-chain jitter at 15.8 px/merge (worse than
  legacy). Post-change: deep-chain jitter damps to 3.8 px/merge
  (legacy: 11.8) while confidence stays regime-discriminating
  (~1.0 stable / 0.85 reflow / 0.35 heavy jitter). Sweep evidence:
  `doc/replay/validation/2026-07-scale-sweep/`. Slated to become the
  1.0 default (#74).

### Added
- **Replay rig for consumer-captured observation streams** (#68):
  `dart tool/replay/replay.dart <freeze-report|ab-report|live-report>
  <capture.jsonl>` grades captured streams against the engine — freeze
  semantics (#57), position-model A/B (#58), and consumer-side lifecycle
  views. JSONL schema contract: `doc/replay/capture_schema.md`.

### Decided
- **Provisional-freeze semantics stay evidence-free** (#57, #69, #76):
  frozen captures accrue no observation count, text votes, or position.
  Decision + re-armed re-open triggers are codified at the freeze path;
  the one nonzero-traffic counterfactual observed (noisy-OCR dwell,
  admit-mode replay) was tail magnitude — 1 chain, 3 freezes, 2
  discarded high-confidence votes per ~5-minute session.

## 0.8.0 - 2026-07-22

The package is now **pure Dart** (#59): no Flutter SDK dependency, usable
in server-side Dart (PDF and camera OCR pipelines) and CLI tools as well
as Flutter apps. Same behavior, new geometry types — read the migration
notes below.

### Breaking
- **Geometry types moved off `dart:ui`.** `Rect`, `Offset`, and `Size`
  are now package-owned value types exported from the barrel
  (`lib/src/types/geometry.dart`), member-compatible with their
  `dart:ui` counterparts and matching their semantics exactly (strict
  `overlaps` on edge-touching rects, negative-size `intersect` for
  disjoint rects, `Rect.lerp` incl. null-scaling branches).
  Migration:
  - Code constructing package inputs: change the import — call sites
    are unchanged.
  - Flutter render boundary: convert with
    `ui.Rect.fromLTRB(r.left, r.top, r.right, r.bottom)` and the
    reverse (copy-paste extensions in the README's Platform Support
    section).
- **Debug logging is opt-in.** `BlockClassifierService` and
  `DriftTracker` take a `debugLogger: void Function(String)?`
  constructor parameter (default null = silent) instead of calling
  Flutter's `debugPrint`. Pass `debugLogger: print` to restore the
  previous output.
- **pubspec surface**: the `flutter` SDK dependency and
  `flutter: '>=3.19.0'` environment constraint are gone; dev-deps are
  `test` + `lints` (replacing `flutter_test` + `flutter_lints` — the
  effective lint rule set is unchanged, `flutter_lints` layered
  Flutter-widget rules this package never triggered).

### Internal
- CI runs on `dart` natively: latest stable plus a Dart 3.3 floor leg
  (replacing the Flutter 3.19 floor leg — same floor, expressed in the
  SDK that now matters). Coverage artifact retained.
- All 520 tests pass under plain `dart test` on both legs; zero Flutter
  packages in dependency resolution.

## 0.7.0 - 2026-07-22

Additive release: the opt-in `agreementWeighted` position-merge
prototype (#58). Default behavior is unchanged — `^0.6.0` consumers can
upgrade without review.

### Added
- `PositionMergeModel` enum and
  `StabilizationEngine(positionMergeModel: ...)` (#58). The default
  `legacy` preserves 0.x numerics exactly. The opt-in
  `agreementWeighted` prototype addresses the audit §1.7 findings:
  - **Merge weight decays with observation count**
    (`fresh / (existing·n + fresh)`): long-observed blocks become
    positionally sticky — a 6-times-confirmed block barely moves for a
    single 12px outlier — while young blocks still adapt quickly.
  - **Merged confidence is a running mean of positional agreement**
    (residual vs the region's drift margin, median-block-height scaled
    when no margin exists) instead of the saturating sum: disagreeing
    observations now reduce confidence, making `qualityScore`'s
    position term informative again for well-observed blocks.
  Rollout mirrors the band-fallback pattern: ship on `legacy`, A/B
  `agreementWeighted` against your captures, adopt when the numbers
  hold. Slated to become the 1.0 default pending that validation.

## 0.6.1 - 2026-07-21

Performance release finishing the remaining #55 items. No API changes.

### Performance
- Intra-batch NMS now resolves overlaps against a per-batch spatial
  grid instead of linearly scanning the whole output per fresh block —
  ~O(n²)·(drift-margin per pair) becomes O(cells) (#55). Behavioral
  nuance: the grid applies the same 3×3-neighborhood locality contract
  the inter-capture matching path already uses, so two blocks whose
  centers sit more than one bucket apart are no longer compared — only
  observable for blocks wider than ~2 buckets, which the spatial index
  documented as out-of-contract in 0.5.1.
- `stabilize()` reuses that batch grid for grouping-contradiction
  detection instead of building a second throwaway index every capture
  (#55). The public `detectGroupingContradictions` now sizes its
  temporary index's buckets from the engine's spatial index rather than
  defaults.
- `DriftTracker.medianDriftForKey` / `medianBlockHeightForKey` /
  `driftMarginForKey` cache per-key results, invalidated on
  `addObservation` and every clearing path — previously each call
  copied and sorted up to 20 samples, several times per block per
  capture (#55).

### Internal
- CI uploads the lcov coverage report as a build artifact from the
  latest-stable leg (#60; badge/coverage-service wiring still open
  there — needs a repo token).
- `flutter_lints` constraint comment updated for the Dependabot-widened
  `>=4.0.0 <7.0.0` range (#63): 4.x resolves on the Dart 3.3 floor,
  newer lines elsewhere.
- Test count: 513.

## 0.6.0 - 2026-07-20

Audit-driven feature-and-fix release implementing the 0.6.0 roadmap
(#46–#56). Pre-1.0, behavioral changes take a minor bump: review the
Breaking section before upgrading from 0.5.x.

### Breaking
- **`CssSubmapMembership.spaceKeyFor` maps viewport-relative (weight 40)
  and nested IC+carousel (weight 30) blocks to `SpaceKey.unknown()`**
  instead of `SpaceKey.normal(...)` (#48). Drift observation and
  correction are now symmetric: a `position:fixed` header no longer
  receives the page-scroll submap's median correction it never
  contributed to. Consumers relying on VR blocks being drift-corrected
  (unlikely — the correction was categorically wrong) must supply a
  custom `SubmapMembership`.
- **`ContradictionEvent`'s constructor is no longer `const` and throws
  `ArgumentError`** when `evidence` has fewer than 2 entries (#51) —
  the storage-invariant policy (throw, not assert) now applies here
  too. Migration: drop `const` from any `ContradictionEvent`
  constructions (engine-produced events are unaffected).
- **Contradiction detectors skip the viewport-relative boundary** (#49):
  `detectGroupingContradictions` ignores VR cached blocks and
  `detectSplittingContradictions` ignores VR fresh blocks. Near scroll
  offset 0, healthy sticky headers were reported as "subdivided" by
  unrelated normal blocks and evicted by consumers.
- **Batch-NMS key lifecycle** (#50): dedup keys register only for
  blocks that survive intra-batch NMS, and an evicted block's key
  retires with it. Dropped blocks no longer fuzzy-suppress later
  same-neighborhood blocks. Eviction lookup is identity-based —
  Equatable-style consumer blocks can no longer cause the wrong
  value-equal element to be replaced.
- **New direct dependency `meta: ^1.11.0`**; dev-dependency
  `flutter_lints` moved `^5.0.0` → `^4.0.0` because 5.x requires Dart
  3.5 and never actually resolved on this package's declared `^3.3.0`
  floor — caught by the new CI floor leg (#56).

### Added
- `StabilizationEngine.missedFrameRetention` (#46): opt-in retention
  window keeping unmatched cached blocks matchable for N further
  `stabilize()` calls, so a single OCR miss (glare, occlusion) no
  longer resets a block's accumulated identity. Default `0` preserves
  0.5.x behavior exactly; retained blocks are never part of
  `stableBlocks`. The `stabilize()` index-ownership docs now tell one
  consistent story.
- `StabilizationEngine.updateViewport(...)` (#52): single validated
  entry point that recomputes the spatial index's adaptive buckets and
  adopts the same dimensions for dedup keys. The `bucketWidth` /
  `bucketHeight` / `scale` setters now throw `ArgumentError` on
  non-finite or non-positive values.
- `DriftTracker.propagationCountFor(spaceKey)` — public reader for the
  counts written via `recordPropagation` (#53).
- `TextVote` implements `==` / `hashCode` / `toString`, matching the
  package's other value types (#53).
- `BandFallbackStatsInternal` is annotated `@internal` — the analyzer
  now flags downcast-mutation from outside the package (#53).

### Deprecated
- `DriftTracker.spaceKeys` — use the identical `observedKeys`; removal
  planned for 1.0 (#53).

### Fixed
- `DriftTracker.clearKey` / `clearSpatialRegion` now also clear the
  matching propagation counts, which previously leaked for the rest of
  the session (#55).

### Performance
- Text-similarity calls (`isTextSimilar`, `isTextSimilarWithScores`,
  `computeTextSimilarity`) extract each string's significant-char list
  once and feed both metric cores — previously up to 6 extractions per
  comparison (#55).

### Internal
- CI matrix now tests the declared minimum floor (Flutter 3.19.6)
  alongside latest stable (#56); Dependabot covers GitHub Actions and
  pub (#60).
- Band admission ordering caveat and `String.hashCode` key-stability
  caveat documented (#53).
- Test backfill (#54): first dedicated suites for `RobustStats`,
  `IqrOutlier`, `OverlapResolver`, `BlockKeyGenerator`, `AbsoluteRect`,
  hierarchy/scroll value types, `CssSubmapMembership`, and `TextVote`;
  real mixed-confidence coverage for `computeTextConfidence`;
  regression tests for every fix above. Test count: 504 (was 297),
  verified on both stable and Flutter 3.19.6.

## 0.5.1 - 2026-07-20

Bug-fix release driven by the v0.5.0 package audit
(`doc/audit/2026-07-20-package-audit.md` in the repository). No API
changes — `^0.5.0` consumers resolve `0.5.1` automatically.

### Fixed
- `SpatialBlockIndex.candidates()` now deduplicates yielded blocks by
  object identity, matching `allBlocks` / `blocksInRegion`. Previously a
  dual-indexed IC block reachable from both its page-absolute cell and
  its `ic:` cell was yielded twice to an IC query — running the full
  Levenshtein comparison twice per duplicate and double-ticking the
  `BandFallbackStats` funnel counters (`candidatesConsidered`,
  `rejectedSpatial`, `rejectedTextBand`, and in observeOnly
  `bandMatchesIdentified`) that consumers are told to read before
  flipping to `admit`.
- `StabilizationEngine` primary matching no longer drops a candidate
  admitted purely through the Jaccard arm with a Levenshtein score of
  0.0 (full character reordering, e.g. a two-character OCR segment swap
  like `北京` → `京北`). The best-candidate scan seeded its comparison
  at 0.0 with a strict `>`, so such a match never registered and the
  observation spawned a duplicate block instead of merging.
- `OcrBlock` now stores a NaN `confidence` as `null` (unavailable). The
  documented clamp could not contain NaN — in IEEE-754,
  `nan.clamp(0.0, 1.0)` returns NaN — so NaN leaked to any consumer
  reading `confidence` directly. Infinite values still clamp to the
  range bounds.
- Unified the package's two divergent CJK-ideograph definitions into one
  shared predicate (`lib/src/internal/cjk_ideographs.dart`). The dedup
  utilities (`cjkOnly`, `cjkFraction`, significant-char extraction)
  omitted CJK Extension B (U+20000–U+2A6DF) while the confidence
  heuristic included it, so text consisting only of Extension-B
  ideographs produced an empty significant-char list and could never
  text-dedup. `TextDedupUtils` and `isCjkIdeograph` now agree.

### Documentation
- `StabilizationEngine.stabilize` documents the index-rebuild
  limitation: blocks not re-observed in a capture leave the spatial
  index and re-enter as new; app-inserted blocks are dropped at the next
  call. The cache-merge redesign is tracked for 0.6.0.
- `classifyGroups` documents its silent fallbacks (degenerate
  `imageToLayoutScale` → identity CSS-per-px; near-singular container
  transform → untransformed rect) and the actual `positionLookup` throw
  contract (caught, neutral stability — previously documented as "must
  not throw").
- `SpatialBlockIndex.blocksInRegion` documents the center-cell +
  1-cell-margin lookup limit for oversized blocks; `remove()` documents
  that cell keys are recomputed from the current rect, so removal after
  mutation silently no-ops.
- `TextDedupUtils.containmentRatio` documents the 5,000-rune LCS
  truncation on the public API (was only on the private helper) and
  drops a stale internal-caller claim.
- `RobustStats.madOrFallback` scopes its "never zero or negative"
  guarantee to positive `minSpread`.
- `MergeResult.observationCount` documents the provisional-freeze
  exception (count passes through unchanged while frozen).

### Internal
- `.pubignore` added: internal process docs (`doc/superpowers/`,
  `doc/audit/`) no longer ship in the published package archive.
- Full package audit report at `doc/audit/2026-07-20-package-audit.md`
  (repository only).
- First dedicated test file for `TextDedupUtils`
  (`test/text_dedup_utils_test.dart`). Test count: 297 (was 277).

## 0.5.0 - 2026-05-24

Quality-polish release. Additive public-API additions plus a latent
engine bug fix in the band-fallback counter accounting. No breaking
changes from 0.4.x — `^0.5.0` is a safe upgrade.

### Added
- `BandPredicateException` — typed wrapper class for throws raised by a
  consumer-supplied `BandSpatialPredicate`. The engine catches the
  predicate's error inside `_findMatch` and rewraps it as
  `BandPredicateException(cause, predicateStackTrace)`. Predicate
  failures now surface with a typed shape; no silent swallow. Exposes
  `cause`, `predicateStackTrace`, `message`, and an asserting ctor that
  rejects double-wrapping (#35).
- `BandFallbackStats.rejectedTextBand` counter ticks at the
  text-band-miss site inside `_findMatch`. Makes the band funnel
  decomposable: `rejectedCandidateFloor + rejectedSpatial +
  rejectedTextBand + bandMatchesIdentified == candidatesConsidered`,
  invariant to admit-mode early-exit (#34).
- Library-level dartdoc in `lib/ocr_stabilizer.dart` now enumerates the
  headline types (`StabilizationEngine`, `BandFallbackConfig`,
  `BandFallbackStats`, `BandPredicateException`, block hierarchy,
  confidence types) plus the recommended adoption flow (off →
  observeOnly → admit) (#35).
- Internal `assertConfidenceRange(field, raw, {prefix})` utility at
  `lib/src/internal/confidence_validation.dart` centralises the
  `[0.0, 1.0]` finite-double predicate. Adopted at five sites:
  `DefaultTrackedBlock` ctor, `MergeResult` ctor,
  `StabilizationEngine._assertValidConfidence` (called by `stabilize`
  and `merge`), `PositionConfidence.from`, `TextConfidence.from`. Future
  tightening happens in one place (#31).

### Changed
- `BandFallbackStats.matchesAdmitted` is now incremented at the
  resolution-time site (where `_findMatch` actually returns a band
  match), not at scan-time. Before this release, the counter ticked as
  soon as a candidate was locked as `bandAdmitted` — so when a later
  primary candidate in the same scan superseded it, the counter
  overcounted and disagreed with the function's return value. New
  semantics: `matchesAdmitted` is exactly "band matches returned by
  `_findMatch`", and the documented invariant
  `matchesAdmitted <= bandMatchesIdentified` is strengthened by the
  precedence rule "primary always wins, even if a band candidate was
  locked first" (#34).
- `MergeResult` ctor's confidence-range error message wording upgraded
  from `'must be in [0.0, 1.0]'` to
  `'must be a finite double in [0.0, 1.0]'` to match the message at the
  engine entry guard and `DefaultTrackedBlock` ctor — a consumer
  catching `ArgumentError` no longer sees two slightly different
  stories about the same invariant (#31).

### Fixed
- Library dartdoc no longer references a non-existent
  `stabilize(fresh, captureRect)` signature — the actual signature is
  `stabilize(List<T> freshBlocks)`. Caught by the comment-analyzer
  pass on PR #42 (#35).
- Privacy scrub: removed 17 references to the downstream consumer's
  internal project name / file:line paths from spec/plan docs and one
  source comment (#33).

### Internal
- New CI job: pana scoring on ubuntu-latest with
  `--exit-code-threshold 0` pinned to pana `0.23.12`. Authoritative
  pre-publish score check — Windows local pana hits 150/160 due to
  upstream `dart-lang/dartdoc` issue #4180 (CRLF offsets in Flutter
  SDK `@docImport` files), but Linux scoring is 160/160 (#36).
- Renamed `docs/` → `doc/` for the Pub layout-convention hint (#37).
- Test count: 277 (was 270 in v0.4.0).

## 0.4.0 - 2026-05-23

### Added
- `BandFallbackMode` enum (`off` | `observeOnly` | `admit`) configures the
  band-relaxed fallback path inside `StabilizationEngine._findMatch`.
  Default is `off`; switch to `observeOnly` to read `BandFallbackStats`
  before committing to `admit`. Design and default provenance: (#20).
- `BandFallbackConfig` value type wraps the band thresholds, candidate
  observation floor, provisional-capture grant, and spatial confirmation
  predicate. Constructor `assert`s on out-of-range values (preserves
  const-constructibility); engine constructor throws `ArgumentError` for
  release-build safety. Primary-path floors (Lev 0.70 / Jaccard 0.80) are
  engine-owned, not configurable through this type (#20).
- `BandFallbackStats` exposes per-capture counters: `primaryMatchesAdmitted`,
  `primaryMatchesRejected`, `candidatesConsidered`, `rejectedCandidateFloor`,
  `rejectedSpatial`, `bandMatchesIdentified`, `matchesAdmitted`. Read-only
  public surface; engine mutates via a same-library `Internal` subclass.
  Reset via `reset()`; the engine never resets it automatically (#20).
- `BandSpatialPredicate` typedef mirrors `ContextualInvalidationCheck` —
  `bool Function(TrackedBlock fresh, TrackedBlock candidate)`. When
  `BandFallbackConfig.spatialConfirm` is `null`, the engine substitutes
  a drift-aware `overlapRatio >= 0.80` closure (#20).
- `StabilizationEngine` constructor gains a `bandFallback:
  BandFallbackConfig` parameter (defaults to `mode: off` — backward
  compatible) and a `bandStats` getter returning the read-only stats view
  (#20).

### Changed
- **Breaking:** `StabilizationEngine.stabilize()` and
  `StabilizationEngine.merge()` now throw `ArgumentError` if any
  observation's `positionConfidence.raw` or `textConfidence.raw` is
  `NaN` or outside `[0.0, 1.0]`. Catches any `TrackedBlock` implementor
  at the engine entry, closing the documented unchecked-`const`-Confidence
  gap (#27).
- **Breaking:** `DefaultTrackedBlock` constructor throws `ArgumentError`
  when `positionConfidence.raw` or `textConfidence.raw` is `NaN` or
  outside `[0.0, 1.0]`. Early-fail at construction with a cleaner stack
  trace than the engine-entry guard would produce. Consumers going through
  `PositionConfidence.from()` / `TextConfidence.from()` (validated since
  #19) are unaffected (#27).
- `StabilizationEngine._findMatch` primary path now uses
  `TextDedupUtils.isTextSimilarWithScores` (Lev OR Jaccard) instead of
  `normalizedLevenshtein` alone. Floors are unchanged (Lev 0.70 /
  Jaccard 0.80); the metric set widens — character-reordered text with
  the same significant-character set now matches on the primary path
  where it previously fell through (#20).

### Fixed
- `OverlapResolver.qualityScore` no longer silently propagates `NaN` into
  the NMS comparison. NaN reaching `qualityScore` is now a debug-time
  `AssertionError`; release builds skip the check (defended by engine
  entry validation, above) (#27).
- `StabilizationEngine` constructor now rejects `NaN` and `±Infinity` for
  `BandFallbackConfig.bandLevenshteinFloor` and `bandJaccardFloor` in
  release builds. The bare range check (`value < 0 || value >= floor`)
  evaluated `false` for `NaN` under IEEE 754 and let it bypass the
  defense; the `assert` in the const ctor catches it in debug only. Now
  short-circuits on `!isFinite` before the range check (#20).

## 0.3.0

A breaking release bundling four API changes. Pre-1.0, breaking changes
take a minor version bump.

### Breaking
- `ObservableBlock` no longer declares `exclusionHitCount`, and
  `DefaultTrackedBlock` no longer carries it. The field was inert
  engine-side — never read or written by merge, dedup, drift correction,
  or the spatial index. It is consumer-managed state and does not belong
  on the package's block contract. Migration: a consumer with
  `@override int get exclusionHitCount;` on its own block class removes the
  `@override` annotation — the field stays, it is just no longer an
  interface member. Consumers that do not need the field drop it entirely.
  (#23)
- `PositionConfidence.from` / `TextConfidence.from` now throw `ArgumentError`
  on out-of-range **or NaN** input. Previously they validated with `assert`
  only, which is stripped in release builds — an invalid confidence passed
  silently in production. Migration: catch `ArgumentError` instead of
  `AssertionError`; any code that relied on release-mode silent acceptance
  of an out-of-range value now gets a thrown exception. The primary
  `const PositionConfidence(double)` / `const TextConfidence(double)`
  constructor stays public and unchecked — it is the only `const`-capable
  path, kept for `const` literal sentinels. (#26)

### Changed
- `StabilizationEngine.stabilize()` now rebuilds `spatialIndex` internally
  from its returned `stableBlocks` before returning. The old caller
  contract (call `spatialIndex.rebuild(result.stableBlocks)` after every
  `stabilize()`) is retired, along with the debug-mode staleness guard.
  Callers can drop the post-`stabilize()` rebuild call — a redundant
  rebuild is harmless, so this is non-breaking. (#24)
- `MergeResult`'s confidence boundary checks now also reject NaN (NaN fails
  both `< 0` and `> 1.0`, so it previously slipped through). (#26)

### Added
- `StabilizationEngine.resetDriftPropagation()` — clears the engine's
  regional-drift baseline so a consumer can reset propagation state on a
  session boundary (page navigation, context reset) without a stale
  baseline triggering a spurious correction. (#25)

## 0.2.2

### Added
- CI: GitHub Actions workflow running `flutter analyze` + `flutter test` on
  push and PR (#15).
- `CONTRIBUTING.md` documenting dev setup, conventions, and release flow (#16).

## 0.2.1

Docs + metadata polish. No API change. First pub.dev-shipped release of the
v0.2.x line.

### Documentation
- README: install snippet updated to `^0.2.1` with a breaking-change pointer
  back to the 0.2.0 typed-confidence migration. (#14)
- README: `TrackedBlock<T>` example now lists all 14 getters (was missing
  `innerScrollerTop`, `sourceQuality`) with a follow-up note pointing
  integrators at `DefaultTrackedBlock<T>` or `ObservableBlock<T>` as
  appropriate. (#14)
- README: API Reference tables refreshed for v0.2.x — corrected getter
  count, generic on `ObservableBlock<T>`, documented `DefaultTrackedBlock<T>`,
  `PositionConfidence`, `TextConfidence`, plus the previously-undocumented
  exports (`StabilizationEngine`, `BlockClassifierService`, `OverlapResolver`,
  `BlockKeyGenerator`, `MergeResult`, `StabilizationResult`,
  `ClassificationResult`, `TextVote`, `IqrOutlier`, `TextDedupUtils`). (#14)

### Metadata
- `pubspec.yaml` gains `homepage:` and pub.dev `topics:` (`ocr`, `overlay`,
  `tracking`, `slam`, `flutter`). (#14)
- `.gitignore` excludes local agentic-scaffolding directory (`.ultra/`). (#14)

## 0.2.0

### Breaking
- `TrackedBlock.positionConfidence` and `textConfidence` now return typed
  `PositionConfidence` / `TextConfidence` extension types (over `double`)
  instead of raw `double`. Consumers implementing `TrackedBlock` must
  update the getter signatures. The migration path:
  ```diff
  - final double positionConfidence;
  - final double textConfidence;
  + final PositionConfidence positionConfidence;
  + final TextConfidence textConfidence;
  ```
  Producer sites wrap raw doubles via `.from(value)` (range-asserted),
  or use the `.groundTruth` sentinel (= 1.0) for deterministic origins.
  Extension types are zero-cost at runtime.

### Added
- `PositionConfidence` / `TextConfidence` extension types in
  `lib/src/types/confidence_types.dart`. Range `[0.0, 1.0]` enforced via
  `.from()` factory; `.groundTruth` static const sentinel for DOM/deterministic
  origins. (#10)
- `DefaultTrackedBlock<T>` — concrete reference implementation of
  `ObservableBlock<T>` with documented defaults for every required field
  (notably `carouselIdVotes: {-1: 1}` — the engine's phantom-vote sentinel).
  Includes `copyWith` and `applyMerge(MergeResult)` convenience. (#5)
- `SpatialBlockIndex.isEmpty` — O(1) accessor (was: `allBlocks.isEmpty`
  allocated a `Set.identity()` per call). (#2)
- `StabilizationEngine.stabilize()` debug-mode staleness warning when
  the spatial index appears empty after a non-empty previous call, plus
  prominent "Caller contract" docstring documenting the consumer's
  rebuild responsibility. (#2)
- `MergeResult` now throws `ArgumentError` (not just `assert`) when
  invariants are violated, including the confidence-range bypass via
  the unvalidated `PositionConfidence(double)` primary constructor.
  Asserts strip in release; this guards engine output that flows into
  consumer caches. (#10)

### Changed
- SDK constraint relaxed from `sdk: ^3.8.1` to `sdk: ^3.3.0` (extension
  types shipped in Dart 3.3 — the only modern feature this package uses).
  `flutter` constraint pinned to `>=3.19.0` (the Flutter that bundled
  Dart 3.3). `flutter_lints` dev-dep pinned to `^5.0.0` to keep dev-deps
  SDK floor consistent with the package SDK floor. (#3)
- `DriftTracker` rolling windows switched from `List` (O(N) `removeAt(0)`)
  to `dart:collection`'s `Queue` (O(1) `removeFirst`). Type now signals
  FIFO ring-buffer intent at the declaration site. (#4)
- `DefaultTrackedBlock` constructor throws `ArgumentError` (not just
  asserts) when the `containerId` / `isInnerScrollerChild` invariant
  is violated — the reference implementation is state-owning, asserts
  strip in release. (#5)

### Fixed
- `SpaceKey.regionIndex` returns 0 as a safe fallback instead of throwing
  `FormatException` on malformed keys (forward-compat for externally-
  constructed or future-format-extension keys). (#1)

### Internal
- New test files: `test/space_key_test.dart`, `test/confidence_types_test.dart`,
  `test/merge_result_test.dart`, `test/default_tracked_block_test.dart`.
  Test count: 207 (was 180 in v0.1.0).

## 0.1.0

Initial release.

### Core
- `StabilizationEngine` — SAR merge, intra-batch dedup, contradiction detection
- `DriftTracker` — regional drift correction with submap isolation
- `SpatialBlockIndex` — grid-cell spatial index for O(cells) overlap queries
- `OverlapResolver` — spatial NMS with language-aware thresholds
- `BlockKeyGenerator` — position+text dedup keys with fuzzy neighbor matching
- `BlockClassifierService` — OCR group classification (fixed/sticky/carousel/IC/normal)

### Types
- `TrackedBlock<T>` / `ObservableBlock<P>` — block identity interfaces
- `AbsoluteRect` — zero-cost coordinate-space safety (extension type)
- `SpaceKey`, `ContainerId`, `ScrollContext`, `StickyFallback` — value types

### Utilities
- `TextDedupUtils` — Levenshtein, Jaccard, CJK detection
- `RobustStats` — median, MAD, IQR
- `IqrOutlier` — Tukey fence outlier detection
