<!-- Relocated from README.md in #144 (2026-09-08): the README keeps the
     quick start; reference material lives here. Content unchanged. -->

# Calibrating `coherentShiftFloorPx`

The floor admits a single surviving mover to the coherent-shift vote on its
own magnitude — the fix for slabs so large that too few matched movers
survive for the quorum to see. It is **a property of your capture
geometry, not a universal constant**, which is why it ships `null`
(disabled, always safe) instead of with a default:

1. **Lower bound:** measure the largest displacement ORDINARY scrolling
   produces between two consecutive captures on your device and capture
   cadence (replay your own captures, or read the largest per-frame move
   on a scroll-only session). The floor must sit ABOVE it, or scroll
   fires step events. On the validation corpus this bound is 377 px on
   the published streams (the tesseract-matrix scroll control's largest
   step); across the eight seed / noise configurations of the #136 entry
   it spans 220–377 px on the seven that measure it (one sits below the
   200 px search floor).
2. **Upper bound:** the smallest single-frame slab you need tracked. The
   floor must sit BELOW the displacement such a slab leaves on its
   surviving mover — 406 px on the published page's 600 px slab,
   240–406 px where a mover survives at all — and on two of the four
   synthetic pages the window is empty: on one no mover survives at any
   floor from 200 up, on the other the survivor (240 px) sits below that
   page's own scroll ceiling (359–364 px).
3. Pick inside the window and re-run your controls: the corpus ships at
   390 px with 0 step events on all 10 control streams (and on all 32
   control replays of the #136 entry) and the published page's 600 px
   slab's lag cut 30.7 -> 1.4 px; on the other three synthetic pages
   390 is a safe no-op — never inside their window, never firing. No
   single floor is inside every page's window, which is why this is a
   recipe and not a default. A consumer capturing less often, or
   scrolling faster, needs a HIGHER floor (ordinary between-capture moves
   are bigger); if your window is empty — your scrolling moves farther
   per capture than your smallest slab — leave it `null`.

A height-relative multiplier provably cannot replace this calibration: on
the corpus a scroll control reaches 3.63x its own scale while the real
slab's mover travels at only 2.64x, so NO multiplier admits one without
the other. Full derivation and the sensitivity table:
`doc/replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md`.
