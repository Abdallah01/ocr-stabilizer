# Cross-engine validation matrix, third entry: PaddleOCR — 2026-08-25 (#94)

Third engine in the matrix, alongside ML Kit (production sweeps + the
on-device entry) and Tesseract. Same fully-synthetic recipe as the
Tesseract entry — **the identical rendered page (same seed 94), the
identical perturbation schedule** — so any difference between the two
entries' numbers is engine-shaped noise, nothing else.

## Method

`gen_corpus.py` (this directory) is the Tesseract generator with the
engine swapped: **PaddleOCR 3.7.0, PP-OCRv6_medium det+rec, lang='ch'**
(document orientation/unwarping/textline-orientation modules off,
oneDNN off — see the script header for the Windows-CPU pin), line-level
polygons reduced to axis-aligned rects, confidence clamped to the same
0.30–0.99 band. Capture shapes are identical to the Tesseract entry:

| scenario | frames | perturbation | batches / obs |
|---|---|---|---|
| `stable-dwell` | same viewport ×12 | shift ≤0.3 px, JPEG 90, ±2% bright | 12 / 360 |
| `ocr-jitter-dwell` | same viewport ×12 | shift ≤1.5 px, JPEG 70, ±6% bright | 12 / 362 |
| `scroll` | 0→5200 px in 400 px steps | mild (as stable) | 14 / 424 |

## Result (`ab-report`; agreementWeighted vs legacy, same stream)

| scenario | arm | disp n3-5 | disp n6-10 | disp n11+ | pconf mean |
|---|---|---|---|---|---|
| stable-dwell | agreement | 0.08 | 0.04 | **0.03** | 0.934 |
| stable-dwell | legacy | 0.21 | 0.24 | 0.22 | 1.0 (saturated) |
| ocr-jitter | agreement | 0.20 | 0.11 | **0.08** | 0.929 |
| ocr-jitter | legacy | 0.51 | 0.59 | 0.54 | 1.0 (saturated) |
| scroll | agreement | **1.08** | — | — | 0.900 |
| scroll | legacy | 2.70 | — | — | 1.0 (saturated) |

Merge rates: 330/330/322 over the three streams — no retention anomaly.

Scroll rows regenerated 2026-08-29 with rig 2.1.0, which configures the
engine with the corpus viewport (`meta.vp` = 1080×2200 CSS px) instead
of the 200 px default buckets; merge counts are unchanged and the two
dwell scenarios (no motion between captures) produce identical numbers
either way.

## Reading

Same qualitative shape as every other entry, at the lowest amplitude in
the matrix so far:

- established chains damp ~5–7× under jitter (n11+ 0.08 vs 0.54
  px/merge) and the anchoring loop engages exactly as on ML Kit and
  Tesseract;
- young blocks track at near-parity (scroll n1-2: 2.12 vs 2.34);
- confidence stays regime-discriminating (0.93 dwell / 0.90 scroll)
  instead of legacy's saturated 1.0.

**Verdict: the 3× allowance and the agreementWeighted default carry to
PaddleOCR without retuning.** PP-OCRv6 on clean rendered text is the
*most* photometric engine measured yet — sub-pixel residuals throughout,
no line-extent flips of the kind Tesseract showed — so, as with
Tesseract, this validates the generous regime, not the stressed one.
The high-amplitude re-segmentation regime remains covered by the ML Kit
entries.

## Reproduce

```
# Python 3.12 (paddlepaddle has no 3.13+/3.14 wheels yet):
uv venv paddle-venv --python 3.12
uv pip install --python paddle-venv paddleocr==3.7.0 paddlepaddle==3.3.0 Pillow
paddle-venv/Scripts/python gen_corpus.py .
dart tool/replay/replay.dart ab-report <scenario>.jsonl
```

First run downloads the PP-OCRv6_medium models (~ tens of MB) into
`~/.paddlex/`. The install pins match the versions the corpus was
generated with; an unpinned install may fetch a newer engine whose
default `lang='ch'` models differ. The same font note as the Tesseract entry applies
(`C:\Windows\Fonts\msyh.ttc`; substitute any CJK face on another OS and
expect different boxes and therefore different numbers).
