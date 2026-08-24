# Cross-engine validation matrix, first entry: Tesseract 5 — 2026-08-24 (#94)

The `_kAgreementJitterAllowance` doc and the 2026-07 scale sweep both carry
the caveat "calibrated against ML-Kit-shaped noise; re-run the sweep for a
different engine." This experiment is the first non-ML-Kit data point.

## Method

`gen_corpus.py` (this directory) renders a synthetic CJK prose page
(1080×7760, 105 lines, Microsoft YaHei 36 px; text composed from a small
common-hanzi vocabulary — no copyrighted source), crops per-frame
viewports, perturbs each frame (subpixel shift + JPEG roundtrip +
brightness scale — Tesseract is deterministic on identical pixels, so the
perturbation stands in for the screenshot-pipeline variation real captures
carry), runs **Tesseract 5.4.0 / chi_sim (tessdata_fast) / PSM 6** per
frame, and serializes line-level blocks as capture schema v1 JSONL
(`pconf` 0.5 fresh, `tconf` = mean word confidence). Rects are lifted to
clean page-absolute coordinates, so residual box jitter is exactly the
engine-shaped noise under test. Reports: `tool/replay/replay.dart
ab-report` per scenario, unmodified.

| scenario | frames | perturbation | batches / obs |
|---|---|---|---|
| `stable-dwell` | same viewport ×12 | shift ≤0.3 px, JPEG 90, ±2% bright | 12 / 360 |
| `ocr-jitter-dwell` | same viewport ×12 | shift ≤1.5 px, JPEG 70, ±6% bright | 12 / 360 |
| `scroll` | 0→5200 px in 400 px steps | mild (as stable) | 14 / 424 |

## Result (ab-report; agreementWeighted vs legacy, same stream)

| scenario | arm | disp n3-5 | disp n6-10 | disp n11+ | pconf mean/p50 |
|---|---|---|---|---|---|
| stable-dwell | agreement | 0.04 | 0.02 | **0.01** | 0.94 / 0.94 |
| stable-dwell | legacy | 0.10 | 0.12 | 0.10 | 1.0 (saturated) |
| ocr-jitter | agreement | 0.68 | 0.33 | **0.05** | 0.91 / 0.92 |
| ocr-jitter | legacy | 1.51 | 1.71 | 1.18 | 1.0 (saturated) |
| scroll | agreement | **1.52** | — | — | 0.88 / 0.89 |
| scroll | legacy | 3.61 | — | — | 1.0 (saturated) |

Merge/match rates: 312/308/312 merges over the three streams (~94% of
re-observation opportunities in the dwell scenarios) — no retention
anomaly.

## Reading

The ML-Kit sweep's qualitative claims **transfer to Tesseract-shaped noise
without retuning**:

- established chains damp dramatically under jitter (n11+ 0.05 vs legacy
  1.18 px/merge — the confidence→weight anchoring loop engages exactly as
  on ML Kit, where it was 3.8 vs 11.8 at 10× the amplitude);
- young blocks still track (scroll n1-2: 2.8 px agreement vs 3.1 px
  legacy — near-parity, as expected while chains are too young for the
  anchoring loop to engage);
- confidence stays regime-discriminating (0.94 stable / 0.91 jitter /
  0.88 scroll) instead of legacy's saturated-flat 1.0.

**Verdict: the 3× allowance and the agreementWeighted default carry to
Tesseract in the low-amplitude regime. No engine-specific knob needed for
this regime.**

## Boundary of what this proves

Tesseract on clean rendered text produces mostly *photometric* jitter:
the typical re-observation lands under 1 px (scroll p50 0.67 px legacy /
0.56 px agreement). It is not purely photometric, though — about half of
the lines observed across several scroll frames show one or two frames
where the line box's extent flips by ~20 px (a mild, transient form of
re-segmentation: the box extent changes, not the position). The
page-absolute lift itself is verified by the same corpus: a line's lifted
Y is identical across most frames taken at different scroll offsets.

What the corpus does NOT reproduce is ML Kit's *persistent*
high-amplitude re-segmentation (30–45 px effective residuals from
per-frame block re-splitting), which is what the 3× constant was
actually tuned against — so this matrix entry validates transfer in the
regime where the allowance is generous, not the regime that stresses it.
A degraded-imagery Tesseract corpus (photographs, low-contrast scans)
would be the next entry if anyone hits Tesseract re-segmentation churn in
practice.

## Reproduce

```
winget install UB-Mannheim.TesseractOCR
# + chi_sim.traineddata (tessdata_fast) into the install's tessdata/
pip install pillow
python gen_corpus.py <tesseract.exe> .
dart tool/replay/replay.dart ab-report <scenario>.jsonl
```

`gen_corpus.py` renders with `C:\Windows\Fonts\msyh.ttc` (Microsoft
YaHei, present on stock Windows). On another OS, point the
`ImageFont.truetype` call at any CJK font — the corpus text is
synthesized, so any face works, but the OCR boxes (and therefore the
exact numbers) will differ.
