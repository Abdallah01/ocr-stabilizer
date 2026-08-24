# Batch-size benchmarks — 2026-08-24 (#97)

`dart run benchmark/stabilize_benchmark.dart` on an Intel Core Ultra 9
275HX, Dart 3.12.2 (JIT, windows_x64). Median of 20 seeded runs
(stabilize) / 15 runs (grouping); the harness does a VM-wide JIT warmup
first, so "cold" measures a fresh engine, not compiler startup. See the
script header for the exact method.

| batch | stabilize cold | stabilize warm (median/capture) | group (median) |
|---|---|---|---|
| 100 | 4.0 ms | 15.3 ms | 105 µs |
| 250 | 2.5 ms | 36.6 ms | 220 µs |
| 500 | 5.0 ms | 77.8 ms | 334 µs |
| 1000 | 9.4 ms | 157.5 ms | 699 µs |
| 2000 | 18.5 ms | 350.8 ms | 1.4 ms |

## Reading

- **Warm (steady-state re-observation) is the expensive path** and scales
  near-linearly at ~155–175 µs per block: the cost is dominated by text
  similarity against each block's spatial candidates, not by the index
  lookup itself.
- **Cold (first sighting) is ~10 µs per block** — no candidates to
  compare against yet. The 100-row's 4.0 ms is small-batch fixed
  overhead, not a scaling effect (the 250 row is cheaper in absolute
  terms).
- **Grouping is two orders of magnitude cheaper** than stabilization at
  every size (~0.7 µs per block; the Otsu pass's gap sort is the only
  super-linear term and it does not show at these sizes).
- At the package's real regime — tens of blocks per capture at 1–2 Hz —
  the whole stabilize+group path is **~2–5 ms per capture**, far below
  the capture budget.

## Soft budget

500 warm blocks under **150 ms** on a desktop-class CPU (measured: 78
ms). A regression past this on comparable hardware deserves a look at
the matching path before merging. This is a review aid, not a CI gate —
CI runners vary too much for a hard wall-time assert; re-run the
benchmark locally when touching `stabilization_engine.dart` matching or
`paragraph_grouper.dart` and update this file if the shape changes.
