<!-- Relocated from README.md in #144 (2026-09-08): the README keeps the
     quick start; reference material lives here. Content unchanged. -->

# Observing the engine's decisions

Since 2.5.0 every `StabilizationResult` carries two read-only summaries
of what the engine decided this capture, so a layout layer above the
engine can react without reverse-engineering `stableBlocks`:

```dart
final result = engine.stabilize(blocks);

final shift = result.coherentShift; // CoherentShiftEvent?
if (shift != null) {
  // The tracked content moved as a slab. Move any geometry you cache
  // OUTSIDE the engine for these identities by the same vector.
  overlay.translateAll(shift.translation);
  log('shift ${shift.decidedBy.name} ${shift.translation} '
      'members=${shift.memberCount} adopted=${shift.adoptedCount}');
}

final t = result.identityTurnover; // IdentityTurnover
final leftBehind = t.dropped + t.retained; // cached identities nothing matched
if (shift == null && leftBehind > 0 && t.admittedShare >= 0.5) {
  // Most fresh blocks are NEW identities, cached identities were left
  // unmatched, and nothing moved as a slab: the line boxes changed under
  // the same content (a font swap, a width change that rewraps). The engine reset
  // identity on purpose (contract U1). Cached geometry for the old
  // identities is stale — rebuild it rather than translate it.
  overlay.rebuildFrom(result.stableBlocks);
}
```

Reading rules:

- `coherentShift` is the coherent PLAN, counted at the merges that
  actually applied it: `memberCount` equals the number of
  `MergeResult.stepResponseApplied == coherentShift` your merger saw
  this capture. It is `null` on every capture where no plan was decided —
  every control capture, and always under `StepResponse.damp` / `snap`
  (snap re-anchors per block and reports only through `MergeResult`).
- `decidedBy` names the path: `quorum` (the majority vote), `floor`
  (`coherentShiftFloorPx`), `reanchor` (`coherentShiftReanchorMinBlocks`).
  `floor` events during ordinary scrolling mean the floor sits inside
  your scroll range — recalibrate it (recipe above).
- `identityTurnover.fresh` can be smaller than the batch you passed:
  intra-batch NMS removes duplicates first, and a nested fragment whose
  host already merged this capture is folded into that merge.
- The `leftBehind > 0` guard keeps a session's FIRST sighting (every
  block new, nothing cached) from reading as a rewrap. The 0.5 share is a
  starting point, not a calibrated constant: on the dynamic-reflow
  validation corpus the rewrap frame admits 23 of 30 lines (0.77) and the
  next frame merges 29 of 30, while a stationary re-sighting sits near
  0.0. Calibrate on your own captures.

Since 2.6.0 a third summary reads the capture's matched pairs as ONE
similarity transform — for the zoom `coherentShift` cannot model:

```dart
final z = result.transformEstimate; // TransformEstimate? (null under 3 pairs)
if (z != null &&
    (z.scale - 1).abs() >= 0.10 &&
    z.residualPx <= 10 &&
    z.largestGapShare <= 0.5 &&
    z.pairCount >= 6) {
  // The matched lines moved as one scale about one point — a zoom. The
  // engine did not rescale anything (contract U9): rescale the geometry
  // you hold outside it about the zoom origin, then let it converge.
  overlay.scaleAll(z.scale, about: z.fixedPoint ?? Offset.zero);
}
```

- Read `residualPx` before `scale`: a partial step over a ladder of
  lines also fits as a scale (0.18–0.22 on the corpus's 300 px slabs)
  but with a 58–87 px residual, a zoom with a residual of a few px.
  `spanPx` is the lever arm the scale was estimated over
  (`residualPx / spanPx` is its uncertainty).
- Read `largestGapShare` before trusting a small residual: when the
  matched lines form TWO CLUSTERS (two paragraphs, nothing matched
  between them — or a step whose boundary pairs the trim set aside), a
  translation of one cluster and a zoom about a point fit the same
  pairs equally well, and the residual is only the spread inside each
  cluster. Near 1 the estimate cannot tell them apart; the bound above
  refuses it. The four bounds are the zoom corpus entry's, with its
  margins table as their justification.
- The captures AFTER a zoom event read 0.92–1.08 with large residuals:
  the merged blocks are being damped toward the new geometry while the
  newly admitted ones already sit at it. The residual bound refuses
  them; rescale once, at the event capture.
