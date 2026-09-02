# Zoom — a similarity-transform estimate over matched pairs, 2026-09-02 (#135)

The engine models one layout event, a translation shared by many blocks
(`StepResponse.coherentShift`), and treats everything else — a zoomed
page, a font-size change — as per-block displacement or, when the line
texts change, an identity reset (contract U9). It does NOT estimate a
scale. This entry adds the instrument #135 asked for: a similarity
transform — isotropic scale + translation, no rotation — fitted over each
capture's matched pairs and reported on the result
(`StabilizationResult.transformEstimate`, 2.6.0), never applied. The
question the corpus answers: does the estimate read a real zoom, and does
it stay quiet on every stream that is not one? Throughout, **deviation**
means `|scale − 1|`.

## Method

**The corpus** — the dynamic-reflow generator (`../2026-08-dynamic-reflow/
gen_corpus.py`, seed 93) gained `--zoom K`: a 20-character column (so a
1.25x line still fits the 1080 px viewport) rendered at scale 1 for
captures 1–6 and at scale K about the page origin from capture 7 on —
font, line height, margins and paragraph gap all times K, the viewport
crop unchanged (the same device pixels show different page content, as
a real zoom does). Two flavours per K: **pure** (the same line texts,
scaled boxes — a browser zoom or a DPR change) and **rewrap** (the same
paragraphs at the characters per line DIVIDED by K — a font-size change
on a fixed-width column holds fewer characters per line, 20 → 16 at
1.25 and 20 → 25 at 0.8, so every line's text changes). K = 1.25 and
0.8: `zoom-125`, `zoom-125-rewrap`, `zoom-080`, `zoom-080-rewrap`, 12
captures each, the same per-frame noise as the reflow corpus.

**The estimate** — `TransformEstimate.fit` (lib/src/transform_estimate.dart):
over the capture's eligible matched pairs (the coherent-shift detector's
eligibility — ordinary primary matches; no band admission, nested
fragment, provisional cached block, viewport-relative fresh block or
carousel child — collected in the real match loop, so it exists under
every `StepResponse`), the least-squares fit of
`freshCentre = scale * cachedCentre + translation` over raw absolute-rect
centres, then ONE trim: pairs whose residual exceeds three times the
median residual are set aside and the rest refitted, provided at least
`transformEstimateMinPairs` (3) remain. Reported: `scale`, `translation`,
`pairCount` (after the trim), `rejectedPairs`, `residualPx` (RMS),
`spanPx` (the RMS spread of the cached centres — the lever arm),
`largestGapShare` (the share of the pairs' extent, along the axis they
spread most on, taken by the largest gap between neighbouring cached
centres: a ladder of lines sits low, two clusters sit near 1) and
`fixedPoint` (the zoom origin, `translation / (1 - scale)`).

**The replay** — `dart tool/replay/replay.dart transform-report
<stream>.jsonl`: the shipping configuration (`agreementWeighted`,
`coherentShift`, `coherentShiftAdoptAgreeing: true`), one estimate per
capture. Its own mode, not an `ab-report` field, so the committed
`.ab.json` reports keep their bytes.

