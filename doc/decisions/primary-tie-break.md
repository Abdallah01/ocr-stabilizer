# Primary matching tie-break (#143)

**Where:** `lib/src/internal/block_matcher.dart`, `BlockMatcher.find` →
`_prefersOnTie`, and `BlockMatcher.beginCapture` (called once per capture
by `StabilizationEngine.stabilize`, after batch dedup and before the dry
pre-pass).

## The gap

The primary check keeps the candidate with the highest Levenshtein score
(Jaccard is admission-only). Before #143 the comparison was a strict `>`,
so two candidates with the SAME score — repeated headings such as
"Chapter 4", duplicated labels, a churned line that is one edit away from
two cached variants — resolved to whichever the spatial index yielded
first: the 3×3 neighbourhood in a fixed cell order, insertion order within
a cell. Reproducible run to run, but an artefact, not a decision.

## What was measured before choosing

An earlier attempt (2026-09-08, on the pre-#150 engine) tried "nearest raw
centre" and reverted it: 12 committed replay tests went red, among them a
control stream whose "max lag delta vs coherent" went from 0.000 to
12.754 px. That was read as the rule being wrong under scroll, because the
cached rect lags the learned drift.

Re-measured on 2026-09-11 with the #150 differential harness (21 streams ×
11 arms, a per-capture digest of the whole engine state) and a probe that
records every exact tie in the real pass together with what three rules
would pick:

| stream | ties | raw-nearest flips | drift-corrected flips | raw ≠ drift |
|---|---|---|---|---|
| dynamic-reflow/rewrap | 5 | 2 | 2 | 0 |
| dynamic-reflow/variants/pushdown-600 | 78 | 61 | 61 | 0 |
| dynamic-reflow/variants/pushup-300 | 11 | 11 | 11 | 0 |
| paddleocr-matrix/scroll | 77 | 44 | 44 | 0 |
| the other 17 streams | 0 | 0 | 0 | 0 |
| **total** | **171** | **118** | **118** | **0** |

Two things fell out of that:

1. **The 2026-09-08 "control regressions" were artefacts of mixing rules.**
   The `#119` control tables compare the COMMITTED coherent arm (old rule)
   against a LIVE floor-390 replay (new rule). Once both `.ab.json` and
   `.diff.json` were regenerated under one rule, every control row read
   `0.000 px` again and the ship rule's worst regression was back to
   `0.000 px`. Nothing on a control stream got worse.
2. **Drift correction changes no decision on this corpus** (raw ≠ drift:
   0 of 171), because a tie's candidates are far apart compared with the
   learned drift (clamped to one median block height). The drift-aware
   form is still the one shipped: it is the same correction the merge
   applies, so the tie-break and the merge agree on what "near" means,
   and a unit test pins the case the corpus cannot reach (a learned drift
   that flips the nearer candidate).

## The rule

For candidates with an equal text score, a strict total order:

1. nearer to the fresh block's **drift-corrected** centre
   (`fresh.center − snapshot[spaceKey(fresh)]`) wins;
2. at equal distance the smaller rect key `(top, left, right, bottom)`
   wins;
3. two cached blocks with the same text AND the same rect cannot coexist
   (batch dedup), so step 2 always separates them in practice.

`beginCapture` snapshots `DriftTracker.medianDriftForKey` for every fresh
block's space key BEFORE the capture's merges. The dry pre-pass (#116)
and the real loop both read that map, so the primary check stays a
function of this-capture-immutable state — the invariant #116 needs — even
though the tie-break is drift-aware. A drift learned during the capture
is visible to the NEXT capture's tie-breaks only.

## What moved, and which way

Only the four streams with ties changed; the other 17 (and all four zoom
streams) are byte-identical under all 11 harness arms.

| what | before | after |
|---|---|---|
| `pushdown-600` damp lag move / +3 / +5 (px) | 30.7 / 26.1 / 14.5 | 30.7 / 14.8 / 3.7 |
| `pushdown-600` floor-390 lag move / +3 / +5 (px) | 1.4 / 20.7 / 12.4 | 1.4 / 13.2 / 2.8 |
| `pushup-300` damp lag move / +3 / +5 (px) | 155.1 / 92.7 / 67.3 | 155.1 / 96.7 / 70.0 |
| `paddle-scroll` snap step events (control) | 5 | 1 |
| re-anchor count 1: control step events in total | 17 | 11 |
| paddle `scroll` agreement displacement n3-5 (px) | 1.08 | 0.62 |
| seed-21 `tess-scroll` control: largest firing floor | 208 | < 200 (never fires) |
| seed-93-r2 `pushdown-600` damp +3 / +5 (px) | 15.9 / 22.8 | 3.4 / 14.0 |
| 900-capture long-session steady-state population | 116 / 112 (period 2) | 120 / 115 / 119 / 114 (period 4) |

`pushup-300` is the one stream that moved slightly the wrong way at +3/+5
(about 4 px on lags of 90–100 px); its step-rule verdicts are unchanged.
The `pushdown-600` snap verdict flipped PASS → FAIL only because the rule
is "half of damp" and damp itself improved from 26.1 to 14.8 px at +3.
The long-session population is bounded and periodic, at a period of four
passes instead of two; the leak detector in
`test/long_session_replay_test.dart` was widened to that period and
documents the measured cycle.

## What pins it

- `test/block_matcher_test.dart` "#143 primary tie-break": nearer wins in
  both insertion orders; a higher text score still beats a nearer
  candidate; the drift-corrected case with the snapshot semantics; the
  equal-distance rect-key case in both insertion orders.
- `test/replay/differential_committed_test.dart`: the regenerated
  `.diff.json` references (a tie-break mutant — farther wins — goes red on
  the four tie streams).
- The experiment tables in `doc/replay/validation/*/EXPERIMENT.md`, held
  to live replays by `test/replay/experiment_doc_*_test.dart`.
