# Package audit — ocr_stabilizer v0.5.0

**Date:** 2026-07-20
**Scope:** full `lib/` source (~4,700 lines), `test/` suite (26 files, 277 tests),
packaging (`pubspec.yaml`, CI, pub.dev state), docs (`README`, `CHANGELOG`,
dartdoc).
**Method:** static review. Findings marked **[verified]** were re-checked
line-by-line against the source; the rest were confirmed by at least one full
read of the file in question.

Overall: the package is in unusually good shape for a 0.x — 160/160 pub
points, disciplined CHANGELOG/release flow, strong dartdoc, a well-argued
throw-vs-assert policy, and clean extension-type usage. The findings below are
ranked by how much they matter, not by how many there are.

---

## 1. Correctness

### 1.1 `stabilize()` drops every tracked block not re-observed this frame — [verified]

`stabilization_engine.dart:281` — `spatialIndex.rebuild(stableBlocks)` rebuilds
the index from **only this frame's output**, and the index is the sole source
of match candidates (`_findMatch` → `spatialIndex.candidates`, line 461).

A block seen in frame N, missed by OCR in frame N+1 (glare, occlusion,
partial scroll), and re-seen in frame N+2 finds no candidate and is treated as
brand new: `observationCount` resets, text votes and drift lineage are lost.
This works against the engine's core purpose, and the docs contradict each
other about who owns the index: line 34 says "the app owns cache management",
lines 47–56 document an insertion seam, but lines 235–237 say the engine
rebuilds internally — so anything the app inserts is wiped on the next call.

**Fix:** rebuild from `existing survivors ∪ stableBlocks` (with an app-supplied
eviction hook), or accept a `cachedBlocks` parameter on `stabilize()`, or merge
into the index instead of clearing it. Whatever the choice, make the ownership
docs agree with the code. This is the single highest-value change in the audit.

### 1.2 `SpatialBlockIndex.candidates()` yields dual-indexed IC blocks twice — [verified]

`spatial_block_index.dart:182–199` — unlike `allBlocks` (line 145) and
`blocksInRegion` (line 167), `candidates()` has no identity de-dup. IC blocks
are dual-indexed; when the query block is also IC, a nearby IC candidate is
reachable from both its absolute cell and its `ic:` cell and is yielded twice.

Consequences in `_findMatch`: the full Levenshtein DP runs twice per duplicate,
and every band counter (`candidatesConsidered`, `rejectedSpatial`,
`rejectedTextBand`, `bandMatchesIdentified` in observeOnly) ticks twice —
corrupting exactly the ratios `BandFallbackStats` tells consumers to read
before flipping to `admit`.

**Fix:** add the same `Set<T>.identity()` seen-check the sibling methods use.
One-line fix plus a regression test.

### 1.3 Jaccard-only primary matches with Levenshtein 0.0 are silently lost — [verified]

`stabilization_engine.dart:465,485` — `bestPrimarySim` seeds at `0.0` and the
update is strict `>` on `scores.levenshtein`. A candidate can have
`scores.match == true` purely via the Jaccard arm with `levenshtein == 0.0`
(e.g. short reordered CJK: "北京" vs "京北" → edit distance 2/2 → lev 0.0,
Jaccard 1.0 — precisely the OCR-noise case Jaccard exists for). If that is the
only matching candidate, `primaryMatch` stays null and the observation is
treated as new or falls to the band path.

**Fix:** seed at `-1.0`, or track "any match seen" separately from the ordering
score.

### 1.4 `DefaultTrackedBlock.copyWith` cannot demote an IC block or clear `containerId` — [verified]

`default_tracked_block.dart:162–213` with the ctor guard at 143–151.
`containerId ?? this.containerId` means null can never be restored, so
`block.copyWith(isInnerScrollerChild: false)` on any IC block carrying a
`containerId` throws `ArgumentError` from the constructor invariant. Any
consumer reclassification path that demotes an IC block via `copyWith` crashes.

**Fix:** sentinel-based `copyWith` (`Object? containerId = _unset`) or a
dedicated `demote()`/`clearContainerId()` API, plus a regression test.

