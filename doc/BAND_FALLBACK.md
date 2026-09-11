<!-- Relocated from README.md in #144 (2026-09-08): the README keeps the
     quick start; reference material lives here. Content unchanged. -->

# BandFallback: the band-relaxed matching path

OCR jitter — one character flipped or one ligature mis-segmented — can drop a
stable block below the primary text-similarity floor for a single frame.
`BandFallbackConfig` opens a relaxed second-pass match path so spatially-
unambiguous blocks don't "blink off and back on."

```dart
final engine = StabilizationEngine<DefaultTrackedBlock<MyPayload>, MyPayload>(
  merger: (existing, fresh, merge) => existing.applyMerge(merge),
  // Opt in: start in observeOnly to read counters, then flip to admit.
  bandFallback: const BandFallbackConfig(mode: BandFallbackMode.observeOnly),
);

// After a few captures, inspect the counters before flipping to admit.
// Note: in admit mode, once a band candidate is locked for a fresh
// observation, subsequent candidates skip band evaluation — so
// candidatesConsidered is mode-variant (observeOnly will show a higher
// figure). The funnel terms (rejectedCandidateFloor + rejectedSpatial
// + rejectedTextBand + bandMatchesIdentified == candidatesConsidered)
// are themselves mode-invariant — every term ticks before the
// early-exit fires.
final s = engine.bandStats;
print('primary admits=${s.primaryMatchesAdmitted}, '
      'primary misses=${s.primaryMatchesRejected}, '
      'candidates considered=${s.candidatesConsidered}, '
      'band would-admit=${s.bandMatchesIdentified}, '
      'rejected obs-floor=${s.rejectedCandidateFloor}, '
      'rejected spatial=${s.rejectedSpatial}, '
      'rejected text-band=${s.rejectedTextBand}, '
      'matches admitted=${s.matchesAdmitted}');
```

Recommended adoption flow for callers that want band coverage: ship with
`off` (the default — a `^0.5.0` upgrade is a no-op), switch to
`observeOnly` to read the counters in production, then flip to `admit`
once the ratios justify it. Staying on `off` permanently is also valid —
it disables the band path entirely and pays no extra cost.
