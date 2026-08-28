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
device pixel ratio 3). The recorder did not write the `vp` viewport
field at capture time (rig 2.1.0 added it): the 360×587 CSS px value in
both headers was read from the recording WebView over the Chrome
DevTools Protocol during the same 2026-08-25 session and stamped into
the headers on 2026-08-29. The recorder-side writer is tracked in the
same consumer issue as the scroll-stamp lag below (2552).

| stream | shape (measured from the stream's own scroll stamps) | batches / obs |
|---|---|---|
| `dwell.jsonl` | captures 0–18: one viewport under scripted micro-scrolls whose recorded scroll offset moves 0–297 CSS px between captures (one excursion to 662 px at capture 9); the five captures after 18 (ids 19, 20, 22, 23, 24 — the recorder skips ids): a momentum fling from 735 to 3,328 px | 19 / 98 |
| `scroll.jsonl` | 14 steps down the page, 0 to 3,920 px: the recorded scroll offset advances 274–316 CSS px per step for the first twelve steps (median 303 px), then 159 and 153 px for the last two | 15 / 84 |

**Correction (2026-08-29).** This table first described the dwell as
"14 micro-scroll oscillations (±20 CSS px)" — the script's intent, not
the data. Reading the `sc[0]` field of every block shows the shape above.
Two consequences: (1) the scroll offset the producer stamps on a capture
can lag the screenshot by 100–150 px during motion (the app reads it from
a pushed vitals frame, not at screenshot time —
https://github.com/Abdallah01/ocr_translate_demo/issues/2552), so the same
text line is reported at page-absolute positions that differ by that much
between captures; (2) the last five captures are a fling, not a dwell,
and the README demo GIF uses captures 0–18 only.

Unlike the Tesseract corpus (rendered frames, photometric perturbation),
the noise here is the real production stack end to end: WebView
rasterization, screenshot compression, ML Kit segmentation, the app's own
grouping, and the producer's scroll-stamp lag described above — including
genuine per-frame **misrecognitions** (e.g. 于是→王是), which exercise
the text-vote path.

## Result (`ab-report`, committed alongside)

| stream | arm | disp n1-2 | disp n3-5 | disp n6-10 | wellObs pconf |
|---|---|---|---|---|---|
| dwell | agreement | 8.71 | **4.07** | **0.19** | 0.918 |
| dwell | legacy | 8.85 | 11.31 | 0.79 | 1.0 (saturated) |
| scroll | agreement | 5.46 | — | — | — (no chain reaches 3) |
| scroll | legacy | 5.46 | — | — | — |

(px per merge, means; counts in the `.ab.json` files. Regenerated
2026-08-29 with rig 2.1.0, which configures the engine with the stream's
own viewport — `meta.vp` = 360×587 CSS px, i.e. 80×88 px spatial-index
buckets — instead of the 200 px default buckets the earlier numbers were
produced on. Four dwell merges and one scroll merge disappear (34→30,
19→18): matches whose partner sits outside the 3×3 cell neighbourhood at
production bucket size. They were the large-displacement ones — the
n6-10 legacy mean falls from 20.74 to 0.79 px over the four merges that
remain, and n1-2 from 13.75 to 8.85.)

> **2.2.0 note (2026-08-29).** Two things changed in the committed
> `.ab.json` without moving a displacement number. (1) The nested
> re-observation rule (#112) turns a line reported inside its own
> paragraph into a confirmation of the paragraph instead of a new block;
> the reports now count those separately (`nestedFragmentMerges`: dwell
> 3, scroll 6 — `mergeCount` 30→33 and 18→24) and keep them OUT of the
> displacement buckets, since a confirmation moves nothing by
> construction. Every bucket mean and count above is unchanged. (2) The
> rig now models the consumer's bucket policy (#113). These two streams
> predate the recorder's `bk` field, so the committed reports still run
> on the viewport formula (`input.bucketPolicy: auto` →
> `viewportFormula`); `--buckets=median` emulates the consumer's 2×
> median block height rule from the tracked state and gives, on the
> agreement arm: dwell buckets ≈ 103 px (80 at the start, 220 on the
> fling tail), 36 merges, n1-2 8.71→10.18 over 18, n3-5 4.07 unchanged,
> n6-10 0.19→**4.30 over six merges** (legacy 0.79→20.74 — the far
> matches production geometry was said to lose come back at the
> consumer's real bucket size), wellObs pconf 0.918→0.911; scroll
> buckets 103→171 px, 25 merges, n1-2 5.46→6.24 (legacy 6.57). So the
> viewport-formula numbers UNDERSTATE the displacement the consumer's
> steady-state geometry sees on this stream; a fresh capture with `bk`
> will settle which.

## Reading

This is the **high-amplitude regime the 3× allowance was tuned for**,
now on distributable data: raw ML Kit boxes move ~11 px per merge on
n3-5 chains (n6-10 sits under 1 px, on four merges). Two sources feed
that number, and this entry cannot separate them: genuine OCR
re-segmentation, and the producer's scroll-stamp lag (same text, 100–150
px apart between captures — see the correction above). For a static
page the true position is fixed, so holding an established block still
is the right response to BOTH; what the lag additionally produces is a
young block admitted in the lagged frame next to an established block
held in the true frame, i.e. two coordinate frames in one tracked state
(the box-on-box overlaps in the 2.0.0 demo). 2.1.0's cross-frame
supersession evicts a retained box once one fresh box covers at least
half of its own area; on the 14 demo frames that cuts overlapping pairs
of tracked boxes from 32 to 23 (`doc/media/count_overlap_pairs.py` over
the `dump_frames.dart` output — any two tracked boxes with a positive
intersection, per frame, summed). Of those 23, 8 were a paragraph box
with one of its own lines inside it (ML Kit reports the same text as a
paragraph in one frame and as one line in the next; the line's text is
a prefix of the paragraph's and scores under the whole-string match
gate, so it was admitted as new), 14 the lag — captures 16–18 arrive 21
to 150 px off the earlier frames, so different text lands on an
established box; capture 18 shifts every block by ~150 px at once — and
1 a segmentation split. 2.2.0's nested re-observation rule (#112)
absorbs the first family: a fresh box at least 80 % inside a cached
block whose text it is a fragment of (windowed Levenshtein ≥ 0.70 on ≥ 4
significant characters) confirms that block instead of spawning, and a
fragment reported in the same frame as its paragraph is dropped as
redundant. On the 14 demo frames that takes the count from 23 to **15**
(per frame `0 0 0 0 0 0 0 0 0 1 0 2 4 8`); the six nested pairs in
frames 5–8 and 11–12 are gone, and all 15 that remain are the lag —
different text over an established box, or the same paragraph split
into two side-by-side boxes 23–31 px below where it was — which no
engine rule can tell from real new text (the consumer's issue for the
lag is cited above). Two measured bars, both from this stream: the host
must only be a cached non-provisional block seen ONCE (the grouping
flips every frame here, so a paragraph never reaches two observations
before its line arrives), and containment is 0.8 because a second line
hangs 3 px below its paragraph box (14 of 17 px inside). The app's own
dedup cascade runs after the engine and absorbs most of the lag pairs
(its recorded `dedup` events for captures 16, 17 and 18 add 3, 0 and 2
of 8, 5 and 7 incoming blocks), so the demo overstates what the app's
overlay shows. The
agreement model damps established chains 2.8× at n3-5 (11.31→4.07; the
four n6-10 merges go 0.79→0.19) while young blocks stay at parity (8.85
vs 8.71) — the same shape as the 2026-07 production sweeps (3.8 vs 11.8
at n11+) and the Tesseract entry, and confidence stays informative
(0.918) instead of saturating.

The scroll ladder is young-blocks-only (no chain survives to depth 3 in
14 one-directional steps) and shows parity, as designed — the anchoring
loop has nothing to anchor.

## Boundary of what this proves

Small n (19+15 batches, ~5 paragraph-level blocks per viewport at this
zoom); one device, one page style; the dwell motion is scripted, not
human, and its scroll stamps lag the screenshot (correction above), so
the "raw movement" it measures is an upper bound on OCR jitter, not OCR
jitter alone. The last five dwell captures are a fling and contribute
young-block merges only. Statistical weight stays with the 2026-07
production sweeps — this entry's value is **provenance** (committed
streams, regenerable end-to-end analysis) and **demo material**: the
README's hero GIF renders from `dwell.jsonl` captures 0–18.

## Reproduce

```
python gen_page.py page.html
python -m http.server 8907          # from the page's directory
adb reverse tcp:8907 tcp:8907
# build the consumer app with --dart-define=STAB_CAPTURE=true, set
# translation mode mlkit / overlay display / DOM extraction off, and
# open http://localhost:8907/page.html; drive the two scenarios; pull
# <documentsDir>/stab-capture/*.jsonl
dart tool/replay/replay.dart ab-report dwell.jsonl   # 2.1.0: applies meta.vp; --viewport=360x587 for a stream without it
dart tool/replay/replay.dart ab-report dwell.jsonl --buckets=median   # 2.2.0: the consumer's 2x-median bucket emulation (the note above)
dart tool/replay/dump_frames.dart dwell.jsonl dump.json 2   # same viewport rule; --buckets=... as above
python doc/media/render_demo_gif.py dump.json demo.gif "0,250,360,860" 1.25 14   # the 14 frames = captures 0-18
```

The capture app is any consumer wiring the recorder documented in
`doc/replay/capture_schema.md`; the committed streams carry the exact
schema the loader reads, so the analysis half (`ab-report` onward)
reproduces from this directory alone.
