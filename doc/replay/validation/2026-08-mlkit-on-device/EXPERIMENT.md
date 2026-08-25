# ML Kit on-device capture over a synthetic page — 2026-08-25 (#108)

The two 2026-07 ML Kit entries validate against production capture
streams that cannot be committed (their text belongs to third-party
pages). This entry closes that gap: **real ML Kit, real device, fully
committed streams** — the page is synthetic, so every observation in
`dwell.jsonl` / `scroll.jsonl` is distributable and the whole analysis
regenerates from this directory.

## Method

`gen_page.py` (this directory) synthesizes a CJK page from a small
common-hanzi vocabulary (deterministic, seed 95 — no copyrighted text)
as HTML. The page is served to a Galaxy S25 over `adb reverse` and
displayed in the consumer app's WebView; the app pipeline (screenshot →
**ML Kit text recognition** → grouping) runs with its stabilization
stream recorder enabled (`--dart-define=STAB_CAPTURE=true`, capture
schema v1 — the same recorder that produced the 2026-07 streams).
Translation mode `mlkit`, overlay display, DOM extraction off (forcing
the OCR arm). Rects are page-absolute CSS px (viewport 360 px wide,
device pixel ratio 3).

| stream | shape | batches / obs |
|---|---|---|
| `dwell.jsonl` | one viewport, 14 micro-scroll oscillations (±20 CSS px) at ~2 s cadence | 19 / 98 |
| `scroll.jsonl` | 14-step downward ladder (~200 CSS px per step) | 15 / 84 |

Unlike the Tesseract corpus (rendered frames, photometric perturbation),
the noise here is the real production stack end to end: WebView
rasterization, screenshot compression, ML Kit segmentation, and the
app's own grouping — including genuine per-frame **misrecognitions**
(e.g. 于是→王是), which exercise the text-vote path.

## Result (`ab-report`, committed alongside)

| stream | arm | disp n1-2 | disp n3-5 | disp n6-10 | wellObs pconf |
|---|---|---|---|---|---|
| dwell | agreement | 13.62 | **4.07** | **4.30** | 0.911 |
| dwell | legacy | 13.75 | 11.31 | 20.74 | 1.0 (saturated) |
| scroll | agreement | 6.24 | — | — | — (no chain reaches 3) |
| scroll | legacy | 6.57 | — | — | — |

(px per merge, means; counts in the `.ab.json` files.)

## Reading

This is the **high-amplitude regime the 3× allowance was tuned for**,
now on distributable data: raw ML Kit boxes move ~11–21 px per merge on
established chains under a mere ±20 px oscillation. The agreement model
damps established chains 2.8–4.8× (11.31→4.07, 20.74→4.30) while young
blocks stay at parity (13.75 vs 13.62) — the same shape as the 2026-07
production sweeps (3.8 vs 11.8 at n11+) and the Tesseract entry, and
confidence stays informative (0.911) instead of saturating.

The scroll ladder is young-blocks-only (no chain survives to depth 3 in
14 one-directional steps) and shows parity, as designed — the anchoring
loop has nothing to anchor.

## Boundary of what this proves

Small n (19+15 batches, ~5 paragraph-level blocks per viewport at this
zoom); one device, one page style; the dwell oscillation is scripted,
not human. Statistical weight stays with the 2026-07 production sweeps —
this entry's value is **provenance** (committed streams, regenerable
end-to-end analysis) and **demo material**: the README's hero GIF
renders from `dwell.jsonl`.

## Reproduce

```
python gen_page.py page.html
python -m http.server 8907          # from the page's directory
adb reverse tcp:8907 tcp:8907
# build the consumer app with --dart-define=STAB_CAPTURE=true, set
# translation mode mlkit / overlay display / DOM extraction off, and
# open http://localhost:8907/page.html; drive the two scenarios; pull
# <documentsDir>/stab-capture/*.jsonl
dart tool/replay/replay.dart ab-report dwell.jsonl
dart tool/replay/dump_frames.dart dwell.jsonl dump.json 2
python doc/media/render_demo_gif.py dump.json demo.gif "0,250,360,860" 1.25
```

The capture app is any consumer wiring the recorder documented in
`doc/replay/capture_schema.md`; the committed streams carry the exact
schema the loader reads, so the analysis half (`ab-report` onward)
reproduces from this directory alone.
