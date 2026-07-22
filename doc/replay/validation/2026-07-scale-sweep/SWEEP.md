# Jitter-allowance scale sweep — 2026-07-22/23 (#58, #70, #73)

Provenance for the `_kAgreementJitterAllowance = 3.0` constant
(`lib/src/stabilization_engine.dart`) and the numbers quoted in its doc
comment. Each JSON here is a `tool/replay/replay.dart ab-report` run over a
production consumer capture (JSONL schema: `../../capture_schema.md`), with
the allowance multiplier patched locally per arm.

## Capture shapes

| file | stream shape | source | batches / obs |
|---|---|---|---|
| `stable-dwell.json` | stationary content, micro-scroll oscillation | deterministic layout rects | 60 / 476 |
| `reflow-rotation-1x/3x.json` | physical rotation cycles mid-content (reflow) | deterministic layout rects | 24 / 163 |
| `ocr-jitter-dwell-1x/2x/3x.json` | stationary content, micro-scroll oscillation | OCR-quantized rects (per-frame re-segmentation jitter) | 32 / 414 |

## Result (agreementWeighted arm; legacy reference in each JSON)

| scale | OCR-jitter disp n3-5 / n11+ (px/merge) | OCR pconf mean/p50 | reflow disp n3-5 | reflow pconf mean |
|---|---|---|---|---|
| 1× medianH | 18.0 / 15.8 | 0.22 / 0.05 | 4.6 | 0.77 |
| 2× medianH | 15.9 / 14.0 | 0.23 / 0.06 | 4.5 | 0.83 |
| **3× medianH** | **12.2 / 3.8** | **0.35 / 0.22** | **4.5** | **0.85** |
| legacy | 13.2 / 11.8 | 1.0 (saturated) | 9.3 | 1.0 (saturated) |

The stable-dwell regime is scale-invariant (residuals are numeric residue,
agreement 1.0 at any allowance); its JSON documents the post-#70 baseline:
both arms pconf 1.0, displacement 0.0.

A drift-margin multiplier sweep (1–4×) was bit-identical across all
captures — the margin branch was unreachable (median-of-drift ≈ 0 under
symmetric jitter, sub-floor residue when stable), which is why #73 deleted
it rather than retuned it.

## Reading the choice

At 1×, the typical jitter residual equals the scale, so agreement ≈ 0 and
confidence collapses; the confidence-anchored merge weight then loses its
anchoring exactly under jitter (deep chains chased at 15.8 px/merge, worse
than legacy). At 3× the loop engages: deep-chain jitter damps to 3.8 px/merge
while confidence stays regime-discriminating (~1.0 / 0.85 / 0.35) instead of
legacy's saturated-flat 1.0.

**Caveat:** calibrated against one OCR engine's residual distribution
(re-segmentation-dominated, 30–45 px effective residuals). Re-run this sweep
before trusting the constant for a different OCR engine or a mixed-engine
stream. Full narrative: issue #58 comments, 2026-07-22/23.
