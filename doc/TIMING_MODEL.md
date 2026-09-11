<!-- Relocated from README.md in #144 (2026-09-08): the README keeps the
     quick start; reference material lives here. Content unchanged. -->

# Timing model

The contract is **render at first sight, refine on re-sight** — observation
counts are evidence depth, never a readiness ladder:

- `stabilize()` returns first-sighting blocks in
  `StabilizationResult.stableBlocks` on the very call that observed them.
  Nothing is withheld while evidence accrues, and nothing anywhere gates
  availability on time (the classifier reads a clock only for a
  capture-freshness term feeding position confidence).
- `observationCount` and the chain-depth bands in the validation tables
  (n1-2 … n11+) describe how much an **already-displayed** block's box moves
  per *re*-observation. Deep bands are the steady-state for blocks that stay
  in view (a user dwelling on a paragraph — where captures keep re-observing
  them); blocks scrolled past live their whole life at shallow depth, which
  is normal and costs nothing.
- `StabilizationResult.wellObservedTexts` fires from the **3rd**
  observation onward. It is a hint that a translation can be cached
  long-term — not a display gate.
- The refinement supply is demand-coupled: re-observations and jitter both
  come from captures (regional drift propagation included — it is sourced
  from neighbors' re-observations, never a timer). A stream that produces
  no re-observations also produces no wobble to damp; whenever the wobble
  exists, so does the evidence that suppresses it.
