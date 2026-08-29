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
| 6 (before) | 30 | 28 / 2 | 21 / 1 | 1.6 px |
| 7 (the move) | 26 | 20 / 6 | 9 / 5 | **274.4 px** |
| 8 | 26 | 24 / 2 | 14 / 0 | 138.8 px |
| 9 | 26 | 24 / 2 | 14 / 0 | 160.2 px |
| 10 | 26 | 21 / 2 | 11 / 0 | 155.4 px |
| 11 | 26 | 20 / 3 | 10 / 1 | 153.4 px |
| 12 | 26 | 21 / 3 | 11 / 1 | 132.5 px |

(26 raw lines from capture 7 on: the slab pushes the last four lines out
of the viewport.) **Identity:** 9 of the 14 shifted lines match their
pre-move blocks on the reflow frame (text + band path); 24 of the 26 line
texts on capture 7 existed on capture 6 and 20 of them matched. The five
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

## Reproduce

```
python gen_corpus.py <tesseract.exe> .    # Tesseract 5.4.0, chi_sim (tessdata_fast), Microsoft YaHei installed
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-dynamic-reflow/pushdown.jsonl
dart tool/replay/replay.dart ab-report doc/replay/validation/2026-08-dynamic-reflow/rewrap.jsonl
dart tool/replay/dump_frames.dart doc/replay/validation/2026-08-dynamic-reflow/pushdown.jsonl dump.json 0   # per-capture identity (obs counts) and tracked positions
```
