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
