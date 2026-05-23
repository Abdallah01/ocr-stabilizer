# v0.4.0 — Band-Fallback Inter-Batch Matching + `qualityScore` NaN Guard

**Status:** Approved. Ready for implementation planning.
**Date:** 2026-05-23
**Repository:** `ocr-stabilizer` (community-facing Dart package).
**Release target:** `0.4.0`.
**Closes:** [#27](https://github.com/Abdallah01/ocr-stabilizer/issues/27), [#20](https://github.com/Abdallah01/ocr-stabilizer/issues/20).

---

## 1. Scope

Three PRs land on `main` in order, after which the maintainer publishes 0.4.0
to pub.dev. No other features ride along.

| # | Branch                             | Issue | Net effect                                                                                            |
|---|------------------------------------|-------|-------------------------------------------------------------------------------------------------------|
| 1 | `fix/27-quality-score-nan-guard`   | #27   | `qualityScore` returns `0.0` on NaN input; `DefaultTrackedBlock` rejects NaN/out-of-range confidence. |
| 2 | `feat/20-band-fallback`            | #20   | Optional band-relaxed fallback in `_findMatch`, gated by a default-off config + stats.                |
| 3 | `chore/release-0.4.0`              | —     | CHANGELOG header + `pubspec.yaml` version bump.                                                       |

Out of scope (deferred to a later release):

- Tuning the band thresholds against real-corpus data. Default config ships
  `enabled: false` precisely so consumers can opt in and measure first
  ([feedback_instrument_before_phone_investigation](https://github.com/Abdallah01/ocr_translate_demo/) pattern).
- App-side adoption (`ocr_translate_demo`). The app keeps consuming 0.3.x
  until 0.4.0 is on pub.dev; the unblock PR there lands separately under
  [#1084](https://github.com/Abdallah01/ocr_translate_demo/issues/1084).

---

## 2. Design principles (locked in this session)

1. **Community-facing first.** Every numeric or behavioral knob the app's
   pipeline exposes implicitly must become an explicit parameter so other
   consumers can deviate. Defaults reflect the app's proven choices because
   the app is the most-tested reference.
2. **App-pattern parity for defaults.** Where the in-repo app
   (`c:/src/ocr_project`) already solves the same problem, the package's
   default value matches the app's value verbatim and the spec cites the
   line. See
   [feedback_check_app_first_for_package_design](file:///C:/Users/Ad_88/.claude/projects/c--src-ocr-project/memory/feedback_check_app_first_for_package_design.md).
3. **Non-negotiable invariants enforced at the constructor.** Anything the
   app proves shouldn't be optional must `throw` (not `assert`) on
   construction, in the established style of `DefaultTrackedBlock`'s
   `containerId` check at [default_tracked_block.dart:142-150](../../lib/src/default_tracked_block.dart#L142-L150).
4. **Non-generic predicate signatures.** New predicate types mirror the
   existing `ContextualInvalidationCheck` shape — `bool Function(TrackedBlock,
   TrackedBlock)` — for consistency with the engine's existing seam. No
   speculative generics.
5. **Default OFF for new fuzzy admission paths.** A band-relaxed match is a
   strictly more permissive matcher; ship with the flag off and stats on so
   consumers see candidate volume before flipping.

---

## 3. PR 1 — #27 `qualityScore` NaN guard

### Problem

`OverlapResolver.qualityScore` at [overlap_resolver.dart:176-177](../../lib/src/overlap_resolver.dart#L176-L177)
multiplies and sums two `Confidence.raw` values. If either is `NaN` the
score is `NaN`, which silently poisons `OverlapResolver.resolveOverlap`'s
quality comparison (NaN compares false against every double). The block
that "loses" the comparison is chosen arbitrarily by sort stability.

#19 fixed the upstream entry points (`PositionConfidence.from` /
`TextConfidence.from` reject NaN), but two gaps remain:

- **Direct `DefaultTrackedBlock` construction** bypasses the `.from()`
  factories — a consumer can still build a block with a hand-rolled
  `Confidence(NaN)` and slip past the gate.
- **Defense in depth:** if a future code path constructs `Confidence`
  directly, `qualityScore` should fail safe rather than silently NaN.

### Solution — Option C: both A and B

**A. `qualityScore` defensive return.** When either component is NaN,
return `0.0`. The block sinks to the bottom of the NMS comparison rather
than poisoning it.

```dart
static double qualityScore(TrackedBlock block) {
  final pos = block.positionConfidence.raw;
  final txt = block.textConfidence.raw;
  if (pos.isNaN || txt.isNaN) return 0.0;
  return pos * 0.4 + txt * 0.6;
}
```

**B. `DefaultTrackedBlock` constructor invariant.** Throw `ArgumentError`
when `positionConfidence.raw` or `textConfidence.raw` is NaN or outside
`[0.0, 1.0]`. Mirrors the existing `containerId` `throw` block at
[default_tracked_block.dart:142-150](../../lib/src/default_tracked_block.dart#L142-L150)
verbatim in style.

```dart
if (positionConfidence.raw.isNaN ||
    positionConfidence.raw < 0.0 ||
    positionConfidence.raw > 1.0) {
  throw ArgumentError.value(
    positionConfidence.raw,
    'positionConfidence',
    'must be a finite double in [0.0, 1.0]',
  );
}
// (same shape for textConfidence)
```

Why `throw` over `assert`: storage/state-owning classes need production
enforcement; asserts strip in release mode. See
[feedback_assert_vs_throw_in_storage](file:///C:/Users/Ad_88/.claude/projects/c--src-ocr-project/memory/feedback_assert_vs_throw_in_storage.md).

### TDD sequence

1. **Red** — add `quality_score_nan_test.dart`:
   - block with `positionConfidence.raw = NaN` → expect `qualityScore == 0.0`.
   - block with `textConfidence.raw = NaN` → expect `qualityScore == 0.0`.
   - block with both NaN → expect `0.0`.
   - sanity: block with both 1.0 → expect `1.0`.
2. **Green** — add the `isNaN` guard in `qualityScore`. Run target test.
3. **Red** — add `default_tracked_block_confidence_invariant_test.dart`:
   - `DefaultTrackedBlock(... positionConfidence: Confidence(double.nan) ...)`
     → expect `ArgumentError`.
   - same for `textConfidence`.
   - same for `Confidence(-0.1)` and `Confidence(1.1)` on each.
   - sanity: `Confidence(0.0)` and `Confidence(1.0)` construct successfully.
4. **Green** — add the constructor throws. Run target tests.
5. **Refactor** — extract a private `_validateConfidence(name, value)`
   helper inside `DefaultTrackedBlock` to keep the two checks DRY.
6. **Full suite** — run `flutter test` once; commit.

### Commit shape

Single commit, message:

```
fix(overlap): #27 qualityScore returns 0.0 on NaN; reject NaN/out-of-range Confidence in DefaultTrackedBlock

Closes #27
```

### CHANGELOG entry

```markdown
### Fixed
- `OverlapResolver.qualityScore` returns `0.0` when either confidence
  component is `NaN` instead of propagating `NaN` into the NMS comparison
  (#27).

### Changed
- **Breaking:** `DefaultTrackedBlock` constructor throws `ArgumentError`
  when `positionConfidence.raw` or `textConfidence.raw` is `NaN` or
  outside `[0.0, 1.0]`. Consumers already going through
  `PositionConfidence.from()` / `TextConfidence.from()` (the documented
  entry points, validated since #19) are unaffected (#27).
```

---

## 4. PR 2 — #20 Band-fallback inter-batch matching

### Problem

`_findMatch` at [stabilization_engine.dart:293-312](../../lib/src/stabilization_engine.dart#L293-L312)
rejects any candidate whose `normalizedLevenshtein` score is below 0.70.
On real captures, OCR jitter (one character flipped, one ligature
mis-segmented) reliably drops a stable block below the floor for one
frame, even when the spatial position is unambiguous. The block then
respawns rather than merging, which the user observes as the overlay
"blinking off and back on."

The 0.70 floor stays sound as a *high-confidence* match. The fix is a
*band-relaxed* fallback: when no candidate clears 0.70, look at
candidates whose text similarity is in a lower band AND whose spatial
position confirms the match independently. Admit such a match as
**provisional** so it gets a few frames to prove itself before influencing
drift, and so misreads self-clean.

### Approach summary

```
_findMatch(fresh, candidates):
    primary = first candidate with isTextSimilarWithScores >= primary floors
    if primary != null:
        return primary
    if !bandFallback.enabled:
        return null
    for c in candidates ordered by descending similarity:
        bandStats.candidatesConsidered++
        if c.observationCount < bandFallback.candidateObservationFloor:
            bandStats.rejectedCandidateFloor++; continue
        if !bandFallback.spatialConfirm(fresh, c):
            bandStats.rejectedSpatial++; continue
        if isTextSimilarWithScores(fresh.text, c.text,
                                   levenshtein: bandFallback.bandLevenshteinFloor,
                                   jaccard: bandFallback.bandJaccardFloor):
            bandStats.matchesAdmitted++
            return c  // caller wraps as provisional in _mergeImpl
    return null
```

### Public types

#### `BandFallbackConfig` (new — `lib/src/band_fallback_config.dart`)

Non-generic value type. Lives next to `OverlapResolverConfig`. Exported
from the package barrel.

```dart
/// Configuration for the band-relaxed fallback path inside
/// [StabilizationEngine._findMatch].
///
/// Default is **disabled**; consumers opt in once they have observability
/// on the candidate volume reported by [BandFallbackStats].
@immutable
class BandFallbackConfig {
  /// Master switch for *admitting* band-relaxed matches. When `false`,
  /// no candidate is ever returned through the fallback path, but
  /// [BandFallbackStats.candidatesConsidered] still ticks so consumers
  /// can measure candidate volume before opting in.
  final bool enabled;

  /// Lower Levenshtein threshold for band-relaxed matches.
  /// Range: `[0.0, 0.70)`. The upper bound is exclusive because matches at
  /// `>= 0.70` go through the primary path.
  /// Default: `0.50`.
  final double bandLevenshteinFloor;

  /// Lower Jaccard threshold for band-relaxed matches.
  /// Range: `[0.0, 0.80)`. The upper bound is exclusive because matches at
  /// `>= 0.80` go through the primary path.
  /// Default: `0.60`.
  final double bandJaccardFloor;

  /// Minimum `observationCount` a candidate must have before it can be
  /// considered for band-relaxed admission. Filters first-frame candidates
  /// whose own existence is unconfirmed.
  /// Must be `>= 0`. Default: `2`.
  final int candidateObservationFloor;

  /// `provisionalCapturesRemaining` granted to a freshly band-admitted
  /// match. Must be `>= 1` (reflects [MergeResult]'s invariant that
  /// `isProvisional` implies `provisionalCapturesRemaining > 0`).
  /// Default: `3` — matches `ocr_translate_demo`'s app-side value at
  /// `lib/overlay/services/overlay_cache_service.dart:1603-1604`.
  final int provisionalCaptures;

  /// Predicate that must return `true` before a band-relaxed match is
  /// admitted. Receives the fresh observation and the candidate.
  /// Default: drift-aware spatial overlap (see
  /// [defaultDriftAwareSpatialConfirm]).
  final BandSpatialPredicate spatialConfirm;

  const BandFallbackConfig({
    this.enabled = false,
    this.bandLevenshteinFloor = 0.50,
    this.bandJaccardFloor = 0.60,
    this.candidateObservationFloor = 2,
    this.provisionalCaptures = 3,
    this.spatialConfirm = defaultDriftAwareSpatialConfirm,
  });
  // Constructor body throws ArgumentError on out-of-range values
  // (style mirrors DefaultTrackedBlock).
}
```

Constructor invariants (all `throw ArgumentError.value`):

| Field                       | Range / rule                          |
|-----------------------------|---------------------------------------|
| `bandLevenshteinFloor`      | `[0.0, 0.70)`                         |
| `bandJaccardFloor`          | `[0.0, 0.80)`                         |
| `candidateObservationFloor` | `>= 0`                                |
| `provisionalCaptures`       | `>= 1`                                |

`enabled` and `spatialConfirm` have no invariants beyond type.

#### `BandSpatialPredicate` (new — `lib/src/band_fallback_config.dart`)

```dart
/// Spatial confirmation predicate for a band-relaxed candidate.
/// Signature mirrors [ContextualInvalidationCheck] for consistency with
/// the engine's existing predicate-injection seam.
typedef BandSpatialPredicate =
    bool Function(TrackedBlock fresh, TrackedBlock candidate);
```

Default implementation lives next to the typedef:

```dart
/// Drift-aware overlap-ratio predicate. Mirrors the engine's spatial NMS
/// pattern at [StabilizationEngine._dedup] which uses
/// `overlapRatio(a, b, driftMargin)` from [OverlapResolver].
///
/// Returns `true` when the intersection-over-min-area between `fresh` and
/// `candidate` reaches `0.80`, computed with the candidate's
/// space-keyed drift margin. The 0.80 default matches the app's primary
/// NMS gate at `lib/overlay/services/overlay_cache_service.dart:1573-1574`.
bool defaultDriftAwareSpatialConfirm(
  TrackedBlock fresh,
  TrackedBlock candidate,
) {
  // Reaches into the engine's drift tracker via a closure injected at
  // construction time — see StabilizationEngine.bandSpatialConfirm
  // wiring.
}
```

**Sentinel pattern for the default predicate.** `BandSpatialPredicate`
takes only two block arguments, so it can't reach drift state directly.
The package solves this by exporting `defaultDriftAwareSpatialConfirm`
as a **sentinel function** — calling it directly throws
`UnimplementedError` with a message pointing to the wiring docs. The
engine identity-checks for this sentinel in its constructor and swaps in
a real closure that has drift-tracker access:

```dart
// inside StabilizationEngine constructor
final effectivePredicate = identical(
        bandFallback.spatialConfirm, defaultDriftAwareSpatialConfirm)
    ? (fresh, candidate) => _resolver.overlapRatio(
          fresh,
          candidate,
          _driftTracker.driftMarginForKey(_spaceKeyFor(candidate)),
        ) >= 0.80
    : bandFallback.spatialConfirm;
```

```dart
// exported function — the sentinel itself
bool defaultDriftAwareSpatialConfirm(TrackedBlock fresh, TrackedBlock candidate) {
  throw UnimplementedError(
    'defaultDriftAwareSpatialConfirm is a sentinel — it is replaced by '
    'StabilizationEngine with a drift-tracker-aware closure. Pass a '
    'custom BandSpatialPredicate if you need to call this directly.',
  );
}
```

This keeps the public predicate signature clean while letting the default
have access to drift state. Custom predicates that need drift can be
constructed by consumers — supply a normal `BandSpatialPredicate` closure
over your own state at engine construction time.

#### `BandFallbackStats` (new — `lib/src/band_fallback_stats.dart`)

```dart
/// Per-capture telemetry for the band-relaxed fallback path. Populated
/// even when [BandFallbackConfig.enabled] is `false`, so consumers can
/// measure candidate volume before opting in.
class BandFallbackStats {
  int candidatesConsidered = 0;
  int matchesAdmitted = 0;
  int rejectedSpatial = 0;
  int rejectedCandidateFloor = 0;

  void reset() {
    candidatesConsidered = 0;
    matchesAdmitted = 0;
    rejectedSpatial = 0;
    rejectedCandidateFloor = 0;
  }
}
```

A single instance lives on `StabilizationEngine` and is exposed via a
read-only getter. Consumers `reset()` between captures if they want
per-capture buckets; the engine never resets it automatically (avoids
hiding behavior).

### Engine wiring changes

`StabilizationEngine` constructor gains one new named parameter:

```dart
StabilizationEngine({
  // ...existing parameters...
  BandFallbackConfig bandFallback = const BandFallbackConfig(),
})
```

`_findMatch` is extended with the fallback loop described in §4 ↑.
`_mergeImpl` already supports provisional admission — the band path
simply produces a candidate that's then wrapped via the existing
provisional-freeze path at [stabilization_engine.dart:354-374](../../lib/src/stabilization_engine.dart#L354-L374),
parameterized by `bandFallback.provisionalCaptures`.

### Defaults table — provenance

| Knob                          | Default | App reference                                                                                                                                            |
|-------------------------------|---------|----------------------------------------------------------------------------------------------------------------------------------------------------------|
| `enabled`                     | `false` | Default-off is package convention for permissive matchers; instrumentation before opt-in.                                                               |
| `bandLevenshteinFloor`        | `0.50`  | Mid-band between primary 0.70 and total-mismatch — gives ~20-point relaxation room. Conservative without app data; consumers tune from `BandFallbackStats`. |
| `bandJaccardFloor`            | `0.60`  | Same logic against the app's 0.80 Jaccard floor in `TextDedupUtils.isTextSimilar`.                                                                       |
| `candidateObservationFloor`   | `2`     | Excludes single-frame ghosts. App's `provisionalCapturesRemaining: 3` countdown means by `observationCount >= 2` a candidate has survived one frame.       |
| `provisionalCaptures`         | `3`     | App at `lib/overlay/services/overlay_cache_service.dart:1603-1604`.                                                                                       |
| `spatialConfirm`              | drift-aware `overlapRatio >= 0.80` | App at `lib/overlay/services/overlay_cache_service.dart:1573-1574`. Drift-awareness via `driftMarginForKey` mirrors engine `_dedup` at `stabilization_engine.dart:237-244`. |

### TDD sequence

Order matters — each step ends green before the next begins.

1. **Red** — `band_fallback_config_test.dart`:
   - Default-constructed config has `enabled: false`, `bandLevenshteinFloor: 0.50`, `bandJaccardFloor: 0.60`, `candidateObservationFloor: 2`, `provisionalCaptures: 3`.
   - `BandFallbackConfig(bandLevenshteinFloor: 0.70)` throws `ArgumentError`.
   - `BandFallbackConfig(bandLevenshteinFloor: -0.01)` throws.
   - `BandFallbackConfig(bandJaccardFloor: 0.80)` throws.
   - `BandFallbackConfig(bandJaccardFloor: -0.01)` throws.
   - `BandFallbackConfig(candidateObservationFloor: -1)` throws.
   - `BandFallbackConfig(provisionalCaptures: 0)` throws.
2. **Green** — create `lib/src/band_fallback_config.dart` with the type and the `BandSpatialPredicate` typedef. Add constructor validation.
3. **Red** — `band_fallback_stats_test.dart`:
   - All counters default to `0`.
   - `reset()` zeroes counters that have been incremented.
4. **Green** — create `lib/src/band_fallback_stats.dart`.
5. **Red** — `default_drift_aware_spatial_confirm_test.dart`:
   - Calling `defaultDriftAwareSpatialConfirm(blockA, blockB)` directly throws `UnimplementedError` whose message mentions "sentinel" and "StabilizationEngine".
   - Wire an engine with the default config, feed it two identical-rect candidates, and assert through the band-fallback path that the engine's swapped-in closure returns `true` at `overlapRatio >= 0.80`. (The integration assertion goes via the engine-enabled test in step 9; this step only locks the sentinel-throws behavior.)
6. **Green** — add `defaultDriftAwareSpatialConfirm` as the throwing sentinel. The engine's `identical(...)` swap is wired in step 8.
7. **Red** — `band_fallback_engine_disabled_test.dart`:
   - Engine constructed with default config (`enabled: false`).
   - Feed a fresh observation whose primary Levenshtein vs. all candidates is `< 0.70` but the band floors would pass.
   - Expect: no match (`_findMatch` returns null), `BandFallbackStats.matchesAdmitted == 0`.
   - Expect: `BandFallbackStats.candidatesConsidered >= 1` — the disabled path still **counts** candidates so consumers can measure before opting in.
   - Expect: `BandFallbackStats.rejectedSpatial == 0` and `rejectedCandidateFloor == 0` — rejection buckets only tick when the path is admitting matches.
8. **Green** — extend `StabilizationEngine` constructor with `bandFallback` param + `bandStats` getter + sentinel swap (see §4 wiring). Implement the count-but-don't-admit branch in `_findMatch`: when `enabled: false`, iterate candidates that *would* be considered (passed primary, didn't match), tick `candidatesConsidered`, return null.
9. **Red** — `band_fallback_engine_enabled_admits_test.dart`:
   - Engine with `BandFallbackConfig(enabled: true)`.
   - Candidate with `observationCount: 5`, overlap 1.0, text similarity in the band (e.g. Lev 0.55, Jacc 0.70).
   - Fresh observation with primary similarity `< 0.70`.
   - Expect: `_findMatch` returns the candidate; resulting merge is provisional with `provisionalCapturesRemaining: 3`; stats: `candidatesConsidered: 1`, `matchesAdmitted: 1`, rest 0.
10. **Green** — add fallback loop in `_findMatch`. Wire band-admitted candidates through the existing provisional-freeze path with `bandFallback.provisionalCaptures`.
11. **Red** — `band_fallback_engine_rejects_test.dart`:
    - **Rejected by `candidateObservationFloor`:** candidate `observationCount: 1`, otherwise admissible → null; stats `rejectedCandidateFloor: 1`.
    - **Rejected by `spatialConfirm`:** candidate non-overlapping but band text similarity passes → null; stats `rejectedSpatial: 1`.
    - **Rejected by band text floor:** candidate text similarity below band floor → null; stats `candidatesConsidered: 1`, no rejection bucket (it just didn't match).
12. **Green** — verify rejection branches; adjust counter placement if any test fails.
13. **Red** — `band_fallback_engine_custom_predicate_test.dart`:
    - Construct engine with a custom `spatialConfirm` that always returns `false`.
    - Otherwise-admissible candidate → null; stats `rejectedSpatial: 1`. Locks the predicate-injection seam.
14. **Green** — sanity check; should already pass.
15. **Red** — `band_fallback_engine_provisional_decay_test.dart`:
    - Admit a band-fallback match (provisional, captures=3).
    - Run two more captures where the same observation appears with high primary similarity.
    - Expect: after 3 total captures (admission + 2 confirmations), block is non-provisional (`isProvisional: false`, `provisionalCapturesRemaining: 0`). Locks the decay path's interaction with band admission.
16. **Green** — verify; the existing provisional decay path should handle this without changes.
17. **Refactor** — pull the fallback loop into a private `_findBandMatch(fresh, candidates)` helper on the engine for readability. Re-run targeted tests.
18. **Full suite** — `flutter test` once; commit.

### Commit shape

Split into commits for review legibility (one squash on merge):

- `feat(api): #20 add BandFallbackConfig + BandFallbackStats + BandSpatialPredicate`
- `feat(engine): #20 wire band-relaxed fallback into _findMatch (default off)`
- `refactor(engine): extract _findBandMatch helper`

Squash-merge title:

```
feat(engine): #20 optional band-relaxed inter-batch matching fallback

Closes #20
```

### CHANGELOG entry

```markdown
### Added
- `BandFallbackConfig` value type configures an optional band-relaxed
  fallback inside `StabilizationEngine._findMatch`. Default constructor
  ships disabled; consumers opt in once they have measured candidate
  volume from `BandFallbackStats`. See `docs/superpowers/specs/`
  for the full design and provenance of every default (#20).
- `BandFallbackStats` exposes per-capture counters for the fallback path:
  `candidatesConsidered`, `matchesAdmitted`, `rejectedSpatial`,
  `rejectedCandidateFloor`. Reset via `reset()`; the engine never resets
  it automatically (#20).
- `BandSpatialPredicate` typedef mirrors `ContextualInvalidationCheck` —
  `bool Function(TrackedBlock fresh, TrackedBlock candidate)`. The
  default predicate is a drift-aware overlap-ratio check at 0.80,
  matching `ocr_translate_demo`'s primary NMS gate (#20).
- `StabilizationEngine` constructor gains a `bandFallback:
  BandFallbackConfig` parameter (defaults to disabled — backward
  compatible) and a `bandStats` getter (#20).
```

---

## 5. PR 3 — 0.4.0 release commit

Branch `chore/release-0.4.0`. Two file changes only.

### `pubspec.yaml`

```diff
-version: 0.3.0
+version: 0.4.0
```

### `CHANGELOG.md`

Add a `## 0.4.0 - 2026-MM-DD` header above 0.3.0's entry, fold in the
draft entries from PRs 1 and 2 verbatim.

### Commit + PR

Commit message:

```
chore: release v0.4.0

#20 band-fallback config + stats wired into the engine (default off).
#27 qualityScore NaN guard + DefaultTrackedBlock constructor invariants.

See CHANGELOG.md for the full entry.
```

After merge, the maintainer runs `flutter pub publish` interactively.
That step is NOT in scope for this spec (requires `pub.dev` credentials
and an interactive y/N prompt).

### Post-release follow-up (not in this spec)

- Bump `ocr_translate_demo`'s `ocr_stabilizer` constraint to `^0.4.0` in
  the same PR that wires `resetDriftPropagation()` (the unblock of #1084).
- Open follow-up issues for: corpus-data-driven band-threshold tuning;
  optional `observeOnly` mode if any consumer requests it.

---

## 6. Non-goals (lock against scope creep)

- **No app-side changes** in this spec. The unblock PR is separate.
- **No DriftTracker API changes.** The default predicate reaches into
  drift state via a constructor-time closure; no public surface change.
- **No `qualityScore` weight tuning.** The 0.4 / 0.6 split stays.
- **No new public types beyond the three in §4.** Stats / config / predicate
  typedef are the entire new surface.
- **No primary `_findMatch` threshold change.** The 0.70 floor stays as
  the high-confidence gate. Band fallback is strictly additive.

---

## 7. Risks

| Risk                                                                                                       | Mitigation                                                                                          |
|------------------------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------|
| Default thresholds (0.50 / 0.60 band) are guesses without corpus data.                                     | Ship default-off. Document `BandFallbackStats` as the measurement vehicle. Tune in 0.4.x.            |
| `defaultDriftAwareSpatialConfirm` closes over engine state, making it untestable in isolation.             | Test exercises the lambda the engine builds with a hand-rolled drift tracker. Documented in spec. |
| Adding a constructor invariant to `DefaultTrackedBlock` is technically breaking.                            | Documented as Breaking in CHANGELOG. The breaking surface is "constructors with NaN/out-of-range" — should be zero in practice given the documented `.from()` entry points. |
| Stats-at-zero on disabled path contradicts "measure before opt-in" promise.                                | Spec pin in §4 step 7: explicit decision, leaves room for a future `observeOnly` mode.              |
| Provisional admission interacts with drift propagation in unexpected ways.                                 | TDD step 15 explicitly locks the decay path; existing provisional infrastructure carries the load. |

---

## 8. Acceptance criteria (release readiness)

- [ ] PR #1 (`fix/27-...`) merged to `main` with green CI / local tests; CHANGELOG draft included.
- [ ] PR #2 (`feat/20-...`) merged to `main` with green CI / local tests; CHANGELOG draft included.
- [ ] PR #3 (`chore/release-0.4.0`) merged to `main`; CHANGELOG `## 0.4.0` header dated; `pubspec.yaml` bumped.
- [ ] `git tag v0.4.0` pushed.
- [ ] Maintainer runs `flutter pub publish` (out-of-band).
- [ ] Issue #1084 in `ocr_translate_demo` unblocks (separate PR).
