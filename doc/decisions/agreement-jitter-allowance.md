# The agreement jitter allowance — why 3× the block's own height

Source: `kAgreementJitterAllowance` in `lib/src/internal/block_geometry.dart`
(moved out of `StabilizationEngine` in #150). Used by the
agreement-weighted merge's confidence computation, `StepResponse.snap`'s
threshold and the coherent-shift "moved" gate — all through one
`agreementScale` function.

## Why the block's own height (#75)

Through 1.0.x the scale was the region's median block height. A pooled
median gets polluted by small siblings (a caption's height says nothing
about how much a paragraph may jitter) and cold regions fell to the
16 px height default. The existing (tracked) block's height is
jitter-stable and needs no default: tolerance proportional to the
block's own text size.

## Why not the drift margin

`driftMarginForKey` is a *median-of-drift* — a systematic-offset
measure, ~0 under symmetric jitter and sub-floor numeric residue on
stable streams — so a margin-derived scale is dead or poisonous in
every sampled production regime (#58, #70, #71). A spread measure (MAD
of drift residuals, see `RobustStats`) is the documented option if a
drift-adaptive scale is ever wanted; note #72 (the `madOrFallback`
floor) becomes load-bearing first.

## Why 3

Sweep-validated on production captures (#58, 2026-07-22): at 1×,
deep-chain OCR jitter is chased at 15.8 px/merge (worse than legacy's
11.8); at 3× the confidence→weight anchoring loop engages and damps it
to 3.8 px/merge, while confidence stays regime-discriminating (~1.0
stable / 0.85 reflow / 0.35 heavy jitter — never saturated-blind like
legacy). The 3× multiplier carried over unchanged to the per-block base
(#75, 2026-07-24): on uniform streams the two bases coincide (the
sweep's calibration transfers), and the six-capture validation showed
per-block ~30–60 % better established-chain damping under OCR jitter
with every other regime within noise
(`doc/replay/validation/2026-07-perblock-scale/`).

## Transfer across OCR engines (#94)

Calibrated against ML-Kit-shaped noise; re-run the sweep
(`tool/replay` ab-report) before trusting it for a different OCR
engine's residual distribution. The cross-engine matrix (Tesseract 5 and
PaddleOCR, synthetic low-amplitude corpora, 2026-08) shows the default
TRANSFERS without retuning in the photometric-jitter regime —
established-chain damping and regime-discriminating confidence
replicate on both. The high-amplitude re-segmentation regime remains
ML-Kit evidence, now including a committed on-device stream
(`doc/replay/validation/2026-08-mlkit-on-device/`). All entries live
under `doc/replay/validation/`.
