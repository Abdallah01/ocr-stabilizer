# Dynamic reflow (non-rotation) — synthetic Tesseract corpus, 2026-08-29 (#93)

The scale sweep's reflow captures are rotations: the whole layout
transforms at once, deterministically. This entry covers the other family
— the layout shifting while the viewer does nothing — with two synthesized
scenarios, one per mechanism from the issue that can be produced as a pure
page change:

| scenario | event (rendered from capture 7 of 12) | what changes | what does not |
|---|---|---|---|
| `pushdown` | a 300 px image slab finishes loading after paragraph 10 (page y 1692, inside the 800–3000 px dwell viewport) | every line below it moves down by exactly 300 px | every line's text; every line above the slab |
| `rewrap` | a web font swaps in: the same paragraphs re-wrap at 22 instead of 26 characters per line | every line box AND every line's text (103 → 121 lines) | the paragraph text |

## Method

`gen_corpus.py` (this directory) is the Tesseract matrix entry's pipeline
with a page-state switch: a synthetic CJK prose page composed from a small
common-hanzi vocabulary (no copyrighted text), 1080 px wide, Microsoft
YaHei 36 px; a 1080×2200 viewport dwelling at scrollY 800 for all twelve
captures; mild perturbation per frame (subpixel shift ≤ 0.3 px, JPEG 90,
±2 % brightness); Tesseract 5.4.0 / chi_sim (tessdata_fast) / PSM 6 per
frame; line-level blocks serialized as capture schema v1 JSONL. The reflow
is applied to the RENDERED PAGE from capture 7 on, so the boxes on both
sides of the event carry real engine noise; the +300 px of `pushdown` is
exact by construction and pinned by
`test/replay/dynamic_reflow_corpus_test.dart`. The rewrap width is 22, not
24: at 24 no paragraph crossed a line-count boundary, so boxes changed
width but nothing moved — the font swap worth measuring is the one that
costs long paragraphs a wrapped line.

Reports: `pushdown.ab.json` and `rewrap.ab.json` (`ab-report`, both
position models, the stream's own `meta.vp`); per-capture identity from
`dump_frames.dart` (agreement-weighted model, retention 0), where a stable
block with observation count ≥ 2 kept an identity and one with count 1 was
admitted as new.

## Result

### `pushdown` — identity retained, position NOT updated

| capture | raw | matched / new | below the slab: matched / new | mean lag of retained shifted lines (raw top − tracked top) |
|---|---|---|---|---|
| 6 (before) | 30 | 28 / 2 | 18 / 0 | 1.6 px |
| 7 (the move) | 26 | 20 / 6 | 9 / 5 | **274.4 px** |
| 8 | 26 | 24 / 2 | 14 / 0 | 138.8 px |
| 9 | 26 | 24 / 2 | 14 / 0 | 160.2 px |
| 10 | 26 | 21 / 2 | 11 / 0 | 155.4 px |
| 11 | 26 | 20 / 3 | 10 / 1 | 153.4 px |
| 12 | 26 | 21 / 3 | 11 / 1 | 132.5 px |

(26 raw lines from capture 7 on: the slab pushes the last four lines out
of the viewport.) **Identity:** 9 of the 14 shifted lines match their
pre-move blocks on the reflow frame through the primary text match (the
band-relaxed fallback is off in both replay tools and admitted nothing);
24 of the 26 line texts on capture 7 existed on capture 6 and 20 of them
matched. The five
resets re-enter as new chains and track from capture 8. **Position:** the
agreement-weighted model treats the 300 px step as jitter — the tracked top
lags by 274 px on the move and is still 130–160 px behind five captures
later. `ab-report` says the same in per-merge terms: displacement in the
n6-10 band is 9.0 px per merge (agreement) against 21.9 (legacy) — both
arms converge slowly, the agreement arm slowest, exactly the damping that
is right for jitter and wrong for a coherent move.

**Regime: "same content" recognised, "new layout" not.** A consumer's
overlay would draw ~150 px above the text for several seconds after an ad
or image finishes loading. Tracked as #116 (a per-batch coherent-shift
estimate, or a re-anchor when a match's displacement is far outside the
jitter allowance — not decided here).

### `rewrap` — identity reset, as it should be

| capture | raw | matched / new |
|---|---|---|
| 6 (before) | 30 | 28 / 2 |
| 7 (the swap) | 30 | **7 / 23** |
| 8 | 30 | 29 / 1 |
| 12 | 30 | 26 / 2 |