### 1.5 Viewport-relative and nested blocks receive page-scroll drift corrections

`css_submap_membership.dart:26–39` — `spaceKeyFor` only special-cases
`hierarchyWeight == 20`; VR (40) and nested IC+carousel (30) blocks fall
through to `SpaceKey.normal(...)`, and the engine then applies that submap's
median page-scroll drift to them (`stabilization_engine.dart:689–694`). A
`position:fixed` header gets shifted by page-scroll drift, which by definition
does not apply to it. The class doc says these tiers are "excluded" — they are
excluded only from observation, not correction.

**Fix:** return `SpaceKey.unknown()` for weights ≥ 30 (or at minimum for VR),
or document the asymmetry precisely. Add a direct `CssSubmapMembership` test —
today the class has none.

### 1.6 Contradiction detectors ignore the VR coordinate boundary

`stabilization_engine.dart:875–916` (grouping) and 939–963 (splitting) —
`OverlapResolver.checkOverlap` explicitly refuses VR↔non-VR comparison, but
neither contradiction detector filters on `isViewportRelative`. Near scroll
offset 0 (where the coordinate spaces numerically coincide), a healthy sticky
header can be reported "subdivided" by unrelated normal blocks and evicted by
the consumer.

**Fix:** `continue` on `isViewportRelative` mismatch; consider IC
scroller-relative Y here too (the matching path handles it; this path doesn't).

### 1.7 Merged position confidence saturates at 1.0 after two observations

`stabilization_engine.dart:697–699,797` — `totalConf = existing + fresh`,
clamped to 1.0: two 0.5-confidence observations produce full confidence
regardless of positional agreement, and the merge weight
`w = fresh/(existing+fresh)` locks near ~0.33 forever — a 100-times-observed
block still moves ~33% toward every noisy rect, so jitter never fully damps.
`qualityScore`'s 0.4 position weight also becomes uninformative for any
twice-seen block.

**Fix (design change):** derive confidence from positional agreement (residual
vs drift margin) and/or use a 1/n-style weight decay driven by
`observationCount`.

### 1.8 Provisional freeze discards fresh evidence and contradicts `MergeResult` docs

`stabilization_engine.dart:651–670` — during the freeze, merges return the
old `observationCount` (no +1) and drop the fresh rect, text vote, and drift
observation. The block's count stalls for `provisionalCaptures` frames —
delaying well-observed status and keeping it under the band candidate floor
longer than `band_fallback_config.dart:156–157` implies — and
`MergeResult.observationCount`'s doc ("Total observation count after this
merge") is false on this path. If freezing is intended, document it at both
sites; consider still recording text votes so the grace window gathers
evidence.

### 1.9 Batch-NMS eviction uses value-equality `indexOf` and pollutes `seenKeys`

`stabilization_engine.dart:389,404` — `out[out.indexOf(overlapping)] = b` uses
`==`; the index's own docs anticipate Equatable consumer blocks, in which case
the wrong (value-equal) element can be replaced. Separately, `seenKeys.add`
happens before NMS, so a dropped block's key still fuzzy-suppresses later
same-frame blocks. **Fix:** identity-based lookup; add the key only after the
block is actually kept.

### 1.10 Smaller confirmed issues

- **`OcrBlock.confidence` NaN survives the documented clamp**
  (`ocr_block.dart:50–57`): `nan.clamp(0.0, 1.0)` is NaN in Dart. Guard with
  `isFinite` before clamping.
- **CJK Extension B inconsistency** (`text_dedup_utils.dart:45–49,75–82` vs
  `confidence.dart:163–167`): dedup omits U+20000–U+2A6DF, confidence includes
  it. Text that is only Ext-B ideographs produces an empty significant-char
  list and can never text-dedup. Share one CJK predicate.
- **`ContradictionEvent` uses `assert` for its `evidence.length >= 2`
  invariant** (`stabilization_result.dart:60–68`) — contradicts the package's
  own documented throw-in-release policy (`merge_result.dart:91–95`).
- **Misnamed test masks an untested path**: `confidence_test.dart:121–138`
  ("mixed confidence (some null)") actually constructs all-null blocks; the
  real mixed-confidence weighting in `computeTextConfidence` is untested.

---

## 2. API design

- **Mutable collaborators exposed** (`stabilization_engine.dart:43,57`):
  `driftTracker` and `spatialIndex` are public mutable fields; the "known
  seam" comment admits the leak, and finding 1.1 makes the index
  simultaneously "yours to write" and "mine to overwrite". Prefer a read-only
  query facade and keep the index private.
- **Three uncoordinated quantization knobs**: engine `bucketWidth`/
  `bucketHeight`/`scale` (public, settable, unvalidated — no NaN/≤0 checks
  despite the #27 hardening theme), `SpatialBlockIndex.updateBucketSizes`, and
  `DriftTracker.regionSize`. Updating one but not the others silently degrades
  matching. Provide one validated `engine.updateViewport(...)` that fans out.
- **`BandFallbackStats` mutability by downcast**: `BandFallbackStatsInternal`
  is reachable by consumers. Annotate `@internal` (package:meta) or drop it
  from the export surface.
- **Duplicate getters** `DriftTracker.observedKeys` / `spaceKeys`
  (`drift_tracker.dart:63,135`) — identical live views of internal state.
  Deprecate one; return an unmodifiable snapshot.
- **Non-deterministic band admission**: "first qualifying admit wins" over
  hash-map iteration order (`stabilization_engine.dart:498,545`) — which
  candidate wins can vary run-to-run. Score band candidates like the primary
  path, or document the non-determinism.
- **`TextVote` lacks `==`/`hashCode`** while sibling value types
  (`ScrollContext`, `StickyFallback`) implement them — inconsistent and makes
  consumer-side vote-map assertions awkward.
- **`String.hashCode` in dedup keys** (`block_key.dart:130–132`) is not stable
  across Dart runtimes. Fine in-process; a landmine if keys are ever
  persisted. Document, or switch to FNV-1a.
- **`BlockKeyGenerator.keyWithPrefix` silently ignores the prefix for VR
  blocks** (`block_key.dart:35–47`) — document on the method, not just the
  class.

---

## 3. Performance

Nothing alarming at 1–2 Hz, but the hot path has avoidable churn:

- **Significant-char lists rebuilt up to 6× per comparison**
  (`text_dedup_utils.dart:194` guard, `normalizedLevenshtein` 90–91,
  `jaccardSimilarity` 129–130 — each extracts both strings). Compute once per
  string and thread through; multiplied by finding 1.2's duplicate candidates
  this is the dominant per-frame waste. (The DP cores themselves are properly
  space-optimized — good.)
- **Batch NMS is O(n²)** (`stabilization_engine.dart:430–444`): linear scan of
  `out` per fresh block with `driftMarginForKey` (two sorts of up to 20
  samples) per call — ~45k `checkOverlap` calls for a 300-block frame. The
  package already has a grid index; use one per batch.
- **Throwaway `SpatialBlockIndex` built every frame** for grouping detection
  (`stabilization_engine.dart:869–870`), on top of the main rebuild.
- **Per-call median sorts**: `medianDriftForKey` / `medianBlockHeightForKey` /
  `driftMarginForKey` each `toList()`+sort per call, several times per block.
  Cache per-key medians, invalidate on `addObservation`.
- **Unbounded key maps**: `_lastRegionalDrift`
  (`stabilization_engine.dart:294`) and `_propagationCounts`
  (`drift_tracker.dart:60`) grow per distinct `SpaceKey` for the session;
  `clearKey`/`clearSpatialRegion` forget the propagation counts.

---

## 4. Test coverage

Well covered: engine (10 files), band fallback (all three modes + release
validation), drift tracker, spatial index, classifier, confidence,
merge/default-block invariants.

Zero dedicated tests (grep-confirmed) for exported components:

| Component | Risk |
|---|---|
| `TextDedupUtils` | Core dedup math (Levenshtein, Jaccard, containment/LCS, punctuation guards) — the engine's matching floor rests on it |
| `RobustStats`, `IqrOutlier` | Entire statistical layer (fallback chains, adaptive k, even/odd medians) |
| `BlockKeyGenerator` | Key format, VR path, neighbor keys, prefix override |
| `OverlapResolver` | Only the NaN debug-assert is tested; resolution logic isn't |
| `CssSubmapMembership` | Only indirect coverage; the tier fall-through (finding 1.5) has no test |
| `TextVote`, `AbsoluteRect`, `HierarchyWeightX`, `ScrollContext`/`StickyFallback` equality | Small value types, cheap to cover |

---

## 5. Documentation mismatches

- `stabilization_engine.dart:235–237` ("callers no longer rebuild") vs
  299–305/329 (drift propagation instructs the app to shift blocks and
  "rebuild the spatial index") — the two workflows contradict (see 1.1).
- `block_classifier.dart:57–58` says `positionLookup` "must not throw", yet
  the service catches and neutralizes throws at 285–296. Pick one contract.
- `block_classifier.dart:69,384–385` — silent fallbacks (scale ≤ 0.001 →
  `cssPerPx = 1.0`; singular matrix → untransformed rect) are undocumented in
  `classifyGroups`.
- `spatial_block_index.dart:162–178` — `blocksInRegion`'s fixed 1-cell margin
  misses blocks wider than ~2 cells; `remove()` recomputes the cell from the
  *current* rect and silently no-ops if the rect changed since `add`.
- `text_dedup_utils.dart:216–217` — public `containmentRatio` doc bakes in an
  internal-caller claim; the 5,000-rune LCS truncation is documented only on
  the private helper.
- `ocr_block.dart:50–51`, `robust_stats.dart:153`, `merge_result.dart:54` —
  see findings 1.10, 2, and 1.8.

---

## 6. Packaging, CI, repo hygiene

Current state is strong (160/160 pub points, pinned pana guard, tidy
releases). Gaps:

1. **CI never exercises the declared floor.** `sdk: ^3.3.0` /
   `flutter: '>=3.19.0'`, but both jobs use `channel: stable` only. A
   compile-time use of a post-3.3 feature would ship unnoticed. Add a matrix
   leg with `flutter-version: 3.19.x`.
2. **Internal planning docs ship in the published package.**
   `doc/superpowers/plans|specs` goes to pub.dev (pub includes `doc/`). Add a
   `.pubignore` for `doc/superpowers/` — trims the archive and keeps internal
   process docs out of the artifact.
3. **No Dependabot/Renovate** for GitHub Actions or pub deps
   (`actions/checkout@v4`, `subosito/flutter-action@v2` unpinned by SHA).
4. **Missing v0.4.0 GitHub Release** — the tag exists but has no release
   entry; v0.2.0/0.2.1/0.3.0/0.5.0 all do.
5. **No coverage reporting** — `flutter test --coverage` + a badge would make
   the section-4 gaps visible.
6. **Consider decoupling from Flutter.** The only Flutter dependency is
   `dart:ui` `Rect`/`Offset`. A pure-Dart geometry type (or a tiny own
   `record`-based rect) would make this a pure Dart package: usable server
   side (PDF/camera pipelines mentioned in the README), testable with
   `dart test`, faster CI. Breaking, so pre-1.0 is the time.

---

## 7. Suggested roadmap

**Patch (0.5.1):** 1.2 candidates de-dup, 1.3 similarity seed, 1.10 NaN clamp
+ CJK predicate unification, doc mismatches (§5), missing v0.4.0 release,
`.pubignore`.

**Minor (0.6.0):** 1.1 index/cache ownership redesign, 1.4 `copyWith`
sentinel, 1.5/1.6 VR guards, 1.9 NMS fixes, §2 API cleanups
(`updateViewport`, private index, `@internal` stats), test backfill for §4,
CI floor matrix.

**Toward 1.0:** 1.7 confidence/weight model, Flutter decoupling decision, then
freeze the `TrackedBlock`/`ObservableBlock`/`MergeResult` surface.
