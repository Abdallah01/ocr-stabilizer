# Batch-size benchmarks — 2026-08-24 (#97)

`dart run benchmark/stabilize_benchmark.dart` on an Intel Core Ultra 9
275HX, Dart 3.12.2 (JIT, windows_x64). Median of 20 seeded runs
(stabilize) / 15 runs (grouping); the harness does a VM-wide JIT warmup
first, so "cold" measures a fresh engine, not compiler startup, and both
stabilize paths build their fixtures outside the timed region. See the
script header for the exact method.

| batch | stabilize cold | stabilize warm (median/capture) | group (median) |
|---|---|---|---|
| 25 | 1.2 ms | 3.9 ms | 27 µs |
| 50 | 649 µs | 7.4 ms | 61 µs |
| 100 | 1.1 ms | 14.2 ms | 82 µs |
| 250 | 2.7 ms | 36.5 ms | 171 µs |
| 500 | 4.5 ms | 77.2 ms | 372 µs |
| 1000 | 9.2 ms | 154.7 ms | 640 µs |
| 2000 | 19.0 ms | 343.3 ms | 1.3 ms |

## Reading

- **Warm (steady-state re-observation) is the expensive path** and scales
  near-linearly at ~145–175 µs per block from 50 blocks up: the cost is
  dominated by text similarity against each block's spatial candidates,
  not by the index lookup itself.
- **Cold (first sighting) is ~10 µs per block** at scale — no candidates
  to compare against yet. The sub-100 cold rows are dominated by
  small-batch fixed overhead (the 25 row costs more in absolute terms
  than the 50 row), so per-block arithmetic is meaningless there.
- **Grouping is two orders of magnitude cheaper** than stabilization at
  every size (~0.7–1 µs per block; the Otsu pass's gap sort is the only
  super-linear term and it does not show at these sizes).
- **The package's real regime is measured directly**: at 25–50 blocks per
  capture — the typical page the engine actually sees, and the band the
  long-session replay test's fixture models (≤54 visible lines) — the
  whole stabilize+group path is **~4–8 ms per capture** on this desktop
  CPU. Comfortable headroom against a 1–2 Hz capture cadence, with the
  usual caveats: JIT desktop numbers, not AOT-on-phone numbers — treat
  the scaling shape as transferable, not the absolute milliseconds.

## Soft budget

500 warm blocks under **150 ms** on a desktop-class CPU (measured: 77
ms). A regression past this on comparable hardware deserves a look at
the matching path before merging. This is a review aid, not a CI gate —
CI runners vary too much for a hard wall-time assert; re-run the
benchmark locally when touching `stabilization_engine.dart` matching or
`paragraph_grouper.dart` and update this file if the shape changes.
