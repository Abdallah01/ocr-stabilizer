# v0.4.0 — Band-Fallback Inter-Batch Matching + `qualityScore` NaN Guard

**Status:** Approved (revised after first-round review). Ready for implementation planning.
**Date:** 2026-05-23 (initial), revised 2026-05-23 post-review.
**Repository:** `ocr-stabilizer` (community-facing Dart package).
**Release target:** `0.4.0`.
**Closes:** [#27](https://github.com/Abdallah01/ocr-stabilizer/issues/27), [#20](https://github.com/Abdallah01/ocr-stabilizer/issues/20).

---

## 1. Scope

Three PRs land on `main` in order, after which the maintainer publishes 0.4.0
to pub.dev. No other features ride along.

| # | Branch                             | Issue | Net effect                                                                                                                       |
|---|------------------------------------|-------|----------------------------------------------------------------------------------------------------------------------------------|
| 1 | `fix/27-confidence-nan-guard`      | #27   | Engine entry validates incoming `TrackedBlock` confidence; `DefaultTrackedBlock` ctor throws on NaN/out-of-range; `qualityScore` debug-asserts. |
| 2 | `feat/20-band-fallback`            | #20   | Optional band-relaxed fallback in `_findMatch`, gated by `BandFallbackMode` (off / observeOnly / admit). Default `off`. Stats expose primary + band counters. |
| 3 | `chore/release-0.4.0`              | —     | CHANGELOG header + `pubspec.yaml` version bump.                                                                                  |

### Out of scope (deferred)

- Tuning the band thresholds against real-corpus data. Default config ships
  `mode: BandFallbackMode.off` precisely so consumers can switch to
  `observeOnly` first and read counters before committing to `admit`.
- Downstream adoption. The consumer app keeps consuming 0.3.x until
  0.4.0 is on pub.dev; the unblock PR there lands separately in the
  consumer's own backlog.
- **Confidence-validation cleanup (Option A\*).** Lifting NaN/range validation
  into `Confidence` itself would require either dropping `const` on
  `PositionConfidence.groundTruth` / `TextConfidence.groundTruth` (breaks
  default-parameter-value use in `DefaultTrackedBlock`) or refactoring those
  defaults to nullable+init-list. Would require revisiting 0.2.0's
  const-sentinel trade-off; deferred pending a concrete reason.

---

## 2. Design principles

1. **Community-facing first.** Every numeric or behavioral knob the app's
   pipeline exposes implicitly becomes an explicit parameter so other
   consumers can deviate. Defaults reflect the app's proven choices because
   the app is the most-tested reference.
2. **App-pattern provenance for defaults.** Where the in-repo app already
   solves the same problem, the package's default value is *cited* against
   the app's value and the spec records the file:line. The package owns the
   default thereafter — defaults don't track app changes.
3. **Non-negotiable invariants enforced as exceptions.** Anything that
   shouldn't be optional `throw`s (not `assert`s) on construction or at the
   engine entry, in the established style of `DefaultTrackedBlock`'s
   `containerId` check at [default_tracked_block.dart:142-150](../../lib/src/default_tracked_block.dart#L142-L150).
4. **Non-generic predicate signatures.** New predicate types mirror the
   existing `ContextualInvalidationCheck` shape — `bool Function(TrackedBlock,
   TrackedBlock)` — for consistency with the engine's existing seam. No
   speculative generics, no engine-internal types (`SpaceKey`,
   `DriftTracker`) leaked into public signatures.
5. **Make invalid state unrepresentable.** Where the configuration space has
   three modes, use a three-state enum, not two booleans with a forbidden
   combination.
6. **Default OFF for new permissive matchers.** Ship with the flag off and
   stats on so consumers see candidate volume *and* what would have been
   admitted before flipping.

---

## 3. PR 1 — #27 Confidence NaN/range invariants

### Problem

`OverlapResolver.qualityScore` at [overlap_resolver.dart:176-177](../../lib/src/overlap_resolver.dart#L176-L177)
multiplies two `Confidence.raw` values. If either is `NaN` the score is
`NaN`, which silently poisons `resolveOverlap`'s quality comparison
(NaN compares false against every double). The block that "loses" the
comparison is chosen arbitrarily by sort stability.

#19 fixed the upstream factories (`PositionConfidence.from` /
`TextConfidence.from` reject NaN). Two gaps remain:

- The **primary const constructors** `PositionConfidence(double)` and
  `TextConfidence(double)` are documented as intentionally unchecked
  ([confidence_types.dart:14-22](../../lib/src/types/confidence_types.dart#L14-L22))
  to support `const` sentinels like `groundTruth`. Dart can't `throw` from
  a `const` constructor, so the unchecked path is structurally required.
- Therefore, **any code that constructs `Confidence` directly** (test
  fixtures, future producers, etc.) can slip a NaN past the gate. Today
  the only path that does is direct `DefaultTrackedBlock` construction in
  tests; tomorrow it could be any new `TrackedBlock` implementor.

### Solution — engine-entry validation (Option C, done properly)

Plug the gap **once, at the engine boundary**:

**A. `StabilizationEngine.stabilize()` validates every incoming `TrackedBlock`.**
At the entry of the public `stabilize(List<TrackedBlock> observations)`
method, before any merge work runs, validate that every block's
`positionConfidence.raw` and `textConfidence.raw` are finite values in
`[0.0, 1.0]`. Throw `ArgumentError.value` on the first violation, naming
the offending field and observation index. This catches any
`TrackedBlock` implementor — `DefaultTrackedBlock` or otherwise — at one
single seam.

Note that `MergeResult`'s 0.2.0 throw already guards engine *output*;
this PR adds the symmetric guard at engine *input*. The two together
bracket the pipeline — anything that violates the Confidence invariants
fails at one end or the other, regardless of where it originated.

```dart
// inside StabilizationEngine.stabilize(...)
for (var i = 0; i < observations.length; i++) {
  _assertValidConfidence(observations[i], i);
}
```

**B. `DefaultTrackedBlock` constructor still throws on NaN/out-of-range.**
Mirrors the existing `containerId` `throw` block at
[default_tracked_block.dart:142-150](../../lib/src/default_tracked_block.dart#L142-L150).
Belt-and-suspenders early-fail at construction time produces a clearer
stack trace than a downstream engine-entry throw, even though the engine
guard would catch the same case.

**C. `qualityScore` collapses to a debug assert.** With (A) in place,
NaN reaching `qualityScore` is a logic bug — the production guard is at
the engine entry. Use `assert` so debug builds surface the bug; release
builds skip the check for zero overhead. No 0.0 sentinel return.

```dart
static double qualityScore(TrackedBlock block) {
  final pos = block.positionConfidence.raw;
  final txt = block.textConfidence.raw;
  assert(!pos.isNaN && !txt.isNaN,
      'qualityScore reached with NaN confidence — '
      'engine-entry validation should have caught this.');
  return pos * 0.4 + txt * 0.6;
}
```

Why `throw` (at the engine entry / `DefaultTrackedBlock` ctor) over
`assert` (at `qualityScore`): the first two are state-owning seams where
production enforcement matters; the third is downstream of those guards
and only fires on a logic bug worth catching in debug.

### TDD sequence

1. **Red** — `default_tracked_block_confidence_invariant_test.dart`:
   - `DefaultTrackedBlock(... positionConfidence: PositionConfidence(double.nan) ...)` → `ArgumentError`.
   - same for `textConfidence`.
   - same for `PositionConfidence(-0.1)` and `PositionConfidence(1.1)`.
   - sanity: `PositionConfidence(0.0)` and `PositionConfidence(1.0)` construct successfully.
2. **Green** — add the constructor throws to `DefaultTrackedBlock`, modelled on the existing `containerId` block. Extract a private `_validateConfidence(name, raw)` helper for DRYness while adding.
3. **Red** — `stabilization_engine_confidence_entry_validation_test.dart`:
   - `engine.stabilize([blockWithNaNPositionConfidence])` → `ArgumentError` whose message names the field and observation index.
   - same for `textConfidence`.
   - same for out-of-range values constructed via a hand-rolled `TrackedBlock` impl that bypasses `DefaultTrackedBlock` (proves the engine catches non-`DefaultTrackedBlock` implementors too).
   - sanity: a valid block list runs through without throwing.
4. **Green** — add the entry-validation loop in `stabilize()`.
5. **Red** — `quality_score_debug_assert_test.dart`:
   - In a debug build only (Dart's `assert` is debug-only), construct a `Confidence(double.nan)` block via the *unchecked* primary constructor (bypassing both `DefaultTrackedBlock` and the engine entry), pass it directly to `OverlapResolver.qualityScore(...)`, expect `AssertionError`.
   - In a release build, the assert is stripped; can't be tested in the same target. Document this in the test.
6. **Green** — replace `qualityScore`'s body with the assert + plain return.
7. **Refactor** — none planned; the helper extracted in step 2 is the only DRY opportunity.
8. **Full suite** — `flutter test` once; commit.

### Commit shape

Single squashed commit, message:

```
fix(engine): #27 validate Confidence at engine entry; throw in DefaultTrackedBlock ctor; debug-assert in qualityScore

Closes #27
```

### CHANGELOG entry

```markdown
### Fixed
- `OverlapResolver.qualityScore` no longer silently propagates `NaN` into
  the NMS comparison. NaN reaching `qualityScore` is now a debug-time
  `AssertionError`; release builds skip the check (defended by entry
  validation, below) (#27).

### Changed
- **Breaking:** `StabilizationEngine.stabilize()` now throws
  `ArgumentError` if any observation's `positionConfidence.raw` or
  `textConfidence.raw` is `NaN` or outside `[0.0, 1.0]`. Catches any
  `TrackedBlock` implementor at the engine entry, closing the documented
  unchecked-`const`-Confidence gap (#27).
- **Breaking:** `DefaultTrackedBlock` constructor throws `ArgumentError`
  when `positionConfidence.raw` or `textConfidence.raw` is `NaN` or
  outside `[0.0, 1.0]`. Early-fail at construction with a cleaner stack
  trace than the engine-entry guard would produce. Consumers going through
  `PositionConfidence.from()` / `TextConfidence.from()` (validated since
  #19) are unaffected (#27).
```

---

## 4. PR 2 — #20 Band-fallback inter-batch matching

### Problem

`_findMatch` at [stabilization_engine.dart:293-312](../../lib/src/stabilization_engine.dart#L293-L312)
rejects any candidate whose text similarity (`isTextSimilarWithScores`)
is below the **primary path floors of Lev ≥ 0.70 / Jaccard ≥ 0.80** —
matching the package's [`TextDedupUtils.isTextSimilar`](../../lib/src/text_dedup_utils.dart#L162)
defaults. On real captures, OCR jitter (one character flipped, one
ligature mis-segmented) reliably drops a stable block below those floors
for one frame, even when the spatial position is unambiguous. The block
then respawns rather than merging, which the user observes as the overlay
"blinking off and back on."

The 0.70 / 0.80 floors stay sound as a *high-confidence* gate. The fix
is a *band-relaxed* fallback: when no candidate clears the primary
floors, look at candidates whose text similarity is in a lower band AND
whose spatial position confirms the match independently. Admit such a
match as **provisional** so it gets a few frames to prove itself before
influencing drift, and so misreads self-clean.

### Approach summary

```text
_findMatch(fresh, candidates):
    primary = first candidate with isTextSimilarWithScores ≥ Lev 0.70 OR Jacc 0.80
    if primary != null:
        bandStats.primaryMatchesAdmitted++
        return primary
    bandStats.primaryMatchesRejected++
    if bandFallback.mode == BandFallbackMode.off:
        return null  // zero further work
    // mode is observeOnly OR admit — run the full loop
    for c in candidates ordered by descending similarity:
        bandStats.candidatesConsidered++
        if c.observationCount < bandFallback.candidateObservationFloor:
            bandStats.rejectedCandidateFloor++; continue
        if !effectiveSpatialConfirm(fresh, c):
            bandStats.rejectedSpatial++; continue
        if !isTextSimilarWithScores(fresh.text, c.text,
                                    levenshtein: bandFallback.bandLevenshteinFloor,
                                    jaccard: bandFallback.bandJaccardFloor):
            continue  // text-band miss; not bucketed (would-have-matched ≠ rejected)
        bandStats.bandMatchesIdentified++
        if bandFallback.mode == BandFallbackMode.admit:
            bandStats.matchesAdmitted++
            return c  // wrapped as provisional in _mergeImpl
        // observeOnly: continue scanning so all candidates contribute to counters
    return null  // observeOnly always returns null; admit returns null if no candidate matched
```

`effectiveSpatialConfirm` is the engine's resolved predicate: either the
consumer-supplied `bandFallback.spatialConfirm`, or — when that's `null` —
a drift-aware closure the engine builds at construction time (see
"Default spatial predicate" below).

### Public types

#### `BandFallbackMode` (new — `lib/src/band_fallback_config.dart`)

```dart
/// Operating mode for the band-relaxed fallback path inside
/// [StabilizationEngine._findMatch].
enum BandFallbackMode {
  /// No band-fallback work runs. Primary path counters
  /// ([BandFallbackStats.primaryMatchesAdmitted] and
  /// [BandFallbackStats.primaryMatchesRejected]) still tick because they
  /// are populated by the primary path, not the band loop.
  off,

  /// The full band loop runs, every counter populates, but no candidate is
  /// ever returned. Use this mode to measure what `admit` *would* have
  /// done before flipping. Loops scans all candidates so per-stage
  /// counters reflect the full population, not just the first match.
  observeOnly,

  /// Production mode. The full band loop runs and returns the first
  /// candidate that clears every gate. Matches are admitted as
  /// provisional (see [BandFallbackConfig.provisionalCaptures]).
  admit,
}
```

#### `BandSpatialPredicate` (new — same file)

```dart
/// Spatial confirmation predicate for a band-relaxed candidate.
/// Signature mirrors [ContextualInvalidationCheck] for consistency with
/// the engine's existing predicate-injection seam — two `TrackedBlock`
/// arguments, no engine-internal types leaked.
typedef BandSpatialPredicate =
    bool Function(TrackedBlock fresh, TrackedBlock candidate);
```

#### `BandFallbackConfig` (new — same file)

Non-generic value type. Exported from the package barrel.

```dart
/// Configuration for the band-relaxed fallback path inside
/// [StabilizationEngine._findMatch].
///
/// Default is [BandFallbackMode.off]. Recommended adoption flow:
/// ship with `mode: off`, switch to `observeOnly` to read
/// [BandFallbackStats], commit to `admit` once the counter ratios
/// justify it.
///
/// Primary-path floors (Lev 0.70 / Jaccard 0.80) are owned by the engine
/// and not configurable through this type — see
/// [TextDedupUtils.isTextSimilarWithScores] for those.
@immutable
class BandFallbackConfig {
  /// Operating mode. Default: [BandFallbackMode.off].
  final BandFallbackMode mode;

  /// Lower Levenshtein threshold for band-relaxed matches.
  /// Range: `[0.0, 0.70)` — the upper bound is exclusive because matches
  /// at `>= 0.70` go through the primary path.
  /// Default: `0.50`.
  final double bandLevenshteinFloor;

  /// Lower Jaccard threshold for band-relaxed matches.
  /// Range: `[0.0, 0.80)` — the upper bound is exclusive because matches
  /// at `>= 0.80` go through the primary path.
  /// Default: `0.60`.
  final double bandJaccardFloor;

  /// Minimum `observationCount` a candidate must have before it can be
  /// considered for band-relaxed admission. Filters candidates whose own
  /// existence is still provisional, preventing a provisional fresh
  /// observation from vouching for a provisional candidate.
  ///
  /// Must be `>= 0`. Default: `provisionalCaptures + 1` (= `4` with the
  /// default `provisionalCaptures`) — semantically "candidate has
  /// cleared its own provisional window."
  ///
  /// Consumers who want provisional-on-provisional admission (the
  /// existing provisional-decay path is self-cleaning eventually) can
  /// lower this to `1` or `2` explicitly.
  final int candidateObservationFloor;

  /// `provisionalCapturesRemaining` granted to a freshly band-admitted
  /// match. Must be `>= 1` (reflects [MergeResult]'s invariant that
  /// `isProvisional` implies `provisionalCapturesRemaining > 0`).
  ///
  /// Default: `3`. Empirically validated by deployed consumer instances;
  /// the package owns the default thereafter.
  final int provisionalCaptures;

  /// Spatial confirmation predicate. `null` means the engine substitutes a
  /// drift-aware overlap-ratio closure at construction time (see
  /// "Default spatial predicate" in the spec).
  /// Default: `null`.
  final BandSpatialPredicate? spatialConfirm;

  const BandFallbackConfig({
    this.mode = BandFallbackMode.off,
    this.bandLevenshteinFloor = 0.50,
    this.bandJaccardFloor = 0.60,
    int? candidateObservationFloor,
    this.provisionalCaptures = 3,
    this.spatialConfirm,
  }) : candidateObservationFloor =
            candidateObservationFloor ?? (provisionalCaptures + 1);
  // Constructor body throws ArgumentError on out-of-range values.
}
```

Constructor invariants (all `throw ArgumentError.value`):

| Field                       | Range / rule                          |
|-----------------------------|---------------------------------------|
| `bandLevenshteinFloor`      | `[0.0, 0.70)`                         |
| `bandJaccardFloor`          | `[0.0, 0.80)`                         |
| `candidateObservationFloor` | `>= 0`                                |
| `provisionalCaptures`       | `>= 1`                                |

`mode` and `spatialConfirm` have no invariants beyond type.

#### Default spatial predicate (engine-internal closure)

`BandSpatialPredicate` takes only two block arguments — it cannot reach
drift state directly, and that's by design (principle 4: no engine-
internal types leak). When `BandFallbackConfig.spatialConfirm` is
`null`, the engine builds a closure at construction time that uses its
own `DriftTracker` and `OverlapResolver`:

```dart
// inside StabilizationEngine constructor
final BandSpatialPredicate effectiveSpatialConfirm =
    bandFallback.spatialConfirm ??
    (fresh, candidate) => _resolver.overlapRatio(
          fresh,
          candidate,
          _driftTracker.driftMarginForKey(_spaceKeyFor(candidate)),
        ) >= 0.80;
```

The `0.80` threshold matches conventional NMS overlap floors used in
production overlay caches; the
drift-margin pattern mirrors the engine's own `_dedup` at
[stabilization_engine.dart:237-244](../../lib/src/stabilization_engine.dart#L237-L244).
Both are cited as provenance; the package owns the defaults thereafter.

Consumers who want a drift-aware custom predicate construct one
themselves by closing over their own drift state at engine-construction
time. The package does not export a callable default — the default is
the engine's internal behavior when `spatialConfirm` is `null`.

#### `BandFallbackStats` (new — `lib/src/band_fallback_stats.dart`)

Public read-only view; the engine writes to a same-library
`BandFallbackStatsInternal` subclass.

```dart
/// Per-capture telemetry for the matching path inside [StabilizationEngine].
/// All counters are cumulative until [reset] is called.
///
/// Primary counters tick whether or not the band-fallback path is enabled —
/// they reflect the primary path's outcome. Band counters only tick when
/// [BandFallbackConfig.mode] is [BandFallbackMode.observeOnly] or
/// [BandFallbackMode.admit].
class BandFallbackStats {
  BandFallbackStats._();

  /// Number of fresh observations that found a primary-path match.
  int get primaryMatchesAdmitted => _primaryMatchesAdmitted;
  int _primaryMatchesAdmitted = 0;

  /// Number of fresh observations that the primary path rejected.
  /// `primaryMatchesAdmitted + primaryMatchesRejected` == total fresh
  /// observations that reached `_findMatch`.
  int get primaryMatchesRejected => _primaryMatchesRejected;
  int _primaryMatchesRejected = 0;

  /// Number of candidates the band loop scanned. Only ticks when
  /// `mode != off`. Compare against `primaryMatchesRejected` to compute
  /// "candidates considered per primary miss."
  int get candidatesConsidered => _candidatesConsidered;
  int _candidatesConsidered = 0;

  /// Number of candidates the band loop rejected because their
  /// `observationCount` was below `candidateObservationFloor`.
  int get rejectedCandidateFloor => _rejectedCandidateFloor;
  int _rejectedCandidateFloor = 0;

  /// Number of candidates the band loop rejected because `spatialConfirm`
  /// returned `false`.
  int get rejectedSpatial => _rejectedSpatial;
  int _rejectedSpatial = 0;

  /// Number of candidates that passed every gate (observation floor,
  /// spatial confirm, text band floors). In `admit` mode this also ticks
  /// `matchesAdmitted`; in `observeOnly` mode it ticks alone.
  int get bandMatchesIdentified => _bandMatchesIdentified;
  int _bandMatchesIdentified = 0;

  /// Number of band-relaxed matches actually returned by `_findMatch`.
  /// Always `<= bandMatchesIdentified`. In `observeOnly` mode this stays
  /// at zero by construction.
  int get matchesAdmitted => _matchesAdmitted;
  int _matchesAdmitted = 0;

  /// Zero every counter. The engine does not call this automatically;
  /// consumers reset between captures if they want per-capture buckets.
  void reset() {
    _primaryMatchesAdmitted = 0;
    _primaryMatchesRejected = 0;
    _candidatesConsidered = 0;
    _rejectedCandidateFloor = 0;
    _rejectedSpatial = 0;
    _bandMatchesIdentified = 0;
    _matchesAdmitted = 0;
  }
}

/// Engine-side mutation surface. Lives in the same library as
/// [BandFallbackStats] so the underscore-private fields are accessible.
/// Public to the package — consumers see only the [BandFallbackStats]
/// supertype via [StabilizationEngine.bandStats].
class BandFallbackStatsInternal extends BandFallbackStats {
  BandFallbackStatsInternal() : super._();

  void recordPrimaryMatchAdmitted() => _primaryMatchesAdmitted++;
  void recordPrimaryMatchRejected() => _primaryMatchesRejected++;
  void recordCandidateConsidered() => _candidatesConsidered++;
  void recordRejectedCandidateFloor() => _rejectedCandidateFloor++;
  void recordRejectedSpatial() => _rejectedSpatial++;
  void recordBandMatchIdentified() => _bandMatchesIdentified++;
  void recordMatchAdmitted() => _matchesAdmitted++;
}
```

The engine holds a `BandFallbackStatsInternal` and exposes it via
`BandFallbackStats get bandStats => _internalStats;` (the supertype is
the return type; the upcast hides the mutators). Consumers can read
counters and call `reset()` but cannot corrupt them.

### Engine wiring changes

`StabilizationEngine` constructor gains one new named parameter:

```dart
StabilizationEngine({
  // ...existing parameters...
  BandFallbackConfig bandFallback = const BandFallbackConfig(),
})
```

`_findMatch` is extended with the pseudocode loop from "Approach summary"
above. The primary-path counter (`recordPrimaryMatchAdmitted` /
`recordPrimaryMatchRejected`) ticks regardless of `mode`. The band loop
runs only when `mode != off`. `_mergeImpl` already supports provisional
admission — the band path produces a candidate that's then wrapped via
the existing provisional-freeze path at [stabilization_engine.dart:354-374](../../lib/src/stabilization_engine.dart#L354-L374),
parameterized by `bandFallback.provisionalCaptures`.

### Defaults table

| Knob                          | Default                          | Source                                                                                                       |
|-------------------------------|----------------------------------|--------------------------------------------------------------------------------------------------------------|
| `mode`                        | `BandFallbackMode.off`           | Package convention for permissive matchers; instrumentation before opt-in.                                  |
| Primary path Lev floor        | `0.70` (engine-owned, non-config) | Existing `TextDedupUtils.isTextSimilar` default; matches the consumer's primary NMS default. |
| Primary path Jaccard floor    | `0.80` (engine-owned, non-config) | Same.                                                                                                       |
| `bandLevenshteinFloor`        | `0.50`                           | Mid-band between primary `0.70` and total-mismatch. Conservative without corpus data; consumers tune from stats. |
| `bandJaccardFloor`            | `0.60`                           | Same logic vs primary `0.80`.                                                                                |
| `candidateObservationFloor`   | `provisionalCaptures + 1` (= 4)  | "Candidate has cleared its own provisional window." Lower to enable provisional-on-provisional admission.   |
| `provisionalCaptures`         | `3`                              | Cited from the consumer's deployed value as proven; package owns the default.                                |
| Default `spatialConfirm`      | drift-aware `overlapRatio >= 0.80` (engine-internal closure when config is `null`) | `0.80` cited from the consumer's primary NMS gate; drift-margin pattern from engine's own `_dedup`. |

### TDD sequence

Order matters — each step ends green before the next begins.

1. **Red** — `band_fallback_mode_test.dart`:
   - `BandFallbackMode.values` contains `off`, `observeOnly`, `admit` in that order.
2. **Green** — create the enum in `lib/src/band_fallback_config.dart`.
3. **Red** — `band_fallback_config_test.dart`:
   - Default-constructed: `mode == off`, `bandLevenshteinFloor == 0.50`, `bandJaccardFloor == 0.60`, `candidateObservationFloor == 4` (= 3 + 1), `provisionalCaptures == 3`, `spatialConfirm == null`.
   - Explicit `provisionalCaptures: 5` with no `candidateObservationFloor` → floor is `6`.
   - Explicit `provisionalCaptures: 5` with `candidateObservationFloor: 2` → floor is `2` (consumer override wins).
   - Out-of-range throws: `bandLevenshteinFloor: 0.70`, `bandLevenshteinFloor: -0.01`, `bandJaccardFloor: 0.80`, `bandJaccardFloor: -0.01`, `candidateObservationFloor: -1`, `provisionalCaptures: 0`.
4. **Green** — implement `BandFallbackConfig` + constructor validation + `BandSpatialPredicate` typedef.
5. **Red** — `band_fallback_stats_test.dart`:
   - All counters default to `0`.
   - `reset()` zeroes counters that have been incremented (test via the `Internal` subclass to mutate, then read via the public supertype).
   - `BandFallbackStats()` (public ctor) does not exist / is not callable (private constructor enforced).
6. **Green** — implement both classes in `band_fallback_stats.dart`.
7. **Red** — `stabilization_engine_band_off_primary_counters_test.dart`:
   - Engine constructed with default config (`mode: off`).
   - Feed an observation that finds a primary match → `primaryMatchesAdmitted == 1`, `candidatesConsidered == 0`.
   - Feed an observation that does NOT find a primary match → `primaryMatchesRejected == 1`, `candidatesConsidered == 0` (off mode does zero band work).
8. **Green** — extend `StabilizationEngine` ctor with `bandFallback` param + `bandStats` getter. Wire primary-path counters in `_findMatch`. Leave the band loop unwritten.
9. **Red** — `stabilization_engine_band_observe_only_test.dart`:
   - Engine with `mode: observeOnly`.
   - Two candidates: one would clear every band gate, one would fail spatial.
   - Fresh observation has no primary match.
   - Expect: `_findMatch` returns `null` (observeOnly never returns a match), `primaryMatchesRejected == 1`, `candidatesConsidered == 2`, `bandMatchesIdentified == 1`, `rejectedSpatial == 1`, `matchesAdmitted == 0`.
10. **Green** — implement the band loop with the observeOnly branch (scan all, count all, return null).
11. **Red** — `stabilization_engine_band_admit_test.dart`:
    - Engine with `mode: admit`.
    - Candidate `observationCount: 5`, overlap 1.0, text similarity in the band (e.g. Lev 0.55, Jacc 0.70).
    - Fresh observation with primary similarity below floors.
    - Expect: `_findMatch` returns the candidate; resulting merge is provisional with `provisionalCapturesRemaining: 3`; `candidatesConsidered: 1`, `bandMatchesIdentified: 1`, `matchesAdmitted: 1`.
12. **Green** — add the admit branch (return on first identified match). Wire provisional-freeze with `bandFallback.provisionalCaptures`.
13. **Red** — `stabilization_engine_band_rejections_test.dart` (admit mode):
    - **Rejected by `candidateObservationFloor`:** candidate `observationCount: 1`, floor `2` → null; `rejectedCandidateFloor: 1`, `bandMatchesIdentified: 0`.
    - **Rejected by `spatialConfirm`:** non-overlapping candidate, band text passes → null; `rejectedSpatial: 1`, `bandMatchesIdentified: 0`.
    - **Below band text floor:** candidate text similarity below `bandLevenshteinFloor` AND `bandJaccardFloor` → null; `candidatesConsidered: 1`, no rejection bucket (text-band miss isn't bucketed).
14. **Green** — verify each branch; adjust counter placement if any test fails.
15. **Red** — `stabilization_engine_band_custom_predicate_test.dart`:
    - Construct engine with `spatialConfirm: (a, b) => false` and `mode: admit`.
    - Otherwise-admissible candidate → null; `rejectedSpatial: 1`. Locks the predicate-injection seam.
    - Also: with `spatialConfirm: null` (default), feed two identical-rect candidates and an out-of-bounds candidate; the default closure must accept the identical rects (`overlapRatio == 1.0 >= 0.80`) and reject the out-of-bounds one (`overlapRatio < 0.80`). Locks the engine's default closure behavior.
16. **Green** — sanity check; should already pass.
17. **Red** — `stabilization_engine_band_provisional_decay_test.dart`:
    - Admit a band-fallback match (provisional, captures=3).
    - Run two more captures where the same observation appears with primary similarity above floors.
    - Expect: after 3 total captures (admission + 2 confirmations), block is non-provisional (`isProvisional: false`, `provisionalCapturesRemaining: 0`). Locks the decay path's interaction with band admission.
18. **Green** — verify; the existing provisional decay path should handle this without changes.
19. **Refactor** — pull the band loop into a private `_findBandMatch(fresh, candidates)` helper on the engine for readability. Re-run targeted tests.
20. **Full suite** — `flutter test` once; commit.

### Commit shape

Split into commits for review legibility (one squash on merge):

- `feat(api): #20 add BandFallbackMode + BandFallbackConfig + BandSpatialPredicate`
- `feat(api): #20 add BandFallbackStats (read-only public + Internal mutator)`
- `feat(engine): #20 primary-path counters in _findMatch (no band loop yet)`
- `feat(engine): #20 wire band loop with observeOnly + admit branches`
- `refactor(engine): extract _findBandMatch helper`

Squash-merge title:

```
feat(engine): #20 optional band-relaxed inter-batch matching fallback

Closes #20
```

### CHANGELOG entry

```markdown
### Added
- `BandFallbackMode` enum (`off` | `observeOnly` | `admit`) configures the
  band-relaxed fallback path inside `StabilizationEngine._findMatch`.
  Default is `off`; switch to `observeOnly` to read `BandFallbackStats`
  before committing to `admit`. See `doc/superpowers/specs/` for the
  full design and default provenance (#20).
- `BandFallbackConfig` value type wraps the band thresholds, candidate
  observation floor, provisional-capture grant, and spatial confirmation
  predicate. Constructor `throw`s on out-of-range values. Primary-path
  floors (Lev 0.70 / Jaccard 0.80) are engine-owned, not configurable
  through this type (#20).
- `BandFallbackStats` exposes per-capture counters: `primaryMatchesAdmitted`,
  `primaryMatchesRejected`, `candidatesConsidered`, `rejectedCandidateFloor`,
  `rejectedSpatial`, `bandMatchesIdentified`, `matchesAdmitted`. Read-only
  public surface; engine mutates via a same-library `Internal` subclass.
  Reset via `reset()`; the engine never resets it automatically (#20).
- `BandSpatialPredicate` typedef mirrors `ContextualInvalidationCheck` —
  `bool Function(TrackedBlock fresh, TrackedBlock candidate)`. When
  `BandFallbackConfig.spatialConfirm` is `null`, the engine substitutes
  a drift-aware `overlapRatio >= 0.80` closure (#20).
- `StabilizationEngine` constructor gains a `bandFallback:
  BandFallbackConfig` parameter (defaults to `mode: off` — backward
  compatible) and a `bandStats` getter returning the read-only stats view
  (#20).
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

Add a `## 0.4.0 - <release date>` header above 0.3.0's entry, fold in
the draft entries from PRs 1 and 2 verbatim.

### Commit + PR

Commit message:

```
chore: release v0.4.0

#27 engine-entry Confidence validation + DefaultTrackedBlock ctor throws.
#20 band-fallback config + stats wired into the engine
    (BandFallbackMode: off | observeOnly | admit; default off).

See CHANGELOG.md for the full entry.
```

After merge, the maintainer runs `flutter pub publish` interactively.
That step is NOT in scope for this spec (requires `pub.dev` credentials
and an interactive y/N prompt).

### Post-release follow-up (not in this spec)

- Bump the downstream consumer's `ocr_stabilizer` constraint to `^0.4.0`
  in the same PR that wires `resetDriftPropagation()` (the consumer's
  adoption unblock).
- Open follow-up issue for corpus-data-driven band-threshold tuning,
  once `observeOnly` mode has produced counter data. (Option A\*
  Confidence-validation cleanup is *not* pre-tracked — see §1; a tracking
  issue is filed only if a concrete reason emerges.)

---

## 6. Non-goals (lock against scope creep)

- **No downstream consumer changes** in this spec. The unblock PR is separate.
- **No `DriftTracker` / `OverlapResolver` API changes.** The default spatial
  predicate reaches into drift state via an engine-internal closure when
  the consumer doesn't supply one; no public surface change.
- **No `qualityScore` weight tuning.** The 0.4 / 0.6 split stays.
- **No public type beyond:** `BandFallbackMode`, `BandFallbackConfig`,
  `BandSpatialPredicate`, `BandFallbackStats` (+ `BandFallbackStatsInternal`,
  package-public for the engine but consumers see only the supertype). No
  default-predicate function exported.
- **No primary `_findMatch` threshold change.** The Lev 0.70 / Jaccard 0.80
  primary floors stay as the high-confidence gate. Band fallback is
  strictly additive.
- **No `Confidence` extension type changes.** The documented unchecked
  primary constructor stays; engine-entry validation closes the gap from
  the outside.

---

## 7. Risks

| Risk                                                                                                                | Mitigation                                                                                                                       |
|---------------------------------------------------------------------------------------------------------------------|----------------------------------------------------------------------------------------------------------------------------------|
| Band default thresholds (0.50 / 0.60) are guesses without corpus data.                                              | Ship `mode: off`. `observeOnly` is the measurement vehicle — counter ratios drive the eventual `admit` flip and threshold tuning. |
| Engine-entry validation adds per-call overhead.                                                                     | One linear pass over observations checking two doubles each. Microbench in the test if a regression appears; otherwise negligible. |
| `DefaultTrackedBlock` ctor + engine-entry guard duplicate work for the common path.                                 | Intentional — ctor produces a clearer stack trace at the right source location; engine guard catches non-`DefaultTrackedBlock` implementors. The redundancy is a feature. |
| `candidateObservationFloor: provisionalCaptures + 1` may surprise consumers who expected `2`.                       | Documented in dartdoc; lowering to `1` or `2` re-enables provisional-on-provisional. Default biases toward conservative.        |
| `BandFallbackStatsInternal` is public to the package — a determined consumer can downcast and mutate.               | Convention, not enforcement; the `Internal` suffix is the signal. Out-of-scope to add a Dart-language private mechanism here.    |
| Option A\* (lifting validation into `Confidence`) would be cleaner but breaks default-parameter-value sites.        | Would require revisiting 0.2.0's const-sentinel trade-off; deferred pending a concrete reason. Tracked in §1 Out of scope.       |
| Provisional admission interacts with drift propagation in unexpected ways.                                          | TDD step 17 explicitly locks the decay path; existing provisional infrastructure carries the load.                              |

---

## 8. Acceptance criteria (release readiness)

- [ ] PR #1 (`fix/27-...`) merged to `main` with green local tests; CHANGELOG draft included.
- [ ] PR #2 (`feat/20-...`) merged to `main` with green local tests; CHANGELOG draft included.
- [ ] PR #3 (`chore/release-0.4.0`) merged to `main`; CHANGELOG `## 0.4.0` header dated; `pubspec.yaml` bumped to `0.4.0`.
- [ ] `dart run dart_pre_publish` / `dart pub publish --dry-run` reports no warnings against the new public surface.
- [ ] **pana score 160/160** against the new public surface — every new
      public symbol (`BandFallbackMode`, `BandFallbackConfig`,
      `BandSpatialPredicate`, `BandFallbackStats`, `BandFallbackStats.reset`,
      every counter getter, every engine ctor/getter addition) has dartdoc
      coverage that holds the documentation score.
- [ ] `git tag v0.4.0` pushed.
- [ ] Maintainer runs `flutter pub publish` (out-of-band).
- [ ] Downstream consumer's adoption issue unblocked (separate PR).

---

## 9. Resolved review items (post-first-round)

This spec was revised after a first-round review. Resolutions, by item:

| # | Reviewer point                                       | Resolution                                                                                                                    |
|---|-------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------|
| 1 | Sentinel-function pattern is a footgun.               | Replaced with nullable `spatialConfirm`; engine substitutes default closure when `null`. No public sentinel.                  |
| 2 | `Confidence` validation gap.                          | Grep confirmed const-context use (default param in `DefaultTrackedBlock`). Engine-entry validation (Option C done properly) catches any `TrackedBlock` implementor; ctor `throw` stays for early-fail; `qualityScore` collapses to debug assert. Cleaner Option A\* deferred pending a concrete reason. |
| 3 | "Count but don't admit" can't deliver instrumentation.| Replaced with `BandFallbackMode.observeOnly` — full loop, all counters, no admission. Real measurement vehicle.               |
| 4 | `candidateObservationFloor: 2` vs `provisionalCaptures: 3` interaction. | Default changed to `provisionalCaptures + 1` (= 4) — semantically "candidate has cleared its own provisional window." Documented; consumers can override. |
| 5 | `BandFallbackStats` public mutable fields.            | Read-only public class with private constructor + private fields + public getters + `reset()`. `BandFallbackStatsInternal` subclass with public mutators; engine holds the Internal, exposes the supertype. |
| 6 | `qualityScore` returning `0.0` collides with legitimate zeros. | Resolved by #2 — guard becomes debug assert; release builds skip; engine entry catches NaN. No magic `0.0` return.          |
| 7 | Local `file:///` links break for everyone else.       | All stripped; rationale inlined where useful.                                                                                 |
| 8 | "Matches the app's value verbatim" reads like coupling. | Reframed throughout: "cited as provenance; the package owns the default thereafter."                                          |
| 9 | No primary-path counter.                              | Added `primaryMatchesAdmitted` + `primaryMatchesRejected` to `BandFallbackStats`. Always tick. Enables "band fires as % of primary misses" from a single read. |
| 10| pana 160/160 not in acceptance.                       | Added to §8.                                                                                                                  |
| 11| Primary floors never stated explicitly.               | Called out in §4 problem section, defaults table, and `BandFallbackConfig` dartdoc.                                           |
