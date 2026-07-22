## 0.7.0 - 2026-07-22

Additive release: the opt-in `agreementWeighted` position-merge
prototype (#58). Default behavior is unchanged — `^0.6.0` consumers can
upgrade without review.

### Added
- `PositionMergeModel` enum and
  `StabilizationEngine(positionMergeModel: ...)` (#58). The default
  `legacy` preserves 0.x numerics exactly. The opt-in
  `agreementWeighted` prototype addresses the audit §1.7 findings:
  - **Merge weight decays with observation count**
    (`fresh / (existing·n + fresh)`): long-observed blocks become
    positionally sticky — a 6-times-confirmed block barely moves for a
    single 12px outlier — while young blocks still adapt quickly.
  - **Merged confidence is a running mean of positional agreement**
    (residual vs the region's drift margin, median-block-height scaled
    when no margin exists) instead of the saturating sum: disagreeing
    observations now reduce confidence, making `qualityScore`'s
    position term informative again for well-observed blocks.
  Rollout mirrors the band-fallback pattern: ship on `legacy`, A/B
  `agreementWeighted` against your captures, adopt when the numbers
  hold. Slated to become the 1.0 default pending that validation.

## 0.6.1 - 2026-07-21

Performance release finishing the remaining #55 items. No API changes.

### Performance
- Intra-batch NMS now resolves overlaps against a per-batch spatial
  grid instead of linearly scanning the whole output per fresh block —
  ~O(n²)·(drift-margin per pair) becomes O(cells) (#55). Behavioral
  nuance: the grid applies the same 3×3-neighborhood locality contract
  the inter-capture matching path already uses, so two blocks whose
  centers sit more than one bucket apart are no longer compared — only
  observable for blocks wider than ~2 buckets, which the spatial index
  documented as out-of-contract in 0.5.1.
- `stabilize()` reuses that batch grid for grouping-contradiction
  detection instead of building a second throwaway index every capture
  (#55). The public `detectGroupingContradictions` now sizes its
  temporary index's buckets from the engine's spatial index rather than
  defaults.
- `DriftTracker.medianDriftForKey` / `medianBlockHeightForKey` /
  `driftMarginForKey` cache per-key results, invalidated on
  `addObservation` and every clearing path — previously each call
  copied and sorted up to 20 samples, several times per block per
  capture (#55).

### Internal
- CI uploads the lcov coverage report as a build artifact from the
  latest-stable leg (#60; badge/coverage-service wiring still open
  there — needs a repo token).
- `flutter_lints` constraint comment updated for the Dependabot-widened
  `>=4.0.0 <7.0.0` range (#63): 4.x resolves on the Dart 3.3 floor,
  newer lines elsewhere.
- Test count: 513.

## 0.6.0 - 2026-07-20

Audit-driven feature-and-fix release implementing the 0.6.0 roadmap
(#46–#56). Pre-1.0, behavioral changes take a minor bump: review the
Breaking section before upgrading from 0.5.x.

### Breaking
- **`CssSubmapMembership.spaceKeyFor` maps viewport-relative (weight 40)
  and nested IC+carousel (weight 30) blocks to `SpaceKey.unknown()`**
  instead of `SpaceKey.normal(...)` (#48). Drift observation and
  correction are now symmetric: a `position:fixed` header no longer
  receives the page-scroll submap's median correction it never
  contributed to. Consumers relying on VR blocks being drift-corrected
  (unlikely — the correction was categorically wrong) must supply a
  custom `SubmapMembership`.
- **`ContradictionEvent`'s constructor is no longer `const` and throws
  `ArgumentError`** when `evidence` has fewer than 2 entries (#51) —
  the storage-invariant policy (throw, not assert) now applies here
  too. Migration: drop `const` from any `ContradictionEvent`
  constructions (engine-produced events are unaffected).
- **Contradiction detectors skip the viewport-relative boundary** (#49):
  `detectGroupingContradictions` ignores VR cached blocks and
  `detectSplittingContradictions` ignores VR fresh blocks. Near scroll
  offset 0, healthy sticky headers were reported as "subdivided" by
  unrelated normal blocks and evicted by consumers.
- **Batch-NMS key lifecycle** (#50): dedup keys register only for
  blocks that survive intra-batch NMS, and an evicted block's key
  retires with it. Dropped blocks no longer fuzzy-suppress later
  same-neighborhood blocks. Eviction lookup is identity-based —
  Equatable-style consumer blocks can no longer cause the wrong
  value-equal element to be replaced.
- **New direct dependency `meta: ^1.11.0`**; dev-dependency
  `flutter_lints` moved `^5.0.0` → `^4.0.0` because 5.x requires Dart
  3.5 and never actually resolved on this package's declared `^3.3.0`
  floor — caught by the new CI floor leg (#56).

### Added
- `StabilizationEngine.missedFrameRetention` (#46): opt-in retention
  window keeping unmatched cached blocks matchable for N further
  `stabilize()` calls, so a single OCR miss (glare, occlusion) no
  longer resets a block's accumulated identity. Default `0` preserves
  0.5.x behavior exactly; retained blocks are never part of
  `stableBlocks`. The `stabilize()` index-ownership docs now tell one
  consistent story.
- `StabilizationEngine.updateViewport(...)` (#52): single validated
  entry point that recomputes the spatial index's adaptive buckets and
  adopts the same dimensions for dedup keys. The `bucketWidth` /
  `bucketHeight` / `scale` setters now throw `ArgumentError` on
  non-finite or non-positive values.
- `DriftTracker.propagationCountFor(spaceKey)` — public reader for the
  counts written via `recordPropagation` (#53).
- `TextVote` implements `==` / `hashCode` / `toString`, matching the
  package's other value types (#53).
- `BandFallbackStatsInternal` is annotated `@internal` — the analyzer
  now flags downcast-mutation from outside the package (#53).

### Deprecated
- `DriftTracker.spaceKeys` — use the identical `observedKeys`; removal
  planned for 1.0 (#53).

### Fixed
- `DriftTracker.clearKey` / `clearSpatialRegion` now also clear the
  matching propagation counts, which previously leaked for the rest of
  the session (#55).

### Performance
- Text-similarity calls (`isTextSimilar`, `isTextSimilarWithScores`,
  `computeTextSimilarity`) extract each string's significant-char list
  once and feed both metric cores — previously up to 6 extractions per
  comparison (#55).

### Internal
- CI matrix now tests the declared minimum floor (Flutter 3.19.6)
  alongside latest stable (#56); Dependabot covers GitHub Actions and
  pub (#60).
- Band admission ordering caveat and `String.hashCode` key-stability
  caveat documented (#53).
- Test backfill (#54): first dedicated suites for `RobustStats`,
  `IqrOutlier`, `OverlapResolver`, `BlockKeyGenerator`, `AbsoluteRect`,
  hierarchy/scroll value types, `CssSubmapMembership`, and `TextVote`;
  real mixed-confidence coverage for `computeTextConfidence`;
  regression tests for every fix above. Test count: 504 (was 297),
  verified on both stable and Flutter 3.19.6.

## 0.5.1 - 2026-07-20

Bug-fix release driven by the v0.5.0 package audit
(`doc/audit/2026-07-20-package-audit.md` in the repository). No API
changes — `^0.5.0` consumers resolve `0.5.1` automatically.

### Fixed
- `SpatialBlockIndex.candidates()` now deduplicates yielded blocks by
  object identity, matching `allBlocks` / `blocksInRegion`. Previously a
  dual-indexed IC block reachable from both its page-absolute cell and
  its `ic:` cell was yielded twice to an IC query — running the full
  Levenshtein comparison twice per duplicate and double-ticking the
  `BandFallbackStats` funnel counters (`candidatesConsidered`,
  `rejectedSpatial`, `rejectedTextBand`, and in observeOnly
  `bandMatchesIdentified`) that consumers are told to read before
  flipping to `admit`.
- `StabilizationEngine` primary matching no longer drops a candidate
  admitted purely through the Jaccard arm with a Levenshtein score of
  0.0 (full character reordering, e.g. a two-character OCR segment swap
  like `北京` → `京北`). The best-candidate scan seeded its comparison
  at 0.0 with a strict `>`, so such a match never registered and the
  observation spawned a duplicate block instead of merging.
- `OcrBlock` now stores a NaN `confidence` as `null` (unavailable). The
  documented clamp could not contain NaN — in IEEE-754,
  `nan.clamp(0.0, 1.0)` returns NaN — so NaN leaked to any consumer
  reading `confidence` directly. Infinite values still clamp to the
  range bounds.
- Unified the package's two divergent CJK-ideograph definitions into one
  shared predicate (`lib/src/internal/cjk_ideographs.dart`). The dedup
  utilities (`cjkOnly`, `cjkFraction`, significant-char extraction)
  omitted CJK Extension B (U+20000–U+2A6DF) while the confidence
  heuristic included it, so text consisting only of Extension-B
  ideographs produced an empty significant-char list and could never
  text-dedup. `TextDedupUtils` and `isCjkIdeograph` now agree.

### Documentation
- `StabilizationEngine.stabilize` documents the index-rebuild
  limitation: blocks not re-observed in a capture leave the spatial
  index and re-enter as new; app-inserted blocks are dropped at the next
  call. The cache-merge redesign is tracked for 0.6.0.
- `classifyGroups` documents its silent fallbacks (degenerate
  `imageToLayoutScale` → identity CSS-per-px; near-singular container
  transform → untransformed rect) and the actual `positionLookup` throw
  contract (caught, neutral stability — previously documented as "must
  not throw").
- `SpatialBlockIndex.blocksInRegion` documents the center-cell +
  1-cell-margin lookup limit for oversized blocks; `remove()` documents
  that cell keys are recomputed from the current rect, so removal after
  mutation silently no-ops.
- `TextDedupUtils.containmentRatio` documents the 5,000-rune LCS
  truncation on the public API (was only on the private helper) and
  drops a stale internal-caller claim.
- `RobustStats.madOrFallback` scopes its "never zero or negative"
  guarantee to positive `minSpread`.
- `MergeResult.observationCount` documents the provisional-freeze
  exception (count passes through unchanged while frozen).

### Internal
- `.pubignore` added: internal process docs (`doc/superpowers/`,
  `doc/audit/`) no longer ship in the published package archive.
- Full package audit report at `doc/audit/2026-07-20-package-audit.md`
  (repository only).
- First dedicated test file for `TextDedupUtils`
  (`test/text_dedup_utils_test.dart`). Test count: 297 (was 277).

## 0.5.0 - 2026-05-24

Quality-polish release. Additive public-API additions plus a latent
engine bug fix in the band-fallback counter accounting. No breaking
changes from 0.4.x — `^0.5.0` is a safe upgrade.

### Added
- `BandPredicateException` — typed wrapper class for throws raised by a
  consumer-supplied `BandSpatialPredicate`. The engine catches the
  predicate's error inside `_findMatch` and rewraps it as
  `BandPredicateException(cause, predicateStackTrace)`. Predicate
  failures now surface with a typed shape; no silent swallow. Exposes
  `cause`, `predicateStackTrace`, `message`, and an asserting ctor that
  rejects double-wrapping (#35).
- `BandFallbackStats.rejectedTextBand` counter ticks at the
  text-band-miss site inside `_findMatch`. Makes the band funnel
  decomposable: `rejectedCandidateFloor + rejectedSpatial +
  rejectedTextBand + bandMatchesIdentified == candidatesConsidered`,
  invariant to admit-mode early-exit (#34).
- Library-level dartdoc in `lib/ocr_stabilizer.dart` now enumerates the
  headline types (`StabilizationEngine`, `BandFallbackConfig`,
  `BandFallbackStats`, `BandPredicateException`, block hierarchy,
  confidence types) plus the recommended adoption flow (off →
  observeOnly → admit) (#35).
- Internal `assertConfidenceRange(field, raw, {prefix})` utility at
  `lib/src/internal/confidence_validation.dart` centralises the
  `[0.0, 1.0]` finite-double predicate. Adopted at five sites:
  `DefaultTrackedBlock` ctor, `MergeResult` ctor,
  `StabilizationEngine._assertValidConfidence` (called by `stabilize`
  and `merge`), `PositionConfidence.from`, `TextConfidence.from`. Future
  tightening happens in one place (#31).

### Changed
- `BandFallbackStats.matchesAdmitted` is now incremented at the
  resolution-time site (where `_findMatch` actually returns a band
  match), not at scan-time. Before this release, the counter ticked as
  soon as a candidate was locked as `bandAdmitted` — so when a later
  primary candidate in the same scan superseded it, the counter
  overcounted and disagreed with the function's return value. New
  semantics: `matchesAdmitted` is exactly "band matches returned by
  `_findMatch`", and the documented invariant
  `matchesAdmitted <= bandMatchesIdentified` is strengthened by the
  precedence rule "primary always wins, even if a band candidate was
  locked first" (#34).
- `MergeResult` ctor's confidence-range error message wording upgraded
  from `'must be in [0.0, 1.0]'` to
  `'must be a finite double in [0.0, 1.0]'` to match the message at the
  engine entry guard and `DefaultTrackedBlock` ctor — a consumer
  catching `ArgumentError` no longer sees two slightly different
  stories about the same invariant (#31).

### Fixed
- Library dartdoc no longer references a non-existent
  `stabilize(fresh, captureRect)` signature — the actual signature is
  `stabilize(List<T> freshBlocks)`. Caught by the comment-analyzer
  pass on PR #42 (#35).
- Privacy scrub: removed 17 references to the downstream consumer's
  internal project name / file:line paths from spec/plan docs and one
  source comment (#33).

### Internal
- New CI job: pana scoring on ubuntu-latest with
  `--exit-code-threshold 0` pinned to pana `0.23.12`. Authoritative
  pre-publish score check — Windows local pana hits 150/160 due to
  upstream `dart-lang/dartdoc` issue #4180 (CRLF offsets in Flutter
  SDK `@docImport` files), but Linux scoring is 160/160 (#36).
- Renamed `docs/` → `doc/` for the Pub layout-convention hint (#37).
- Test count: 277 (was 270 in v0.4.0).

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