23 of the 30 lines are admitted as new blocks on the swap frame: their
line text changed (different character spans), so no text match is
possible and the engine correctly starts new chains. The 7 retained are
lines whose 22-character text is a prefix of the old 26-character line
(similarity ≥ 0.70). From capture 8 the new chains track normally
(displacement n1-2 4.0 px agreement vs 4.6 legacy; n3-5 0.72 vs 1.58).

**Regime: reset.** The expected outcome for a re-wrap at line level —
nothing snaps, nothing stale.

## Expected behaviour, stated

| mechanism | identity | position | engine today |
|---|---|---|---|
| push-down (coherent subtree translation) | retain | move with the content | retains 9 of 14, position lags (#116) |
| re-wrap (font swap) | reset — the line texts differ | new chains | resets 23 of 30; 7 prefix matches retained |

## Boundary of what this proves

One synthetic page, one engine (Tesseract), one viewport, one event size
per mechanism (300 px; 26 → 22 characters). Blocks are lines: a
paragraph-level consumer would see the re-wrap as "same paragraph text,
new box" and could retain identity — that is the consumer's grouping, not
this engine's matching. Not covered from the issue's list: an expandable
section (a push-down where a TEXT block appears, not a slab — a mix of the
two regimes above) and a sticky header offsetting the visual viewport (a
scroll-offset change, not a layout change; the on-device entry's `sc`
field is that path).

## Unit of identity: lines vs pre-grouped paragraphs (2026-08-29 addendum)

The engine tracks whatever unit a consumer feeds it (issue #101: grouping is
the consumer's, downstream concern). A consumer that groups BEFORE tracking
makes the grouped unit the identity. This addendum replays the same two
streams under both choices: **lines** = the streams as recorded (Tesseract
line boxes, ~30 per capture); **paragraphs** = the same captures pre-grouped
per capture with `ParagraphGrouper` at one consumer's translation-sized knobs
(gap 10 px / ×0.75, `maxParagraphBlocks` 3, `maxParagraphRunes` 200, member
texts joined with a space), ~14 units per capture. Tool:
`tool/replay/pregroup.dart` (it prints the knobs it applied; a bad flag is
an error, not a fallback); reports: `pushdown.grouped.ab.json`,
`rewrap.grouped.ab.json` (agreement-weighted arm quoted; retention 0).

A grouped unit is a fresh observation carrying only rect, text, the two
confidences and the scroll context. Engine-side per-block fields a recorder
may emit (`cid`, `sf`, `srcQ`, `obsN`, `prov`, `cvotes`, ...) are dropped
and reset to defaults in the grouped arm; the tool reports on stderr when a
stream carries any. Both corpora here carry none, so the two arms differ in
the unit and nothing else.

**Identity on UNCHANGED captures** (units matched to an existing block /
units observed; nested-fragment confirmations count as matches — the
fragment found its block — and make up 3 of the 10 on pushdown capture 6
and 1 of the 7 on rewrap capture 12):

| unit | pushdown caps 2–6 | rewrap caps 8–12 |
|---|---|---|
| lines | 28/30, 29/30, 28/30, 28/30, 28/30 | 29/30, 28/30, 28/31, 27/30, 26/30 |
| paragraphs | 13/14, 13/14, 13/14, **7/11**, **10/14** | 11/11, 11/11, 11/11, **6/11**, **7/11** |

Both rows are pinned by `test/replay/dynamic_reflow_corpus_test.dart`
(pushdown: lines keep at least 9 in 10 on every static capture, paragraphs
drop to three quarters or less on at least one; rewrap: lines keep at least
85 in 100, paragraphs drop to 65 in 100 or less).

The paragraph losses are cascades. On pushdown capture 5 the OCR mis-reads
ten lines slightly and returns a few two-line boxes (72–76 px tall). A line
unit loses only itself, and the text match absorbs small edits; a three-line
chunk shifts its boundary for the rest of the paragraph, so every following
unit changes text and box (14 → 11 units, 9 texts gone, 6 new). Rewrap
captures 10 → 11 show the same shape on a static page (7 of 11 units
re-chunked).

**At the reflow (capture 7):** pushdown — lines keep 20 of 26 (9 of 14 below
the slab), paragraphs keep 8 of 10 (4 of 5 below, 4 of 5 above); rewrap —
lines reset 23 of 30 and recover fully on the next capture (29 / 1),
paragraphs reset 6 of 11, recover fully for three captures, then lose 5 and
4 more on the static captures 11 and 12.

**Merges per frame:** lines 22.6 (pushdown) / 24.0 (rewrap); paragraphs 8.4 /
9.2 — about 2.7× the absolute work with lines, at 0.80 vs 0.72–0.76 merges
per observation. Displacement per merge is the same order either way (n6-10
band 9.0 vs 10.3 px pushdown, 16.3 vs 11.8 rewrap). The pushdown position lag
(#116) is erratic under paragraph units (1–4 survivors per capture) and is a
property of the position model, not of the unit.

**Reading:** identity is only as stable as the unit; a grouping pass that
runs before tracking imports its own instability into identity. Tracking
lines and grouping afterwards costs merges, not identity. Device timing was
not measured here (offline replay, Tesseract boxes).

## Reproduce

```
python gen_corpus.py <tesseract.exe> .    # Tesseract 5.4.0, chi_sim (tessdata_fast), Microsoft YaHei installed
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-dynamic-reflow/pushdown.jsonl
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-dynamic-reflow/rewrap.jsonl
dart tool/replay/pregroup.dart doc/replay/validation/2026-08-dynamic-reflow/pushdown.jsonl pushdown.grouped.jsonl   # then ab-report / dump_frames on the grouped stream
dart tool/replay/dump_frames.dart doc/replay/validation/2026-08-dynamic-reflow/pushdown.jsonl dump.json 0   # per-capture identity (obs counts) and tracked positions
```

## Step response A/B (#116, 2026-08-29)

The `pushdown` entry above shows the default position model treating a
genuine 300 px content shift as jitter — the tracked position stays
130–160 px behind for several captures. #116 tracked two opt-in
alternatives: `StepResponse.snap` (a per-block residual threshold) and
`StepResponse.coherentShift` (a batch vote across an agreeing group of
moved pairs). This entry grades both against the `agreementWeighted` arm
— `StepResponse.damp`, today's behaviour before this change, and NOT the
`legacy` arm above (a structurally different position-match model, not a
`StepResponse` variant) — on `pushdown-300` and `rewrap` (the committed
streams above), six further `pushdown`/`pushup` gap/timing variants
(seven step streams total, committed under `variants/`), and ten streams
that carry no real step — `rewrap` plus nine Tesseract/PaddleOCR/on-device
ML-Kit dwell and scroll controls — seventeen streams total, four
`StepResponse` arms replayed per stream.

**Verdict: `StepResponse.coherentShift`, 14 of 17 streams, vs `snap`'s 11
of 17.** Re-derived independently from raw `ab-report` output over all 17
streams (not a sample) against the corrected `agreementWeighted` (damp)
baseline. `StabilizationEngine`'s constructor default is
[`coherentShift` as of this change](../../../../CHANGELOG.md);
`StepResponse.damp` restores the pre-change numerics exactly.

### Method

Each stream was run once through `dart tool/replay/replay.dart ab-report
<file>`, which reports `legacy`, `agreementWeighted`, `agreementSnap`,
`agreementCoherent`. The last three are the SAME agreement-weighted
position-match model, differing only in `StepResponse`: `agreementWeighted`
passes `StepResponse.damp` explicitly — its numerics do not move when
`StabilizationEngine`'s own default changes — and is the baseline for
this A/B; `agreementSnap` passes `StepResponse.snap`; `agreementCoherent`
passes `StepResponse.coherentShift`.
`legacy` is `PositionMergeModel.legacy` — a different merge model
entirely, with no residual/scale concept to gate a step response on (both
`StepResponse` options are a documented no-op under it) — it is not a
`StepResponse` variant, is not "damp", and is not graded here. The six
variants were generated with `gen_corpus.py`'s CLI knobs: four gap sizes
at the default reflow-at capture (50 / 150 / 600 / −300 px, capture 7)
plus two reflow timings at the default 300 px gap (captures 3 and 10),
seed 93 throughout — see `variants/` and `doc/README.md`'s doc-map row for
the knobs per file. The ten no-step streams are `rewrap` (a font swap —
chains should reset, not step) and nine already-committed
Tesseract/PaddleOCR/on-device dwell, OCR-jitter-dwell and synthetic-scroll
controls.

A judge scored all 17 streams against two rules:

- **Control rule** (10 streams, no real move): PASS iff `stepEvents == 0`
  AND the merge count matches damp's (`sameMergesAsDamp`) — any step
  event where there is no real coherent move is a false trigger
  regardless of merge count.
- **Step rule** (7 `pushdown`/`pushup` streams, a real move): PASS iff lag
  at the move capture and three/five captures later is AT MOST HALF of
  damp's, AND identity at the move capture is AT LEAST damp's.

### Result

*Lag = |OCR top − tracked top| per merge, mean over non-nested merges, per
capture (`topLagAfterPx`). Identity = merges / observed units
(`identityAtMove` at the move capture). Step events = merges where the
named option's step-response logic actually applied — zero means the
option fell through to damp's behaviour on every merge in the stream.
Control PASS = 0 step events AND merge count equal to damp's. Step PASS =
lag at move/+3/+5 ≤ half of damp's AND identity at move ≥ damp's.*

#### Control streams — no real step

| stream | kind | snap stepEvents | snap | coherent stepEvents | coherent |
|---|---|---|---|---|---|
| rewrap | rewrap — "chains should reset, no step" | 1 | **FAIL** | 0 | PASS |
| tess-stable-dwell | dwell | 0 | PASS | 0 | PASS |
| tess-jitter-dwell | dwell | 0 | PASS | 0 | PASS |
| tess-scroll | synthetic scroll | 1 | **FAIL** | 0 | PASS |
| paddle-stable-dwell | dwell | 0 | PASS | 0 | PASS |
| paddle-jitter-dwell | dwell | 0 | PASS | 0 | PASS |
| paddle-scroll | synthetic scroll | 5 | **FAIL** | 0 | PASS |
| mlkit-dwell | on-device (scroll-stamp lag confound) | 1 | **FAIL** | 0 | PASS |
| mlkit-dwell-bk | on-device | 0 | PASS | 0 | PASS |
| mlkit-scroll | on-device (scroll-stamp lag confound) | 0 | PASS | 0 | PASS |
| **tally** | | | **6/10** | | **10/10** |

Every FAIL row has `sameMergesAsDamp: true` — the merge count came out the
same as damp's either way — but `snap` still opened a step event where no
real move occurred (a per-block residual crossed threshold on an isolated
misread or on continuous scroll motion), which fails the control rule as
stated.

#### Step streams — real `pushdown`/`pushup` moves

| stream | gap / reflow-at | damp lag: move / +3 / +5 | identity at move | snap lag: move / +3 / +5 (stepEvents) | snap | coherent lag: move / +3 / +5 (stepEvents) | coherent |
|---|---|---|---|---|---|---|---|
| pushdown-300 | 300 px @ cap 7 | 123.8 / 77.3 / 70.2 | 0.769 | 2.3 / 15.2 / 2.6 (9) | PASS | 4.3 / 16.8 / 3.4 (9) | PASS |
| pushdown-050 | 50 px @ cap 7 | 25.9 / 25.5 / 28.9 | 0.900 | identical — 0 events | **FAIL** | identical — 0 events | **FAIL** |
| pushdown-150 | 150 px @ cap 7 | 82.5 / 66.5 / 59.1 | 0.964 | identical — 0 events | **FAIL** | 68.3 / 54.7 / 45.2 (3) | **FAIL** |
| pushdown-600 | 600 px @ cap 7 | 30.7 / 26.1 / 14.5 | 0.545 | 1.4 / 12.6 / 3.0 (6) | PASS | identical — 0 events | **FAIL** |
| pushup-300 | −300 px @ cap 7 | 155.1 / 92.7 / 67.3 | 0.667 | 9.8 / 19.9 / 4.1 (12) | PASS | 9.4 / 19.3 / 4.2 (11) | PASS |
| pushdown-300-early | 300 px @ cap 3 | 113.1 / 54.7 / 48.0 | 0.769 | 6.0 / 5.5 / 5.2 (10) | PASS | 7.0 / 5.9 / 5.5 (10) | PASS |
| pushdown-300-late | 300 px @ cap 10 | 135.6 / n/a / n/a | 0.731 | 8.7 / n/a / n/a (9) | PASS | 9.9 / n/a / n/a (9) | PASS |
| **tally** | | | | | **5/7** | | **4/7** |

Identity at move ties across damp/snap/coherent on every row — no
`StepResponse` can fire before the move capture, so the pre-move match
set is identical for all three — it never discriminates in this corpus;
the pass/fail split is decided by lag alone. `pushdown-300-late`'s reflow
lands three captures from the end of the 12-capture window, so
`lagPlus3`/`lagPlus5` are undefined for every arm there.

**Combined: `agreementSnap` 6 + 5 = 11/17. `agreementCoherent` 10 + 4 =
14/17.**

### Reading

`coherentShift` wins on breadth: it never false-triggers on a control
(10/10 — including `rewrap`, whose note explicitly says "chains should
reset, no step," and both synthetic-scroll controls, where `snap` fires 1
and 5 times on continuous motion it should ignore), and it clears four of
five 300 px-class step streams with lag cut by roughly an order of
magnitude. Its two misses are measured, not analytically inferred, and
neither is a regression against damp — both are tracked as #119:

- **`pushdown-600` (a 600 px slab): a clean fall-through, not a
  regression.** `coherentShift` never engages its `coherentShiftMinBlocks`
  / `coherentShiftMinShare` quorum — its merges are bit-identical to
  damp's. `snap`'s per-block threshold, having no quorum, passes this
  stream cleanly instead.
- **`pushdown-150` (150 px): a real cut, short of the bar.**
  `coherentShift` fires 3 step events and cuts lag 17–23 % — genuine, but
  short of the ≤ half-of-damp bar this A/B set. `snap` never fires here
  (below its residual threshold).
- **`pushdown-050` (50 px): inside the jitter allowance for both.**
  Neither option fires — the move is inside the block's own 3×-height
  agreement scale, so it is damped by design, the same as any ordinary
  jitter residual. Both arms are byte-identical to damp on this stream.

### Verdict (FINAL)

**`StepResponse.coherentShift`, 14/17 vs `snap`'s 11/17 — re-derived
independently from raw `ab-report` output over all 17 streams against the
`agreementWeighted` (damp) baseline.**

An earlier pass at this table carried a PROVISIONAL verdict: its own
written reasoning (not its tally) named `legacy` as "damp" and graded the
step streams against `legacy`'s lag figures, producing two false claims —
`pushdown-600`'s coherent lag called "worse than damp" (it is
bit-identical to the REAL damp arm, a clean fall-through, not a
regression) and `pushdown-150`'s coherent lag called "also worse than
damp" (against the real baseline it is 17–23 % lower, not worse). Two
spot-check passes (2–3 streams each) first caught the `legacy`-as-damp
defect and confirmed every PASS/FAIL classification was unchanged against
the corrected baseline; the full independent re-derivation above (all 17
streams, not a sample) confirms the same tally and the same winner, which
settles it.

`coherentShift`'s two measured misses (`pushdown-600`, `pushdown-150`) and
the untested-but-analytically-plausible gap below are tracked as #119 —
none of the three is a reason to prefer `snap` as the default, which
false-triggers on 4 of 10 controls (a cost paid on every stream, not just
the ones with a real step).

**Re-verified post-#120 review (2026-08-29):** the #116 review fan-out's
findings B/C reshaped `_detectCoherentShift`'s clustering (deterministic
ordering) and froze each coherent-shift member's drift snapshot at vote
time instead of re-reading it live mid-capture. Re-running `ab-report`
over all 17 streams after those fixes reproduces the identical 14/17 vs
11/17 tally and every PASS/FAIL cell above unchanged, including all 10
controls still showing zero `coherentShift` step events. The frozen-drift
fix (finding C) did move `agreementCoherent`'s `meanTopLagByCapture` by
≤0.1 px on 3 of 17 streams (`pushdown-150`, `pushdown-300-late`,
`pushup-300` — the streams where a coherent-shift member's residual had
previously been read after an earlier same-capture merge already
mutated it) — `pushdown-150`'s row above reflects the re-derived 68.3 /
54.7 / 45.2 (the prior 68.2 / 54.6 / 45.2 rounded to the same display
precision on the other two streams). The three affected `variants/*.ab.json`
files were regenerated from the fixed engine; the diff is confined to
`agreementCoherent`'s displacement/lag fields — `legacy`, `agreementWeighted`
and `agreementSnap` are byte-identical, confirming none of the other
arms leaked drift from the fix. This pass also surfaced a pre-existing,
unrelated gap: the 9 corpus-control `.ab.json` files outside
`variants/` (the on-device, PaddleOCR and Tesseract streams) were never
regenerated since the step-response fields were added, so they carry
none of `agreementSnap`/`agreementCoherent` and only a partial `legacy`/
`agreementWeighted` — tracked as #121, out of scope for this pass since
none of those 9 files changed.

### Boundary of what this proves

Synthetic corpus, single seed (93), one repetition per stream
configuration — no variance estimate on any number above. The six
variants are not a factorial grid (one axis at a time: four gap sizes at
the default timing, two timings at the default gap), so a step small
enough to miss `snap`'s threshold AND land on young chains, or large
enough to blow `coherentShift`'s quorum AND land on well-established
chains, is untested. The on-device streams (`mlkit-dwell`,
`mlkit-dwell-bk`, `mlkit-scroll`) carry the documented scroll-stamp lag
confound; `snap`'s single false-triggered step event on `mlkit-dwell` is
scored as a control failure per the stated rule, but could in principle
be catching that confound rather than a spurious per-block residual — not
demonstrated either way here. The identity-at-move criterion never
discriminated in this dataset (ties in every step row by construction)
and contributed nothing to the score; a future A/B should drop it or
measure identity at move+1 instead (also tracked as #119).
`_detectCoherentShift`'s exclusion of provisional / viewport-relative /
horizontal-scroll-child blocks from the moved-pair pool before the quorum
gates apply is, structurally, the same shape as the confirmed
`pushdown-600` miss (a quorum that can fail to see enough movers) but was
not itself exercised by any of the 17 streams — an untested, not a
measured, gap. Nothing here measures device timing (offline replay,
corpus JSONL only, consistent with the entry above).

### Reproduce

The numbers above come from the COMMITTED streams, not from regenerating
them: this environment's Tesseract/PaddleOCR toolchain does not reproduce
`pushdown.jsonl`/`rewrap.jsonl` bit-for-bit (confirmed by running
`gen_corpus.py`'s pre- and post-CLI-refactor forms side by side here —
both agree with each other, neither with the committed corpus — so this
is environment/version drift, not a script bug). The `gen_corpus.py`
invocations below are the ORIGINAL knobs each variant was produced with,
kept for provenance; regenerating from them in a different environment is
not guaranteed to reproduce the committed `.jsonl` bytes, only the
`ab-report` commands over the already-committed files are.

```
# provenance only — not guaranteed to reproduce the committed bytes in every environment
python doc/replay/validation/2026-08-dynamic-reflow/gen_corpus.py <tesseract.exe> <out_dir> --gap-px 50 --reflow-at 7 --seed 93     # -> pushdown-050.jsonl
python doc/replay/validation/2026-08-dynamic-reflow/gen_corpus.py <tesseract.exe> <out_dir> --gap-px 150 --reflow-at 7 --seed 93    # -> pushdown-150.jsonl
python doc/replay/validation/2026-08-dynamic-reflow/gen_corpus.py <tesseract.exe> <out_dir> --gap-px 600 --reflow-at 7 --seed 93    # -> pushdown-600.jsonl
python doc/replay/validation/2026-08-dynamic-reflow/gen_corpus.py <tesseract.exe> <out_dir> --gap-px -300 --reflow-at 7 --seed 93   # -> pushup-300.jsonl
python doc/replay/validation/2026-08-dynamic-reflow/gen_corpus.py <tesseract.exe> <out_dir> --gap-px 300 --reflow-at 3 --seed 93    # -> pushdown-300-early.jsonl
python doc/replay/validation/2026-08-dynamic-reflow/gen_corpus.py <tesseract.exe> <out_dir> --gap-px 300 --reflow-at 10 --seed 93   # -> pushdown-300-late.jsonl

# reproducible: runs against the committed streams, all four StepResponse arms in one JSON each
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-dynamic-reflow/pushdown.jsonl
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-dynamic-reflow/rewrap.jsonl
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-dynamic-reflow/variants/pushdown-050.jsonl
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-dynamic-reflow/variants/pushdown-150.jsonl
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-dynamic-reflow/variants/pushdown-600.jsonl
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-dynamic-reflow/variants/pushup-300.jsonl
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-dynamic-reflow/variants/pushdown-300-early.jsonl
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-dynamic-reflow/variants/pushdown-300-late.jsonl
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-tesseract-matrix/stable-dwell.jsonl        # + ocr-jitter-dwell.jsonl, scroll.jsonl
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-paddleocr-matrix/stable-dwell.jsonl        # + ocr-jitter-dwell.jsonl, scroll.jsonl
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-mlkit-on-device/dwell.jsonl                # + dwell-bk.jsonl, scroll.jsonl
```

Note: `pushdown.ab.json`/`rewrap.ab.json` committed above predate the
`StepResponse` arms (`legacy`/`agreementWeighted` only) — rerun `ab-report`
on the two `.jsonl` streams to see the four-arm output this section's
table cites; they were deliberately left as the historical snapshot for
the entry above rather than regenerated for this section.
