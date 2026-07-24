# Per-block agreement scale — adoption evidence (#75, 2026-07-24)

Provenance for the 1.1.0 scale-base change in
`_mergedPositionConfidence`: the `agreementWeighted` agreement scale moved
from `3 × medianBlockHeightForKey(spaceKey)` (region median) to
`3 × existing.absoluteRect.raw.height` (the tracked block's own height).
Method mirrors `../2026-07-scale-sweep/`: each JSON is a
`tool/replay/replay.dart ab-report` over a production consumer capture,
run twice — `median-*.json` at the shipped 1.0.x scale, `perblock-*.json`
with the per-block base — on the SAME engine revision. The legacy arm was
bit-identical between runs in every pair (the patch touches only the
agreementWeighted scale), and `mergeCount` is identical per pair, so
displacement deltas are read on identical pairings.

## Capture shapes (raw captures are consumer content — not committed)

| pair | stream shape | batches/obs |
|---|---|---|
| `*-ocr-jitter-dwell` | stationary content, OCR-quantized rects | 32/414 |
| `*-stable-dwell` | stationary content, deterministic layout rects | 60/476 |
| `*-dom-scroll` | scroll walk, deterministic layout rects | 43/395 |
| `*-ocr-scroll-a` | scroll walk, OCR rects (legacy arm live) | 11/103 |
| `*-ocr-scroll-b` | scroll walk, OCR rects (agreementWeighted live) | 10/115 |
| `*-reflow-rotation` | physical-rotation reflow cycles (fresh 2026-07-24 capture; DOM-arm, mixed portrait/landscape) | 21/114 |

## Result (agreementWeighted arm)

**OCR-jitter dwell (192 merges) — the discriminating regime:**

| band | median-scale mean/p50 (px/merge) | per-block mean/p50 |
|---|---|---|
| n1-2 | 14.38 / 12.79 | 13.63 / 10.18 |
| n3-5 | 12.20 / 13.56 | **8.74 / 7.44** |
| n6-10 | 8.66 / 9.51 | **5.44 / 3.73** |
| n11+ | 3.83 / 3.71 | 3.97 / **1.29** |
| wellObservedPconf mean/p50 | 0.352 / 0.215 | **0.620 / 0.742** |

The F2 pooling dilution is real: per-frame OCR re-segmentation feeds the
region median small fragment heights, shrinking the scale below the
block's own text size — confidence then collapses on genuine-jitter-scale
residuals and the anchoring loop weakens. n11+ nuance: mean +0.14 while
p50 −65% (bimodal — most deep merges damp much harder, a small tail moves
more; p90 improves).

**Reflow-rotation (89 merges) — the regime where a too-generous scale
would turn damping into lag:** per-block is within 0.12 px of median-scale
at shallow bands and identical at n6-10/n11+ (2.56/4.17 px), pconf 0.979
vs 0.982. No lag regression. (Legacy reference on the same capture: ~10
px/merge at every depth.)

**Every other shape:** bit-identical (deterministic-rect regimes are
scale-invariant) or within noise (short-chain scroll captures: identical
displacement to 2 decimals, pconf −0.004).

## Reading the choice

On uniform streams the two bases coincide (the #58 3× sweep calibration
transfers unchanged — CI's pinned uniform-fixture numerics did not move).
They diverge exactly where the median is polluted by mixed heights, which
is the defect class (#75 F2); the cold-region 16 px default (F4) also
disappears — the existing block's own height is always defined and
jitter-stable. Corpus caveat: body-text-dominated; the mixed-height
cross-case is covered by the unit fixture
(`stabilization_engine_position_model_test.dart`, "#75" group) rather
than a dedicated capture.
