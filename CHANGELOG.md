## 0.4.0 - 2026-05-23

### Added
- `BandFallbackMode` enum (`off` | `observeOnly` | `admit`) configures the
  band-relaxed fallback path inside `StabilizationEngine._findMatch`.
  Default is `off`; switch to `observeOnly` to read `BandFallbackStats`
  before committing to `admit`. See `doc/superpowers/specs/` for the
  full design and default provenance (#20).
- `BandFallbackConfig` value type wraps the band thresholds, candidate
  observation floor, provisional-capture grant, and spatial confirmation
  predicate. Constructor `assert`s on out-of-range values (preserves
  const-constructibility); engine constructor throws `ArgumentError` for
  release-build safety. Primary-path floors (Lev 0.70 / Jaccard 0.80) are
  engine-owned, not configurable through this type (#20).
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

### Changed
- **Breaking:** `StabilizationEngine.stabilize()` and
  `StabilizationEngine.merge()` now throw `ArgumentError` if any
  observation's `positionConfidence.raw` or `textConfidence.raw` is
  `NaN` or outside `[0.0, 1.0]`. Catches any `TrackedBlock` implementor
  at the engine entry, closing the documented unchecked-`const`-Confidence
  gap (#27).
- **Breaking:** `DefaultTrackedBlock` constructor throws `ArgumentError`
  when `positionConfidence.raw` or `textConfidence.raw` is `NaN` or
  outside `[0.0, 1.0]`. Early-fail at construction with a cleaner stack
  trace than the engine-entry guard would produce. Consumers going through
  `PositionConfidence.from()` / `TextConfidence.from()` (validated since
  #19) are unaffected (#27).
- `StabilizationEngine._findMatch` primary path now uses
  `TextDedupUtils.isTextSimilarWithScores` (Lev OR Jaccard) instead of
  `normalizedLevenshtein` alone. Floors are unchanged (Lev 0.70 /
  Jaccard 0.80); the metric set widens — character-reordered text with
  the same significant-character set now matches on the primary path
  where it previously fell through (#20).

### Fixed
- `OverlapResolver.qualityScore` no longer silently propagates `NaN` into
  the NMS comparison. NaN reaching `qualityScore` is now a debug-time
  `AssertionError`; release builds skip the check (defended by engine
  entry validation, above) (#27).
- `StabilizationEngine` constructor now rejects `NaN` and `±Infinity` for
  `BandFallbackConfig.bandLevenshteinFloor` and `bandJaccardFloor` in
  release builds. The bare range check (`value < 0 || value >= floor`)
  evaluated `false` for `NaN` under IEEE 754 and let it bypass the
  defense; the `assert` in the const ctor catches it in debug only. Now
  short-circuits on `!isFinite` before the range check (#20).

## 0.3.0

A breaking release bundling four API changes. Pre-1.0, breaking changes
take a minor version bump.

### Breaking
- `ObservableBlock` no longer declares `exclusionHitCount`, and
  `DefaultTrackedBlock` no longer carries it. The field was inert
  engine-side — never read or written by merge, dedup, drift correction,
  or the spatial index. It is consumer-managed state and does not belong
  on the package's block contract. Migration: a consumer with
  `@override int get exclusionHitCount;` on its own block class removes the
  `@override` annotation — the field stays, it is just no longer an
  interface member. Consumers that do not need the field drop it entirely.
  (#23)
- `PositionConfidence.from` / `TextConfidence.from` now throw `ArgumentError`
  on out-of-range **or NaN** input. Previously they validated with `assert`
  only, which is stripped in release builds — an invalid confidence passed
  silently in production. Migration: catch `ArgumentError` instead of
  `AssertionError`; any code that relied on release-mode silent acceptance
  of an out-of-range value now gets a thrown exception. The primary
  `const PositionConfidence(double)` / `const TextConfidence(double)`
  constructor stays public and unchecked — it is the only `const`-capable
  path, kept for `const` literal sentinels. (#26)

### Changed
- `StabilizationEngine.stabilize()` now rebuilds `spatialIndex` internally
  from its returned `stableBlocks` before returning. The old caller
  contract (call `spatialIndex.rebuild(result.stableBlocks)` after every
  `stabilize()`) is retired, along with the debug-mode staleness guard.
  Callers can drop the post-`stabilize()` rebuild call — a redundant
  rebuild is harmless, so this is non-breaking. (#24)
- `MergeResult`'s confidence boundary checks now also reject NaN (NaN fails
  both `< 0` and `> 1.0`, so it previously slipped through). (#26)

### Added
- `StabilizationEngine.resetDriftPropagation()` — clears the engine's
  regional-drift baseline so a consumer can reset propagation state on a
  session boundary (page navigation, context reset) without a stale
  baseline triggering a spurious correction. (#25)

## 0.2.2

### Added
- CI: GitHub Actions workflow running `flutter analyze` + `flutter test` on
  push and PR (#15).
- `CONTRIBUTING.md` documenting dev setup, conventions, and release flow (#16).

## 0.2.1

Docs + metadata polish. No API change. First pub.dev-shipped release of the
v0.2.x line.

### Documentation
- README: install snippet updated to `^0.2.1` with a breaking-change pointer
  back to the 0.2.0 typed-confidence migration. (#14)
- README: `TrackedBlock<T>` example now lists all 14 getters (was missing
  `innerScrollerTop`, `sourceQuality`) with a follow-up note pointing
  integrators at `DefaultTrackedBlock<T>` or `ObservableBlock<T>` as
  appropriate. (#14)
- README: API Reference tables refreshed for v0.2.x — corrected getter
  count, generic on `ObservableBlock<T>`, documented `DefaultTrackedBlock<T>`,
  `PositionConfidence`, `TextConfidence`, plus the previously-undocumented
  exports (`StabilizationEngine`, `BlockClassifierService`, `OverlapResolver`,
  `BlockKeyGenerator`, `MergeResult`, `StabilizationResult`,
  `ClassificationResult`, `TextVote`, `IqrOutlier`, `TextDedupUtils`). (#14)

### Metadata
- `pubspec.yaml` gains `homepage:` and pub.dev `topics:` (`ocr`, `overlay`,
  `tracking`, `slam`, `flutter`). (#14)
- `.gitignore` excludes local agentic-scaffolding directory (`.ultra/`). (#14)

## 0.2.0

### Breaking
- `TrackedBlock.positionConfidence` and `textConfidence` now return typed
  `PositionConfidence` / `TextConfidence` extension types (over `double`)
  instead of raw `double`. Consumers implementing `TrackedBlock` must
  update the getter signatures. The migration path:
  ```diff
  - final double positionConfidence;
  - final double textConfidence;
  + final PositionConfidence positionConfidence;
  + final TextConfidence textConfidence;
  ```
  Producer sites wrap raw doubles via `.from(value)` (range-asserted),
  or use the `.groundTruth` sentinel (= 1.0) for deterministic origins.
  Extension types are zero-cost at runtime.

### Added
- `PositionConfidence` / `TextConfidence` extension types in
  `lib/src/types/confidence_types.dart`. Range `[0.0, 1.0]` enforced via
  `.from()` factory; `.groundTruth` static const sentinel for DOM/deterministic
  origins. (#10)
- `DefaultTrackedBlock<T>` — concrete reference implementation of
  `ObservableBlock<T>` with documented defaults for every required field
  (notably `carouselIdVotes: {-1: 1}` — the engine's phantom-vote sentinel).
  Includes `copyWith` and `applyMerge(MergeResult)` convenience. (#5)
- `SpatialBlockIndex.isEmpty` — O(1) accessor (was: `allBlocks.isEmpty`
  allocated a `Set.identity()` per call). (#2)
- `StabilizationEngine.stabilize()` debug-mode staleness warning when
  the spatial index appears empty after a non-empty previous call, plus
  prominent "Caller contract" docstring documenting the consumer's
  rebuild responsibility. (#2)
- `MergeResult` now throws `ArgumentError` (not just `assert`) when
  invariants are violated, including the confidence-range bypass via
  the unvalidated `PositionConfidence(double)` primary constructor.
  Asserts strip in release; this guards engine output that flows into
  consumer caches. (#10)

### Changed
- SDK constraint relaxed from `sdk: ^3.8.1` to `sdk: ^3.3.0` (extension
  types shipped in Dart 3.3 — the only modern feature this package uses).
  `flutter` constraint pinned to `>=3.19.0` (the Flutter that bundled
  Dart 3.3). `flutter_lints` dev-dep pinned to `^5.0.0` to keep dev-deps
  SDK floor consistent with the package SDK floor. (#3)
- `DriftTracker` rolling windows switched from `List` (O(N) `removeAt(0)`)
  to `dart:collection`'s `Queue` (O(1) `removeFirst`). Type now signals
  FIFO ring-buffer intent at the declaration site. (#4)
- `DefaultTrackedBlock` constructor throws `ArgumentError` (not just
  asserts) when the `containerId` / `isInnerScrollerChild` invariant
  is violated — the reference implementation is state-owning, asserts
  strip in release. (#5)

### Fixed
- `SpaceKey.regionIndex` returns 0 as a safe fallback instead of throwing
  `FormatException` on malformed keys (forward-compat for externally-
  constructed or future-format-extension keys). (#1)

### Internal
- New test files: `test/space_key_test.dart`, `test/confidence_types_test.dart`,
  `test/merge_result_test.dart`, `test/default_tracked_block_test.dart`.
  Test count: 207 (was 180 in v0.1.0).

## 0.1.0

Initial release.

### Core
- `StabilizationEngine` — SAR merge, intra-batch dedup, contradiction detection
- `DriftTracker` — regional drift correction with submap isolation
- `SpatialBlockIndex` — grid-cell spatial index for O(cells) overlap queries
- `OverlapResolver` — spatial NMS with language-aware thresholds
- `BlockKeyGenerator` — position+text dedup keys with fuzzy neighbor matching
- `BlockClassifierService` — OCR group classification (fixed/sticky/carousel/IC/normal)

### Types
- `TrackedBlock<T>` / `ObservableBlock<P>` — block identity interfaces
- `AbsoluteRect` — zero-cost coordinate-space safety (extension type)
- `SpaceKey`, `ContainerId`, `ScrollContext`, `StickyFallback` — value types

### Utilities
- `TextDedupUtils` — Levenshtein, Jaccard, CJK detection
- `RobustStats` — median, MAD, IQR
- `IqrOutlier` — Tukey fence outlier detection
