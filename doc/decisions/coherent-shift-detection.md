# Coherent-shift detection — design history

Source: `lib/src/internal/coherent_shift_detector.dart` (extracted from
`StabilizationEngine` in #150; behaviour pinned byte-identical by the
differential replay harness). The engine's `stabilize` runs a dry,
primary-match-only pre-pass and hands its results to
`CoherentShiftDetector.detect`; see `stabilize`'s doc for why that
pre-pass is safe to run ahead of the capture's merges.

This page keeps the *why* that used to sit above the code. Issue numbers
are the package's own.

## Why the position model gates it (#116)

`PositionMergeModel.legacy` has no residual/scale concept to detect
"moved" against, so the engine never asks the detector for a plan under
legacy — a documented no-op (see `StepResponse`). The differential arm
`legacyCoherent` pins that gate.

## Finding B — order-independent clustering (2026-08-29 rewrite)

The original algorithm sorted moved pairs by `dy` ALONE and ran a single
greedy pass with an incremental running median. Two pairs with equal or
near-equal `dy` had no secondary sort key, so which one a greedy scan
visited first — and therefore which running-median state a later
candidate was compared against — depended on the order fresh blocks
arrived in, not on their values. Replacement: a deterministic total
order over VALUES — `(dy, dx, existing.top, existing.left, height)`,
original index last as an always-harmless final tiebreak (two
value-identical pairs always land in the same window regardless of their
relative order) — then a search of every contiguous window of that
order, LARGEST size first, for one whose members are all within
`tolerance × min(member's own height, the window's OWN median height)`
of the window's OWN median displacement (both axes, Euclidean),
validated against the window's FINAL membership, never an incremental
running state. The first (largest, then leftmost-start) valid window
wins; ties within a size resolve to the same window every time because
the search is a fixed, deterministic sweep. This is one reasonable
instantiation of the spec's pairwise "smaller block height" tolerance
for a group-vs-candidate comparison; see the #116 PR description for the
alternatives weighed. Pinned by
`test/stabilization_engine_coherent_shift_order_independence_test.dart`.

## Finding C — the frozen drift snapshot

Each accepted member's `driftTracker.medianDriftForKey(spaceKey)` — the
SAME value used to compute its "moved" displacement and, transitively,
the group's translation — is captured into the returned map alongside
membership. The engine threads it back into that member's real merge as
`frozenRegionDrift`, so the translation the detector votes on and the
residual/`driftCorrection` that merge reports are always read from ONE
snapshot. Without this, the merge's own step 2 would recompute
`medianDriftForKey` LIVE against a tracker already mutated by any
earlier same-capture merge in the real interleaved loop — which member
merges first (and therefore whether the space key has crossed the
tracker's 3-observation floor by the time a given member's merge runs)
depends on arrival order, so the reported residual/confidence could
silently diverge across otherwise-identical orderings even though the
vote itself (fixed by finding B) does not. One map carries both
membership and the snapshot: two parallel collections built from the
same loop could fall out of sync under a later edit, and a missing key
would silently fall back to a live tracker read with nothing red.

The map is identity-keyed like every other `T` collection in the
engine: `T` is the CONSUMER's type and may define VALUE equality (an
Equatable-style block keyed on `originalText` only). Two members that
are `==`-equal but sit in DIFFERENT drift regions must each keep their
OWN snapshot; a value-keyed map collapses them onto one entry. Pinned by
`test/stabilization_engine_coherent_shift_identity_test.dart` and
`test/stabilization_engine_coherent_shift_frozen_drift_test.dart`.

## Finding E — the force-unwraps

`RobustStats.median` returns null ONLY on an empty list. Every window
the quorum searches has `size >= minBlocks`, and the engine rejects
`minBlocks < 1` at construction, so the two unwraps on the quorum path
can never fire; the same argument covers both fallbacks (`minN >= 1`;
a size-1 window always validates). The `searchWindow` null check on the
three medians is explicit non-null handling for the empty-window case
that `size >= minSize >= 1` already excludes.

## #119 — the absolute-pixel floor fallback

Tried ONLY where the ordinary quorum declines (all three of its decline
points route here), so enabling the floor cannot perturb any capture the
quorum already handles. The discriminating axis is absolute pixels
rather than another multiple of the block's own height: see
`ExperimentalCoherentShiftOptions.floorPx` and
`doc/COHERENT_SHIFT_CALIBRATION.md` for the calibration recipe. Two
agreement checks: direction per axis (a slab translates its content ONE
way; sub-epsilon components — real corpus movers report `-0.0` and
`0.1` dx on a purely vertical slab — carry no direction, so a group
agreeing on the axis that moved is not broken up by the other one), then
magnitude (PR #129 review C1/C5: direction alone let a +35 px mover be
re-anchored by a +110 px group median — 37.5 px PAST its own
observation, worse than damp — and let a purely horizontal and a purely
vertical mover "agree" and drag each other diagonally). Magnitude reuses
the quorum's clustering at a minimum size of ONE, so a lone mover is its
own cluster — the starved-quorum case this path exists for — and only
the winning cluster is re-anchored.

## #119 — the batch-level re-anchor

The other axis the starved quorum could be relaxed on: keep the tolerance
clustering, drop the SHARE gate outright, lower only the COUNT required
to act, then apply the winning cluster's median displacement to its own
members alone. No magnitude axis at all, which is precisely what
distinguishes it from the floor. Tried after the floor, so a consumer
that sets both gets the magnitude-gated answer first. Documented
not-recommended; see the calibration page.

## #119 item 2 — adopting the agreeing under-gate pairs

Once a plan is decided — by the quorum or either fallback — the eligible
pairs that sat UNDER the "moved" gate but whose displacement is within
the quorum's tolerance (`tolerance × min(own height, the group's median
height)`) of the decided translation join the plan. They are members of
the MERGE, not of the vote: their displacement never entered the
translation's median. The snapshot rule is the same for them. The
adoption step runs after the ordering computation (which is pure), so
the quorum path's behaviour is unchanged by where it sits. Measured
effect on the reflow corpus (pushdown-150 lag 68 → 6 px, all other
streams byte-identical) is in
`doc/replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md`. The
own-height half of the `min()` is pinned separately: every earlier
fixture had the adoptee TALLER than the median, so a mutant to
group-median-alone survived until a shorter-adoptee fixture was added
(PR #132 review).