**The controls** — every non-zoom stream in the repository: the 17
published streams (the dynamic-reflow originals and variants, the three
Tesseract, three PaddleOCR and three ML Kit controls) and the 77 #136
seed-variance streams — 94 streams, 1,027 estimated captures (the
margins table's unbounded row). Steps, rewraps, dwells and scrolls
alike: whatever rule names the zoom captures must name none of these.

`zoom_report.py` (this directory) prints the three tables below;
`test/replay/experiment_doc_zoom_tables_test.dart` pins every cell — and
every table's row set — against a live replay.

## Result

### The zoom streams, captures 5–9 (the zoom renders from capture 7)

| stream | capture | scale | translation dx / dy | pairs | rejected | residual (px) | span (px) | gap share | merged / admitted |
|---|---|---|---|---|---|---|---|---|---|
| zoom-125 | 5 | 0.998 | 0.3 / -6.0 | 25 | 0 | 2.0 | 667.3 | 0.06 | 25 / 1 |
| zoom-125 | 6 | 0.998 | 0.6 / -5.5 | 25 | 1 | 1.9 | 667.3 | 0.06 | 26 / 5 |
| zoom-125 | 7 | 1.249 | -0.0 / -10.8 | 8 | 0 | 3.8 | 288.2 | 0.26 | 8 / 17 |
| zoom-125 | 8 | 0.920 | 49.1 / 209.9 | 24 | 1 | 84.3 | 704.9 | 0.07 | 25 / 0 |
| zoom-125 | 9 | 0.949 | 31.3 / 137.3 | 22 | 3 | 56.6 | 703.2 | 0.12 | 25 / 0 |
| zoom-125-rewrap | 5 | 0.999 | 0.4 / -6.8 | 25 | 0 | 1.9 | 666.9 | 0.06 | 25 / 1 |
| zoom-125-rewrap | 6 | 0.999 | 0.4 / -6.7 | 23 | 1 | 1.7 | 664.4 | 0.10 | 24 / 1 |
| zoom-125-rewrap | 7 | — | — | — | — | — | — | — | 2 / 23 |
| zoom-125-rewrap | 8 | 1.000 | 4.7 / 0.7 | 23 | 2 | 12.6 | 620.9 | 0.09 | 25 / 0 |
| zoom-125-rewrap | 9 | 1.000 | -2.2 / -6.2 | 23 | 2 | 6.2 | 621.2 | 0.09 | 25 / 0 |
| zoom-080 | 5 | 0.998 | 0.3 / -6.0 | 25 | 0 | 2.0 | 667.3 | 0.06 | 25 / 1 |
| zoom-080 | 6 | 0.998 | 0.6 / -5.5 | 25 | 1 | 1.9 | 667.3 | 0.06 | 26 / 5 |
| zoom-080 | 7 | 0.800 | 1.1 / -1.7 | 8 | 2 | 2.6 | 270.0 | 0.27 | 10 / 28 |
| zoom-080 | 8 | 1.075 | -31.1 / -181.4 | 33 | 4 | 73.1 | 594.5 | 0.06 | 37 / 1 |
| zoom-080 | 9 | 1.068 | -27.2 / -164.0 | 33 | 4 | 65.2 | 599.3 | 0.06 | 37 / 1 |
| zoom-080-rewrap | 5 | 0.999 | 0.4 / -6.8 | 25 | 0 | 1.9 | 666.9 | 0.06 | 25 / 1 |
| zoom-080-rewrap | 6 | 0.999 | 0.4 / -6.7 | 23 | 1 | 1.7 | 664.4 | 0.10 | 24 / 1 |
| zoom-080-rewrap | 7 | — | — | — | — | — | — | — | 0 / 38 |
| zoom-080-rewrap | 8 | 1.000 | 0.0 / -1.0 | 26 | 6 | 0.6 | 618.7 | 0.12 | 32 / 2 |
| zoom-080-rewrap | 9 | 1.000 | 0.0 / -7.5 | 32 | 0 | 0.7 | 620.3 | 0.06 | 32 / 4 |

`merged / admitted` is `identityTurnover` for the capture: how many
fresh lines merged into a tracked identity (the pool the fit draws from)
and how many entered as new identities.

### Every non-zoom stream: the capture of largest deviation

| stream | peak scale | peak deviation | residual at peak (px) | pairs at peak | gap share at peak | capture |
|---|---|---|---|---|---|---|
| s93-r1 / pushdown-300 | 1.220 | 0.220 | 86.7 | 20 | 0.12 | 7 |
| s93-r1 / rewrap | 1.174 | 0.174 | 68.1 | 7 | 0.31 | 7 |
| s93-r1 / pushdown-050 | 1.034 | 0.034 | 13.6 | 27 | 0.08 | 7 |
| s93-r1 / pushdown-150 | 1.104 | 0.104 | 40.6 | 27 | 0.05 | 7 |
| s93-r1 / pushdown-600 | 1.002 | 0.002 | 1.3 | 19 | 0.34 | 8 |
| s93-r1 / pushup-300 | 0.815 | 0.185 | 73.8 | 20 | 0.15 | 7 |
| s93-r1 / pushdown-300-early | 1.222 | 0.222 | 83.6 | 20 | 0.12 | 3 |
| s93-r1 / pushdown-300-late | 1.222 | 0.222 | 85.3 | 19 | 0.12 | 10 |
| s93-r1 / tess-stable-dwell | 1.000 | 0.000 | 0.3 | 26 | 0.07 | 7 |
| s93-r1 / tess-jitter-dwell | 1.002 | 0.002 | 2.4 | 28 | 0.07 | 9 |
| s93-r1 / tess-scroll | 1.005 | 0.005 | 4.3 | 23 | 0.09 | 8 |
| paddle-stable-dwell | 1.000 | 0.000 | 0.7 | 30 | 0.05 | 2 |
| paddle-jitter-dwell | 0.999 | 0.001 | 1.1 | 30 | 0.05 | 8 |
| paddle-scroll | 0.999 | 0.001 | 1.2 | 24 | 0.06 | 4 |
| mlkit-dwell | 0.963 | 0.037 | 4.9 | 3 | 0.55 | 14 |
| mlkit-dwell-bk | 1.000 | 0.000 | 0.6 | 3 | 0.69 | 27 |
| mlkit-scroll | 1.059 | 0.059 | 4.1 | 4 | 0.40 | 8 |
| s07-r1 / pushdown-050 | 1.034 | 0.034 | 14.1 | 29 | 0.05 | 7 |
| s07-r1 / pushdown-150 | 1.106 | 0.106 | 40.9 | 28 | 0.05 | 7 |
| s07-r1 / pushdown-300 | 1.216 | 0.216 | 81.9 | 20 | 0.12 | 7 |
| s07-r1 / pushdown-600 | 0.999 | 0.001 | 0.6 | 16 | 0.40 | 11 |
| s07-r1 / pushup-300 | 0.800 | 0.200 | 60.5 | 21 | 0.25 | 7 |
| s07-r1 / pushdown-300-early | 1.216 | 0.216 | 82.0 | 20 | 0.12 | 3 |
| s07-r1 / pushdown-300-late | 1.216 | 0.216 | 82.1 | 20 | 0.12 | 10 |
| s07-r1 / rewrap | 0.979 | 0.021 | 66.9 | 28 | 0.09 | 10 |
| s07-r1 / tess-stable-dwell | 1.000 | 0.000 | 0.6 | 28 | 0.07 | 11 |
| s07-r1 / tess-jitter-dwell | 1.000 | 0.000 | 0.6 | 27 | 0.07 | 10 |
| s07-r1 / tess-scroll | 1.009 | 0.009 | 3.6 | 25 | 0.06 | 6 |
| s07-r2 / pushdown-050 | 1.034 | 0.034 | 13.6 | 29 | 0.05 | 7 |
| s07-r2 / pushdown-150 | 1.106 | 0.106 | 41.0 | 28 | 0.05 | 7 |
| s07-r2 / pushdown-300 | 1.217 | 0.217 | 81.9 | 20 | 0.12 | 7 |
| s07-r2 / pushdown-600 | 0.999 | 0.001 | 2.4 | 16 | 0.35 | 10 |
| s07-r2 / pushup-300 | 0.802 | 0.198 | 57.8 | 20 | 0.25 | 7 |
| s07-r2 / pushdown-300-early | 1.217 | 0.217 | 81.8 | 20 | 0.12 | 3 |
| s07-r2 / pushdown-300-late | 1.216 | 0.216 | 81.9 | 20 | 0.12 | 10 |
| s07-r2 / rewrap | 1.012 | 0.012 | 11.5 | 11 | 0.12 | 7 |
| s07-r2 / tess-stable-dwell | 1.001 | 0.001 | 1.4 | 26 | 0.10 | 10 |
| s07-r2 / tess-jitter-dwell | 1.001 | 0.001 | 0.5 | 29 | 0.07 | 6 |
| s07-r2 / tess-scroll | 1.009 | 0.009 | 3.8 | 25 | 0.06 | 6 |
| s21-r1 / pushdown-050 | 1.033 | 0.033 | 13.9 | 29 | 0.05 | 7 |
| s21-r1 / pushdown-150 | 1.103 | 0.103 | 41.3 | 28 | 0.05 | 7 |
| s21-r1 / pushdown-300 | 1.223 | 0.223 | 86.9 | 23 | 0.09 | 7 |
| s21-r1 / pushdown-600 | 1.002 | 0.002 | 2.1 | 21 | 0.34 | 9 |
| s21-r1 / pushup-300 | 0.807 | 0.193 | 61.5 | 18 | 0.25 | 7 |
| s21-r1 / pushdown-300-early | 1.222 | 0.222 | 86.9 | 23 | 0.09 | 3 |
| s21-r1 / pushdown-300-late | 1.222 | 0.222 | 86.8 | 23 | 0.09 | 10 |
| s21-r1 / rewrap | 1.032 | 0.032 | 46.5 | 15 | 0.12 | 7 |
| s21-r1 / tess-stable-dwell | 0.999 | 0.001 | 1.7 | 29 | 0.07 | 8 |
| s21-r1 / tess-jitter-dwell | 0.999 | 0.001 | 0.6 | 28 | 0.07 | 9 |
| s21-r1 / tess-scroll | 0.990 | 0.010 | 3.1 | 24 | 0.09 | 4 |
| s21-r2 / pushdown-050 | 1.034 | 0.034 | 13.6 | 29 | 0.05 | 7 |
| s21-r2 / pushdown-150 | 1.103 | 0.103 | 41.1 | 28 | 0.05 | 7 |
| s21-r2 / pushdown-300 | 1.220 | 0.220 | 87.4 | 22 | 0.14 | 7 |
| s21-r2 / pushdown-600 | 1.000 | 0.000 | 0.5 | 12 | 0.16 | 7 |
| s21-r2 / pushup-300 | 0.806 | 0.194 | 62.5 | 17 | 0.25 | 7 |
| s21-r2 / pushdown-300-early | 1.220 | 0.220 | 87.5 | 22 | 0.14 | 3 |
| s21-r2 / pushdown-300-late | 1.221 | 0.221 | 87.4 | 22 | 0.14 | 10 |
| s21-r2 / rewrap | 1.038 | 0.038 | 41.5 | 14 | 0.12 | 7 |
| s21-r2 / tess-stable-dwell | 0.999 | 0.001 | 1.1 | 28 | 0.07 | 12 |
| s21-r2 / tess-jitter-dwell | 0.999 | 0.001 | 0.9 | 28 | 0.07 | 7 |
| s21-r2 / tess-scroll | 0.991 | 0.009 | 2.6 | 24 | 0.09 | 4 |
| s42-r1 / pushdown-050 | 1.032 | 0.032 | 14.0 | 29 | 0.05 | 7 |
| s42-r1 / pushdown-150 | 1.101 | 0.101 | 41.4 | 28 | 0.05 | 7 |
| s42-r1 / pushdown-300 | 1.212 | 0.212 | 85.7 | 22 | 0.09 | 7 |
| s42-r1 / pushdown-600 | 1.003 | 0.003 | 2.1 | 18 | 0.34 | 9 |
| s42-r1 / pushup-300 | 0.805 | 0.195 | 61.1 | 17 | 0.27 | 7 |
| s42-r1 / pushdown-300-early | 1.211 | 0.211 | 85.7 | 22 | 0.08 | 3 |
| s42-r1 / pushdown-300-late | 1.208 | 0.208 | 81.6 | 21 | 0.12 | 10 |
| s42-r1 / rewrap | 1.044 | 0.044 | 23.5 | 12 | 0.11 | 7 |
| s42-r1 / tess-stable-dwell | 0.998 | 0.002 | 3.8 | 30 | 0.05 | 3 |
| s42-r1 / tess-jitter-dwell | 0.999 | 0.001 | 3.1 | 30 | 0.05 | 3 |
| s42-r1 / tess-scroll | 0.990 | 0.010 | 10.5 | 23 | 0.07 | 7 |
| s42-r2 / pushdown-050 | 1.033 | 0.033 | 13.4 | 29 | 0.05 | 7 |
| s42-r2 / pushdown-150 | 1.102 | 0.102 | 41.0 | 28 | 0.05 | 7 |
| s42-r2 / pushdown-300 | 1.207 | 0.207 | 85.9 | 21 | 0.12 | 7 |
| s42-r2 / pushdown-600 | 1.003 | 0.003 | 1.8 | 14 | 0.10 | 10 |
| s42-r2 / pushup-300 | 0.807 | 0.193 | 67.0 | 20 | 0.19 | 7 |
| s42-r2 / pushdown-300-early | 1.201 | 0.201 | 81.7 | 20 | 0.12 | 3 |
| s42-r2 / pushdown-300-late | 1.208 | 0.208 | 85.6 | 21 | 0.12 | 10 |
| s42-r2 / rewrap | 1.044 | 0.044 | 24.2 | 12 | 0.11 | 7 |
| s42-r2 / tess-stable-dwell | 1.001 | 0.001 | 0.8 | 30 | 0.05 | 8 |
| s42-r2 / tess-jitter-dwell | 1.001 | 0.001 | 3.5 | 30 | 0.05 | 3 |
| s42-r2 / tess-scroll | 0.990 | 0.010 | 4.5 | 22 | 0.12 | 7 |
| s93-r2 / pushdown-050 | 1.033 | 0.033 | 13.7 | 27 | 0.08 | 7 |
| s93-r2 / pushdown-150 | 1.103 | 0.103 | 40.0 | 26 | 0.08 | 7 |
| s93-r2 / pushdown-300 | 1.220 | 0.220 | 86.7 | 20 | 0.12 | 7 |
| s93-r2 / pushdown-600 | 1.001 | 0.001 | 0.6 | 19 | 0.34 | 12 |
| s93-r2 / pushup-300 | 0.816 | 0.184 | 74.1 | 20 | 0.15 | 7 |
| s93-r2 / pushdown-300-early | 1.223 | 0.223 | 83.4 | 20 | 0.12 | 3 |
| s93-r2 / pushdown-300-late | 1.223 | 0.223 | 85.5 | 21 | 0.12 | 10 |
| s93-r2 / rewrap | 1.169 | 0.169 | 67.6 | 7 | 0.30 | 7 |
| s93-r2 / tess-stable-dwell | 1.000 | 0.000 | 0.6 | 25 | 0.07 | 8 |
| s93-r2 / tess-jitter-dwell | 1.000 | 0.000 | 0.6 | 27 | 0.07 | 10 |
| s93-r2 / tess-scroll | 1.004 | 0.004 | 1.6 | 22 | 0.09 | 10 |

### Margins: the largest control deviation under a residual cap, a pair floor and a gap-share cap

Over every estimated capture of every non-zoom stream (not only each
stream's peak capture): among the captures whose residual is under the
cap, whose fit used at least the floor's pairs AND whose gap share is at
most the gap cap, the largest deviation, which capture set it, and how
many captures qualified. `any` = no bound on that axis.

| residual under | pairs at least | gap share at most | largest control deviation | set by | control captures under all three |
|---|---|---|---|---|---|
| < 5 px | >= 3 | <= 0.5 | 0.059 | mlkit-scroll (cap 8, 4 pairs) | 835 |
| < 5 px | >= 3 | any | 0.059 | mlkit-scroll (cap 8, 4 pairs) | 840 |
| < 5 px | >= 6 | <= 0.5 | 0.010 | s42-r1 / pushdown-300-late (cap 11, 21 pairs) | 832 |
| < 5 px | >= 6 | any | 0.010 | s42-r1 / pushdown-300-late (cap 11, 21 pairs) | 832 |
| < 10 px | >= 3 | <= 0.5 | 0.059 | mlkit-scroll (cap 8, 4 pairs) | 850 |
| < 10 px | >= 3 | any | 0.059 | mlkit-scroll (cap 8, 4 pairs) | 855 |
| < 10 px | >= 6 | <= 0.5 | 0.010 | s42-r1 / pushdown-300-late (cap 11, 21 pairs) | 847 |
| < 10 px | >= 6 | any | 0.010 | s42-r1 / pushdown-300-late (cap 11, 21 pairs) | 847 |
| < 20 px | >= 3 | <= 0.5 | 0.059 | mlkit-scroll (cap 8, 4 pairs) | 901 |
| < 20 px | >= 3 | any | 0.059 | mlkit-scroll (cap 8, 4 pairs) | 906 |
| < 20 px | >= 6 | <= 0.5 | 0.034 | s07-r2 / pushdown-050 (cap 7, 29 pairs) | 898 |
| < 20 px | >= 6 | any | 0.034 | s07-r2 / pushdown-050 (cap 7, 29 pairs) | 898 |
| < 40 px | >= 3 | <= 0.5 | 0.097 | s07-r1 / pushdown-150 (cap 8, 28 pairs) | 941 |
| < 40 px | >= 3 | any | 0.097 | s07-r1 / pushdown-150 (cap 8, 28 pairs) | 946 |
| < 40 px | >= 6 | <= 0.5 | 0.097 | s07-r1 / pushdown-150 (cap 8, 28 pairs) | 938 |
| < 40 px | >= 6 | any | 0.097 | s07-r1 / pushdown-150 (cap 8, 28 pairs) | 938 |
| any | >= 3 | <= 0.5 | 0.223 | s93-r2 / pushdown-300-late (cap 10, 21 pairs) | 1022 |
| any | >= 3 | any | 0.223 | s93-r2 / pushdown-300-late (cap 10, 21 pairs) | 1027 |
| any | >= 6 | <= 0.5 | 0.223 | s93-r2 / pushdown-300-late (cap 10, 21 pairs) | 1019 |
| any | >= 6 | any | 0.223 | s93-r2 / pushdown-300-late (cap 10, 21 pairs) | 1019 |

## Reading

**1. A pure zoom reads at its event capture, and reads right.**
`zoom-125` capture 7: scale 1.249 over 8 pairs, residual 3.8 px, gap
share 0.26 (a ladder). `zoom-080` capture 7: scale 0.800 over 8 pairs
after 2 were trimmed, residual 2.6 px, gap share 0.27. Only 8 of the
25–38 lines in view matched: a 1.25x zoom moves a line 800 px down the
page by 200 px and a line 2400 px down by 600 px, and the spatial index
searches one to two bucket heights (220–440 px) around a block, so the
lines further down re-entered as new identities (17 and 28 admitted).
Eight pairs over a 270–290 px span pinned both scales to three decimals.
The fixed points are NOT the page corner the renderer scaled about:
`zoom-125`'s translation of (−0.0, −10.8) puts it 43 px below the origin
(`(−0.0, −10.8) / (1 − 1.249)`), `zoom-080`'s (1.1, −1.7) puts it 9 px
above. The 10.8 px is what the OCR line boxes at the new size read — box
edges do not scale exactly with the glyphs — and the 3.8 px residual
says the pairs still agree on one transform. That transform, not the
renderer's, is the one a consumer's own boxes follow, so `fixedPoint` is
the right anchor for them; a consumer that knows the renderer's origin
(a browser's visual viewport) has a better one.

**2. The trim is what makes the zoom-out readable — and it can also
manufacture a false transform.** Before it, the same capture of
`zoom-080` read scale 1.039 with a 179 px residual over 10 pairs (a
one-off fit of the same pairs without the trim; not in the tables): two
fresh lines had matched a near-duplicate sentence a few lines away
instead of their own line (this corpus's small vocabulary; real prose
repeats phrases too). Two pairs hundreds of px from the other eight
dragged a plain least-squares scale from 0.80 to 1.04. Three times the
median residual set exactly those two aside. On this corpus no step
capture was trimmed into a false transform — every step stream's peak
carries a 58–87 px residual over a ladder of 17–23 pairs (gap share
0.08–0.27). But the trim cannot promise that: over three paragraphs with
a slab under the second, the pairs at the step boundary ARE the first
fit's outliers, and the refit sees two clusters — a synthetic eight-line
page with a 200 px slab reads 1.28 at 9.8 px after the trim (51 px
before it), under the residual bound below
(`test/transform_estimate_test.dart` pins the case). What exposes it is
the shape of the kept pairs: `largestGapShare` 0.82 there, against
0.26–0.27 at the zoom events and at most 0.31 on any control capture
with six or more pairs. That is the reading rule's fourth bound.

**3. A rewrapping zoom reports no estimate at the event** — `zoom-125-
rewrap` merged 2 lines and admitted 23, `zoom-080-rewrap` merged 0 and
admitted 38: the identity reset of contract U1, which `identityTurnover`
names. The next capture reads a clean 1.000 over the new identities.
Nothing about the rewrap path changed.

**4. After the event the estimate reads the engine's own lag, and says
so.** Captures 8–9 of the pure zooms read 0.92–1.08 with 57–84 px
residuals: the merged members are damped toward the new geometry over
several captures (the merge is per block — the estimate is not applied)
while the admitted lines already sit at it, so the pairs no longer
describe one transform. The residual bound of the reading rule refuses
these captures. A consumer that rescales its own geometry at the event
capture and lets the engine converge sees the residual fall (84 → 57 px
over two captures on `zoom-125`) and the scale return to 1.

**5. The controls stay quiet under the bounds.** No dwell or scroll
stream of any engine exceeds a deviation of 0.010 with six or more pairs
and a residual under 10 px (94 streams, 847 such captures; the largest
is `tess-scroll` at 0.010 with 10.5 px on one seed's page). The 300 px
step streams, up and down, in all four positions, peak at 0.18–0.22 —
least squares spreading the step over the lines above and below it — but
always with a 58–87 px residual; `pushdown-150` at 0.10–0.11 with
40–41 px, `pushdown-050` at 0.03 with 13–14 px, `rewrap` at up to 0.174
with 68 px (the published seed's seven surviving pairs). The three ML
Kit on-device streams, with three or four blocks in view, reach 0.059 at
a 4 px residual — a four-pair fit over a short span (`residualPx /
spanPx` is the scale's uncertainty) — which is why the pair floor is
part of the rule and not an afterthought. Gap shares at the peaks are
0.05–0.31 everywhere except those ML Kit captures (0.40–0.69, three or
four pairs), so on this corpus the gap-share bound removes only captures
the pair floor removes too: it is set by construction (three evenly
spaced pairs sit at exactly 0.5; the synthetic two-cluster cases at
0.82–0.87), not by a measured control.

**6. The reading rule this corpus supports**, as a starting point for a
consumer's own captures:

> a zoom this capture ⇔ `|scale − 1| ≥ 0.10` and `residualPx ≤ 10` and
> `largestGapShare ≤ 0.5` and `pairCount ≥ 6`; rescale the geometry you
> hold outside the engine by `scale` about `fixedPoint`.

Margins: the two zoom events sit at 0.249 / 3.8 px / 0.26 / 8 pairs and
0.200 / 2.6 px / 0.27 / 8 pairs; the largest control deviation under the
rule's bounds is 0.010, ten times below the threshold; relaxing the
residual bound to 20 px admits `pushdown-050`'s event at 0.034, still
three times below; dropping the pair floor to 3 admits the ML Kit
four-pair capture at 0.059. A page with fewer than six matched lines
cannot be read by this rule — lower the floor at your own risk, and read
`spanPx`. A page whose matched lines form two clusters cannot be read by
any rule over this estimate: a translation of one cluster and a zoom
about a point fit the same pairs, and only `coherentShift`,
`identityTurnover` or the consumer's own source can decide.

## Boundary of what this proves

One seed (93), one noise draw, one layout (a 20-character column at 36 px,
narrower than the reflow corpus's 26), two scale factors, and a zoom about
the page origin only — a zoom about the viewport centre gives the same
scale with a different translation and fixed point, which the fit's model
covers but the corpus does not exercise. The trim threshold (three times
the median) and the reading rule's four bounds were set on this corpus
and on synthetic fixtures; the control population is the repository's
synthetic streams plus the six cross-engine streams, none of which
contains a real zoom, so the rule's false-positive rate on real captures
is unmeasured. No control capture has the two-cluster shape (every stream
is a ladder of consecutive lines), so the gap-share bound is checked
against unit fixtures only, never against a measured false positive. A
zoom that pushes every line in view beyond the index's reach (a large
factor combined with a large scroll offset) leaves nothing to fit and
reads as an identity reset, the same as a rewrap. The estimate is
observed only: what a consumer does with it is outside the engine.
Nothing here measures device timing.

## Reproduce

```
# the corpus (Tesseract 5.4.0 + chi_sim + Microsoft YaHei + Pillow 12.2; ~20 s per factor)
python doc/replay/validation/2026-08-dynamic-reflow/gen_corpus.py <tesseract.exe> doc/replay/validation/2026-09-zoom --zoom 1.25
python doc/replay/validation/2026-08-dynamic-reflow/gen_corpus.py <tesseract.exe> doc/replay/validation/2026-09-zoom --zoom 0.8

# one stream's per-capture estimates (deterministic over the committed streams)
dart tool/replay/replay.dart transform-report doc/replay/validation/2026-09-zoom/zoom-125.jsonl

# the three tables above (all 98 streams; about 90 s)
python doc/replay/validation/2026-09-zoom/zoom_report.py
```
