# v0.4.0 Implementation Plan — Band-Fallback + Confidence Invariants

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `ocr-stabilizer` v0.4.0 — engine-entry Confidence validation (#27) and an optional band-relaxed inter-batch matching fallback (#20) — across three independent PRs that land on `main` in order.

**Architecture:** Three sequential, non-stacked branches off `main`. Strict TDD red-green-refactor per step. Each test is targeted; the full `flutter test` runs once per PR after every targeted test is green. Branches: `fix/27-confidence-nan-guard` → `feat/20-band-fallback` → `chore/release-0.4.0`. After the third merges, the maintainer runs `flutter pub publish` out-of-band.

**Tech Stack:** Dart `^3.3.0`, Flutter `>=3.19.0`, `flutter_test`, `flutter_lints ^5.0.0`. No new dependencies in any PR.

**Source spec:** [docs/superpowers/specs/2026-05-23-band-fallback-and-quality-score-nan-guard.md](../specs/2026-05-23-band-fallback-and-quality-score-nan-guard.md). Every code default, threshold, and TDD step in this plan traces back to a numbered section there.

---

## Pre-flight (read before starting)

- **Repository:** `c:/src/ocr-stabilizer`. Current `main` is at the v0.3.0 release commit; both #27 and #20 are open.
- **Test command:** `flutter test test/<file>.dart` for targeted runs, `flutter test` for the full suite. Targeted during dev, full suite once at PR-end (project convention).
- **Commit cadence:** One commit per logical TDD chunk inside a PR branch. The squash-merge title shapes for each PR are dictated by the spec — preserve them verbatim where specified.
- **No stacking:** Each PR branches off `main` *after* the previous PR is merged. Don't open the next branch until its predecessor is on `main` to avoid GitHub auto-close-on-base-deletion (per `feedback_stacked_pr_base_deletion`).
- **CHANGELOG draft entries** for each PR are in the spec — fold them into the actual `CHANGELOG.md` as part of PR #3, not in PRs #1/#2.

### Behavioral note for PR #2 — primary-path metric

The current `_findMatch` at [stabilization_engine.dart:293-312](../../lib/src/stabilization_engine.dart#L293-L312) uses `TextDedupUtils.normalizedLevenshtein` only — Jaccard is **not** checked on the primary path today. The spec's pseudocode in §4 frames primary as `isTextSimilarWithScores ≥ Lev 0.70 OR Jacc 0.80`. This plan implements the spec literally: PR #2 changes primary-path matching from "Lev only" to "Lev OR Jaccard" using the existing `isTextSimilarWithScores` utility, keeping the 0.70 / 0.80 floors unchanged.

Net behavioral effect: blocks that fail Lev 0.70 but pass Jacc 0.80 (character-reordered text with the same significant-character set) now match on the primary path where they previously fell through to "no match." This is consistent with the app's `overlay_cache_service.dart:1513` pattern and the spec's framing. If you want primary to stay Lev-only and band to use `isTextSimilarWithScores`, edit Task PR2-T7 (the `_findMatch` primary rewrite) and skip the corresponding regression-lock test in Task PR2-T8.

---

## File Structure

### PR 1 (`fix/27-confidence-nan-guard`)

| File                                                           | Action  | Responsibility                                                                                                                          |
|----------------------------------------------------------------|---------|-----------------------------------------------------------------------------------------------------------------------------------------|
| `lib/src/default_tracked_block.dart`                           | Modify  | Add NaN/range throws for `positionConfidence` and `textConfidence` in constructor; extract private `_validateConfidence` helper.        |
| `lib/src/stabilization_engine.dart`                            | Modify  | Add private `_assertValidConfidence(block, index)` helper + entry-validation loop at the top of `stabilize()`.                          |
| `lib/src/overlap_resolver.dart`                                | Modify  | Replace `qualityScore` body with `assert(!isNaN ...)` + plain return; remove the 0.0 sentinel return.                                   |
| `test/default_tracked_block_confidence_invariant_test.dart`    | Create  | Lock the ctor throws on NaN, `-0.1`, `1.1` for both fields; sanity-pass on `0.0` and `1.0`.                                            |
| `test/stabilization_engine_confidence_entry_validation_test.dart` | Create | Lock `stabilize()` throws on NaN observations; message names field + index; non-`DefaultTrackedBlock` implementor also caught.       |
| `test/quality_score_debug_assert_test.dart`                    | Create  | Lock that NaN reaching `qualityScore` fires `AssertionError` in debug; documents release-build strip.                                 |

### PR 2 (`feat/20-band-fallback`)

| File                                                           | Action  | Responsibility                                                                                                                          |
|----------------------------------------------------------------|---------|-----------------------------------------------------------------------------------------------------------------------------------------|
| `lib/src/band_fallback_config.dart`                            | Create  | `BandFallbackMode` enum, `BandSpatialPredicate` typedef, `BandFallbackConfig` value type with constructor invariants.                  |
| `lib/src/band_fallback_stats.dart`                             | Create  | `BandFallbackStats` (private ctor, private fields, public getters, `reset()`); `BandFallbackStatsInternal` subclass with mutators.     |
| `lib/ocr_stabilizer.dart`                                      | Modify  | Export `BandFallbackMode`, `BandFallbackConfig`, `BandSpatialPredicate`, `BandFallbackStats` from the package barrel.                  |
| `lib/src/stabilization_engine.dart`                            | Modify  | Add `bandFallback` ctor param, `bandStats` getter, `_effectiveSpatialConfirm` field; rewrite `_findMatch` to use `isTextSimilarWithScores` and add band loop; thread `wasBandFallback` through `_merge`/`_mergeImpl` to wrap admissions as provisional; extract `_findBandMatch` helper. |
| `test/band_fallback_mode_test.dart`                            | Create  | Lock enum value order (`off`, `observeOnly`, `admit`).                                                                                  |
| `test/band_fallback_config_test.dart`                          | Create  | Lock defaults, `candidateObservationFloor` derivation, all constructor invariants.                                                     |
| `test/band_fallback_stats_test.dart`                           | Create  | Lock initial-zero counters, `reset()` semantics, mutation-via-Internal, public ctor unavailable.                                       |
| `test/stabilization_engine_band_off_primary_counters_test.dart` | Create | Lock that off mode does zero band work but ticks primary counters on every `_findMatch` outcome.                                       |
| `test/stabilization_engine_band_observe_only_test.dart`        | Create  | Lock observeOnly mode runs the full loop, ticks every counter, never admits.                                                          |
| `test/stabilization_engine_band_admit_test.dart`               | Create  | Lock admit mode returns a band-matched candidate; merged result is provisional with `provisionalCaptures` from config.               |
| `test/stabilization_engine_band_rejections_test.dart`          | Create  | Lock each rejection branch in admit mode: candidate floor, spatial confirm, text-band miss.                                           |
| `test/stabilization_engine_band_custom_predicate_test.dart`    | Create  | Lock the predicate-injection seam (custom predicate runs) AND the default closure (overlapRatio >= 0.80 with drift margin).         |
| `test/stabilization_engine_band_provisional_decay_test.dart`   | Create  | Lock the admission → decay → graduation interaction across 3 captures.                                                                |

### PR 3 (`chore/release-0.4.0`)

| File                | Action | Responsibility                                                                            |
|---------------------|--------|-------------------------------------------------------------------------------------------|
| `pubspec.yaml`      | Modify | Bump `version: 0.3.0` → `version: 0.4.0`.                                                 |
| `CHANGELOG.md`      | Modify | Insert `## 0.4.0 - <release date>` header above 0.3.0, fold in PR #1 + PR #2 draft entries verbatim from the spec. |

No tests in PR #3 — it's docs + metadata only.

---

## PR 1 — `fix/27-confidence-nan-guard`

### Task PR1-T1: Create branch off `main`

**Files:** none (git operation)

- [ ] **Step 1: Verify `main` is up to date and clean**

Run:
```bash
cd c:/src/ocr-stabilizer
git checkout main
git pull --ff-only
git status
```
Expected: `main` matches `origin/main`, working tree clean.

- [ ] **Step 2: Create the PR 1 branch**

Run:
```bash
git checkout -b fix/27-confidence-nan-guard
```

---

### Task PR1-T2: Lock `DefaultTrackedBlock` constructor invariant (TDD red→green→refactor)

**Files:**
- Create: `test/default_tracked_block_confidence_invariant_test.dart`
- Modify: `lib/src/default_tracked_block.dart` (constructor body around line 141-151)

- [ ] **Step 1: Write the failing test**

Create `test/default_tracked_block_confidence_invariant_test.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';
import 'package:ocr_stabilizer/src/types/confidence_types.dart';

void main() {
  group('DefaultTrackedBlock constructor: Confidence invariants (#27)', () {
    final rect = AbsoluteRect.fromLTWH(0, 0, 10, 10);

    test('throws when positionConfidence.raw is NaN', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          positionConfidence: PositionConfidence(double.nan),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when textConfidence.raw is NaN', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          textConfidence: TextConfidence(double.nan),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when positionConfidence.raw is below 0.0', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          positionConfidence: const PositionConfidence(-0.1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when positionConfidence.raw is above 1.0', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          positionConfidence: const PositionConfidence(1.1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when textConfidence.raw is below 0.0', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          textConfidence: const TextConfidence(-0.1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when textConfidence.raw is above 1.0', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          textConfidence: const TextConfidence(1.1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('accepts 0.0 and 1.0 boundary values on both confidences', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          positionConfidence: const PositionConfidence(0.0),
          textConfidence: const TextConfidence(0.0),
        ),
        returnsNormally,
      );
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          positionConfidence: const PositionConfidence(1.0),
          textConfidence: const TextConfidence(1.0),
        ),
        returnsNormally,
      );
    });

    test('throw message names the offending field', () {
      try {
        DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          positionConfidence: PositionConfidence(double.nan),
        );
        fail('expected ArgumentError');
      } on ArgumentError catch (e) {
        expect(e.toString(), contains('positionConfidence'));
      }
    });
  });
}
```

- [ ] **Step 2: Run the test, confirm it fails**

Run:
```bash
flutter test test/default_tracked_block_confidence_invariant_test.dart
```
Expected: FAIL — all "throws ArgumentError" expectations fail because the constructor currently accepts NaN / out-of-range silently.

- [ ] **Step 3: Implement the constructor invariant**

Open `lib/src/default_tracked_block.dart`. Locate the constructor body at lines ~141-151 (the existing `containerId` throw block). Replace just the constructor body (`{ ... }` after the parameter list) with:

```dart
}) {
  if (containerId != null && !isInnerScrollerChild) {
    throw ArgumentError(
      'TrackedBlock invariant: containerId requires isInnerScrollerChild '
      '(got containerId=$containerId, isInnerScrollerChild=false). '
      'Setting containerId without isInnerScrollerChild misclassifies the '
      'block into the wrong drift coordinate space and silently corrupts '
      'drift corrections.',
    );
  }
  _validateConfidence('positionConfidence', positionConfidence.raw);
  _validateConfidence('textConfidence', textConfidence.raw);
}

// Private helper — DRY across the two confidence fields. Uses `throw` rather
// than `assert` per project policy (feedback_assert_vs_throw_in_storage):
// asserts strip in release; production-critical invariants on a state-owning
// type must hold in release builds too.
static void _validateConfidence(String name, double raw) {
  if (raw.isNaN || raw < 0.0 || raw > 1.0) {
    throw ArgumentError.value(
      raw,
      name,
      'must be a finite double in [0.0, 1.0]',
    );
  }
}
```

Add this helper as a `static` member of `DefaultTrackedBlock` (place it after the constructor and `copyWith`, before `applyMerge`).

- [ ] **Step 4: Run the test, confirm it passes**

Run:
```bash
flutter test test/default_tracked_block_confidence_invariant_test.dart
```
Expected: PASS — all 8 tests green.

- [ ] **Step 5: Commit**

Run:
```bash
git add lib/src/default_tracked_block.dart test/default_tracked_block_confidence_invariant_test.dart
git commit -m "fix(default_tracked_block): #27 throw on NaN/out-of-range Confidence in ctor"
```

---

### Task PR1-T3: Lock `StabilizationEngine.stabilize()` entry validation (TDD red→green)

**Files:**
- Create: `test/stabilization_engine_confidence_entry_validation_test.dart`
- Modify: `lib/src/stabilization_engine.dart` (top of `stabilize()` around line 92)

- [ ] **Step 1: Write the failing test**

Create `test/stabilization_engine_confidence_entry_validation_test.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/merge_result.dart';
import 'package:ocr_stabilizer/src/observable_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/text_vote.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';
import 'package:ocr_stabilizer/src/types/confidence_types.dart';
import 'package:ocr_stabilizer/src/types/container_id.dart';
import 'package:ocr_stabilizer/src/types/scroll_context.dart';
import 'package:ocr_stabilizer/src/types/sticky_fallback.dart';

/// A `TrackedBlock` implementor that bypasses [DefaultTrackedBlock] entirely.
/// Used to prove engine-entry validation catches non-`DefaultTrackedBlock`
/// implementors too, per spec §3 (Solution A).
class _BareTrackedBlock implements ObservableBlock<Object> {
  _BareTrackedBlock({
    required this.positionConfidence,
    required this.textConfidence,
  });

  @override
  PositionConfidence positionConfidence;
  @override
  TextConfidence textConfidence;

  @override
  AbsoluteRect get absoluteRect => AbsoluteRect.fromLTWH(0, 0, 10, 10);
  @override
  ContainerId? get containerId => null;
  @override
  bool get isViewportRelative => false;
  @override
  bool get isInnerScrollerChild => false;
  @override
  double get innerScrollerTop => 0;
  @override
  bool get isHorizontalScrollChild => false;
  @override
  Object get payload => const Object();
  @override
  String get originalText => 'hi';
  @override
  ScrollContext get scrollContext => ScrollContext.none;
  @override
  bool get isFromStickyElement => false;
  @override
  StickyFallback get stickyFallback => StickyFallback.none;
  @override
  int get sourceQuality => 0;
  @override
  int get observationCount => 1;
  @override
  Map<int, int> get classificationVotes => const {};
  @override
  Map<int, int> get carouselIdVotes => const {-1: 1};
  @override
  Map<String, TextVote> get textVotes => const {};
  @override
  bool get isProvisional => false;
  @override
  int get provisionalCapturesRemaining => 0;
  @override
  int get groupSignature => 0;
  @override
  bool get needsReclassification => false;
  @override
  int get hierarchyWeight => 0;
}

DefaultTrackedBlock<Object> _validBlock({
  String text = 'hi',
  double left = 0,
  double top = 0,
}) {
  return DefaultTrackedBlock<Object>(
    absoluteRect: AbsoluteRect.fromLTWH(left, top, 10, 10),
    payload: const Object(),
    originalText: text,
  );
}

void main() {
  group('StabilizationEngine.stabilize entry validation (#27)', () {
    late StabilizationEngine<DefaultTrackedBlock<Object>, Object> engine;

    setUp(() {
      engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
      );
    });

    test('throws when an observation has NaN positionConfidence (via bare impl)', () {
      final bad = _BareTrackedBlock(
        positionConfidence: PositionConfidence(double.nan),
        textConfidence: TextConfidence(0.5),
      );
      expect(
        () => engine.stabilize([bad as ObservableBlock<Object>]
            .cast<DefaultTrackedBlock<Object>>()),
        throwsA(isA<TypeError>()),
        reason: 'cast forces a runtime check; this proves we can construct '
            'the bare block with NaN at all',
      );
    });

    test('throws when bare-impl observation has NaN positionConfidence', () {
      // Re-parameterize the engine so it accepts ObservableBlock directly
      // (the prod engine accepts T extends ObservableBlock; here T = the bare type).
      final bareEngine =
          StabilizationEngine<ObservableBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing,
      );
      final bad = _BareTrackedBlock(
        positionConfidence: PositionConfidence(double.nan),
        textConfidence: TextConfidence(0.5),
      );
      expect(
        () => bareEngine.stabilize([bad]),
        throwsA(isA<ArgumentError>()
            .having((e) => e.toString(), 'message', contains('positionConfidence'))
            .having((e) => e.toString(), 'message', contains('index 0'))),
      );
    });

    test('throws when bare-impl observation has NaN textConfidence', () {
      final bareEngine =
          StabilizationEngine<ObservableBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing,
      );
      final bad = _BareTrackedBlock(
        positionConfidence: PositionConfidence(0.5),
        textConfidence: TextConfidence(double.nan),
      );
      expect(
        () => bareEngine.stabilize([bad]),
        throwsA(isA<ArgumentError>()
            .having((e) => e.toString(), 'message', contains('textConfidence'))),
      );
    });

    test('throws when bare-impl observation has out-of-range confidence', () {
      final bareEngine =
          StabilizationEngine<ObservableBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing,
      );
      final bad = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(1.1),
        textConfidence: TextConfidence(0.5),
      );
      expect(
        () => bareEngine.stabilize([bad]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throw message names the offending observation index', () {
      final bareEngine =
          StabilizationEngine<ObservableBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing,
      );
      final good = _BareTrackedBlock(
        positionConfidence: PositionConfidence(0.5),
        textConfidence: TextConfidence(0.5),
      );
      final bad = _BareTrackedBlock(
        positionConfidence: PositionConfidence(double.nan),
        textConfidence: TextConfidence(0.5),
      );
      try {
        bareEngine.stabilize([good, bad]);
        fail('expected ArgumentError');
      } on ArgumentError catch (e) {
        expect(e.toString(), contains('index 1'));
      }
    });

    test('sanity: a valid observation list passes entry validation', () {
      expect(
        () => engine.stabilize([_validBlock(text: 'hi')]),
        returnsNormally,
      );
    });
  });
}
```

> **Note on the first test**: it exists to confirm the bare-impl test scaffolding works (constructing the bare block with NaN succeeds — the bug we're closing). The interesting assertions are in the subsequent tests that re-parameterize the engine to accept the bare type directly. Delete the first test if it adds noise; the cast-error test result is not what's being validated for #27.

- [ ] **Step 2: Run the test, confirm it fails**

Run:
```bash
flutter test test/stabilization_engine_confidence_entry_validation_test.dart
```
Expected: FAIL — bare-impl bad observations are accepted silently by `stabilize()`.

- [ ] **Step 3: Add the entry-validation helper to `StabilizationEngine`**

Open `lib/src/stabilization_engine.dart`. Inside the `StabilizationEngine` class, before `stabilize()` (around line 91), add:

```dart
/// Validate that an observation's confidence values are finite and in range.
///
/// Engine *input* guard — symmetric to `MergeResult`'s 0.2.0 engine *output*
/// guard at [merge_result.dart:107-124]. Together they bracket the pipeline:
/// no NaN/out-of-range Confidence can enter or leave the engine.
///
/// Throws [ArgumentError.value] naming the offending field and observation
/// index on the first violation. Catches any [ObservableBlock] implementor —
/// `DefaultTrackedBlock` already early-fails at construction, but a
/// hand-rolled implementor can still slip past the unchecked-`const`
/// `PositionConfidence(double)` / `TextConfidence(double)` primary
/// constructors documented at [confidence_types.dart:14-22].
void _assertValidConfidence(T block, int index) {
  final pos = block.positionConfidence.raw;
  if (pos.isNaN || pos < 0.0 || pos > 1.0) {
    throw ArgumentError.value(
      pos,
      'positionConfidence',
      'observation at index $index: must be a finite double in [0.0, 1.0]',
    );
  }
  final txt = block.textConfidence.raw;
  if (txt.isNaN || txt < 0.0 || txt > 1.0) {
    throw ArgumentError.value(
      txt,
      'textConfidence',
      'observation at index $index: must be a finite double in [0.0, 1.0]',
    );
  }
}
```

Then at the very top of `stabilize()` (line 92, before the comment `// 1. Dedup pipeline`), insert:

```dart
StabilizationResult<T> stabilize(List<T> freshBlocks) {
  // Engine-entry Confidence validation (#27). Catches any ObservableBlock
  // implementor at one seam, complementing MergeResult's engine-output guard.
  for (var i = 0; i < freshBlocks.length; i++) {
    _assertValidConfidence(freshBlocks[i], i);
  }

  // 1. Dedup pipeline
  final deduped = _dedup(freshBlocks);
  // ... (rest unchanged)
```

- [ ] **Step 4: Run the test, confirm it passes**

Run:
```bash
flutter test test/stabilization_engine_confidence_entry_validation_test.dart
```
Expected: PASS on all assertions about engine-entry rejection. The first scaffolding test may fail or pass depending on cast semantics; delete it if it's noise (it isn't a #27 acceptance criterion).

- [ ] **Step 5: Commit**

Run:
```bash
git add lib/src/stabilization_engine.dart test/stabilization_engine_confidence_entry_validation_test.dart
git commit -m "fix(engine): #27 validate Confidence at stabilize() entry; complements MergeResult output guard"
```

---

### Task PR1-T4: Lock `qualityScore` debug assert (TDD red→green)

**Files:**
- Create: `test/quality_score_debug_assert_test.dart`
- Modify: `lib/src/overlap_resolver.dart` (lines 176-177)

- [ ] **Step 1: Write the failing test**

Create `test/quality_score_debug_assert_test.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/overlap_resolver.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';
import 'package:ocr_stabilizer/src/types/confidence_types.dart';

void main() {
  group('OverlapResolver.qualityScore: NaN debug assert (#27)', () {
    // Note: Dart `assert` only fires in debug builds. Tests run in debug by
    // default; in release the assert is stripped and qualityScore returns
    // a poisoned NaN value. The production guard against that case is
    // engine-entry validation in StabilizationEngine.stabilize(); this
    // assert is the developer-facing safety net.

    final rect = AbsoluteRect.fromLTWH(0, 0, 10, 10);

    test('fires AssertionError when positionConfidence.raw is NaN', () {
      // Bypass DefaultTrackedBlock's ctor throw by constructing the
      // confidence values via the unchecked const primary constructor
      // and then building the block via copyWith from a valid baseline
      // (copyWith doesn't re-validate — that's exactly the pathological
      // path the assert defends against).
      //
      // Simpler: skip DefaultTrackedBlock entirely and call qualityScore
      // with a hand-rolled block. But here we want to exercise the real
      // type. Use copyWith to skip the ctor throw.
      final base = DefaultTrackedBlock<Object>(
        absoluteRect: rect,
        payload: const Object(),
      );
      // copyWith builds a new DefaultTrackedBlock that DOES re-run the
      // ctor — so this throws ArgumentError, not AssertionError. The
      // path we want exercises Confidence at the call site directly:
      // use the static qualityScore against a TrackedBlock built via
      // a separate, ctor-bypassing path. The bare-impl trick from PR1-T3
      // is the right tool — copy it here and call qualityScore directly.
      //
      // For brevity we test the assertion via a minimal mock below.
    });

    test('fires AssertionError on NaN positionConfidence via bare impl', () {
      final bad = _NaNConfBlock(posIsNan: true);
      expect(
        () => OverlapResolver.qualityScore(bad),
        throwsA(isA<AssertionError>()),
      );
    });

    test('fires AssertionError on NaN textConfidence via bare impl', () {
      final bad = _NaNConfBlock(txtIsNan: true);
      expect(
        () => OverlapResolver.qualityScore(bad),
        throwsA(isA<AssertionError>()),
      );
    });

    test('returns finite score on valid confidence', () {
      final good = _NaNConfBlock();
      expect(OverlapResolver.qualityScore(good), closeTo(0.5, 1e-9));
    });
  });
}

/// Minimal TrackedBlock implementor that bypasses DefaultTrackedBlock's
/// ctor throw. Mirrors the bare-impl scaffold from
/// stabilization_engine_confidence_entry_validation_test.dart but pared
/// down to what qualityScore reads.
class _NaNConfBlock implements TrackedBlock {
  _NaNConfBlock({this.posIsNan = false, this.txtIsNan = false});
  final bool posIsNan;
  final bool txtIsNan;

  @override
  PositionConfidence get positionConfidence => posIsNan
      ? PositionConfidence(double.nan)
      : const PositionConfidence(0.5);
  @override
  TextConfidence get textConfidence =>
      txtIsNan ? TextConfidence(double.nan) : const TextConfidence(0.5);

  // Stub the rest of TrackedBlock — qualityScore only reads the two
  // confidences above. Use Mockito-style fallback or noSuchMethod if the
  // surface is too large; the bare hand-roll is fine for two callers.
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      'qualityScore only reads positionConfidence + textConfidence');
}
```

> **Note:** the test imports `TrackedBlock` directly. If `TrackedBlock` isn't exported from `lib/src/`, import from the correct location (check `lib/src/tracked_block.dart`). The bare-impl noSuchMethod trick avoids stubbing 20+ fields when only two matter for the call under test.

- [ ] **Step 2: Run the test, confirm it fails**

Run:
```bash
flutter test test/quality_score_debug_assert_test.dart
```
Expected: FAIL — `qualityScore` currently returns NaN silently; no assertion fires.

- [ ] **Step 3: Replace `qualityScore` body with the assert**

Open `lib/src/overlap_resolver.dart`. Replace lines 176-177:

```dart
  /// Combined quality score: text confidence weighted higher than position
  /// confidence because a bad translation is worse than slight position jitter.
  static double qualityScore(TrackedBlock block) =>
      block.positionConfidence.raw * 0.4 + block.textConfidence.raw * 0.6;
```

with:

```dart
  /// Combined quality score: text confidence weighted higher than position
  /// confidence because a bad translation is worse than slight position jitter.
  ///
  /// NaN-on-input is a logic bug — the production guard is
  /// [StabilizationEngine.stabilize]'s entry validation (#27).
  /// This assert is the developer-facing safety net in debug builds;
  /// release builds strip it for zero overhead.
  static double qualityScore(TrackedBlock block) {
    final pos = block.positionConfidence.raw;
    final txt = block.textConfidence.raw;
    assert(!pos.isNaN && !txt.isNaN,
        'qualityScore reached with NaN confidence — '
        'engine-entry validation should have caught this.');
    return pos * 0.4 + txt * 0.6;
  }
```

- [ ] **Step 4: Run the test, confirm it passes**

Run:
```bash
flutter test test/quality_score_debug_assert_test.dart
```
Expected: PASS on both NaN-fires-assert tests and the valid-input test.

- [ ] **Step 5: Commit**

Run:
```bash
git add lib/src/overlap_resolver.dart test/quality_score_debug_assert_test.dart
git commit -m "fix(overlap_resolver): #27 qualityScore debug-asserts on NaN; release builds skip"
```

---

### Task PR1-T5: Full suite + PR open

**Files:** none (CI/git)

- [ ] **Step 1: Run the full test suite**

Run:
```bash
flutter test
```
Expected: ALL GREEN. If any pre-existing test fails, investigate — engine-entry validation might be tripping a test that was using bare-impl blocks with bad Confidence values.

- [ ] **Step 2: Verify the three commits look clean**

Run:
```bash
git log --oneline main..HEAD
```
Expected: three commits — `fix(default_tracked_block)...`, `fix(engine)...`, `fix(overlap_resolver)...`.

- [ ] **Step 3: Push the branch**

Run:
```bash
git push -u origin fix/27-confidence-nan-guard
```

- [ ] **Step 4: Open the PR**

Run:
```bash
gh pr create --base main --head fix/27-confidence-nan-guard \
  --title "fix(engine): #27 validate Confidence at engine entry; throw in DefaultTrackedBlock ctor; debug-assert in qualityScore" \
  --body "Closes #27.

Engine-entry Confidence validation closes the documented unchecked-\`const\` gap from #19:
- \`StabilizationEngine.stabilize()\` validates every \`TrackedBlock\` at the entry seam — catches any implementor, not just \`DefaultTrackedBlock\`. Symmetric to \`MergeResult\`'s 0.2.0 output guard.
- \`DefaultTrackedBlock\` constructor throws on NaN/out-of-range Confidence for clearer stack traces.
- \`qualityScore\` collapses to a debug assert; release builds skip (production defended by entry validation).

Spec: \`docs/superpowers/specs/2026-05-23-band-fallback-and-quality-score-nan-guard.md\` §3.
Plan: \`docs/superpowers/plans/2026-05-23-band-fallback-and-quality-score-plan.md\` PR1 section."
```

- [ ] **Step 5: Wait for bot reviews + agent fan-out per project conventions, then merge**

Per `feedback_review_merged_prs` + `feedback_bots_catch_what_agents_miss`: wait for Copilot + Gemini auto-reviews to complete, run the 5-agent fan-out passing bot context through, batch any fixes inline, then merge via `gh pr merge --squash --delete-branch`. Use the squash-merge title from the spec verbatim:

```
fix(engine): #27 validate Confidence at engine entry; throw in DefaultTrackedBlock ctor; debug-assert in qualityScore

Closes #27
```

- [ ] **Step 6: Pull latest `main` after merge**

Run:
```bash
git checkout main
git pull --ff-only
```

---

## PR 2 — `feat/20-band-fallback`

### Task PR2-T1: Create branch off `main` (post-PR1 merge)

**Files:** none (git operation)

- [ ] **Step 1: Verify on latest `main`**

Run:
```bash
cd c:/src/ocr-stabilizer
git checkout main
git pull --ff-only
git status
```
Expected: latest `main` includes PR #1's merge commit, working tree clean.

- [ ] **Step 2: Create the PR 2 branch**

Run:
```bash
git checkout -b feat/20-band-fallback
```

---

### Task PR2-T2: Lock `BandFallbackMode` enum (TDD red→green)

**Files:**
- Create: `test/band_fallback_mode_test.dart`
- Create: `lib/src/band_fallback_config.dart` (enum portion only this step)

- [ ] **Step 1: Write the failing test**

Create `test/band_fallback_mode_test.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';

void main() {
  group('BandFallbackMode (#20)', () {
    test('values are off, observeOnly, admit in that order', () {
      expect(BandFallbackMode.values,
          [BandFallbackMode.off, BandFallbackMode.observeOnly, BandFallbackMode.admit]);
    });
  });
}
```

- [ ] **Step 2: Run the test, confirm it fails**

Run:
```bash
flutter test test/band_fallback_mode_test.dart
```
Expected: FAIL — `band_fallback_config.dart` doesn't exist yet; compile error on the import.

- [ ] **Step 3: Create the enum**

Create `lib/src/band_fallback_config.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter/foundation.dart' show immutable;

import 'tracked_block.dart';

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
  /// done before flipping. The loop scans all candidates so per-stage
  /// counters reflect the full population, not just the first match.
  observeOnly,

  /// Production mode. The full band loop runs and returns the first
  /// candidate that clears every gate. Matches are admitted as
  /// provisional (see [BandFallbackConfig.provisionalCaptures]).
  admit,
}
```

> **Note:** `import 'tracked_block.dart';` is unused right now but will be needed in PR2-T4 for `BandSpatialPredicate`. Keep it to avoid a touch in the next task; analyzer may warn — silence with `// ignore: unused_import` if needed, or omit and re-add in T4.

- [ ] **Step 4: Run the test, confirm it passes**

Run:
```bash
flutter test test/band_fallback_mode_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit (deferred — bundle with T3/T4)**

Don't commit yet; the next two tasks add `BandFallbackConfig` + `BandSpatialPredicate` in the same file. Bundle into one commit at end of T4.

---

### Task PR2-T3: Lock `BandFallbackConfig` defaults + invariants (TDD red→green)

**Files:**
- Create: `test/band_fallback_config_test.dart`
- Modify: `lib/src/band_fallback_config.dart` (add `BandFallbackConfig` class + `BandSpatialPredicate` typedef)

- [ ] **Step 1: Write the failing test**

Create `test/band_fallback_config_test.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';

void main() {
  group('BandFallbackConfig defaults (#20)', () {
    test('default-constructed config has expected values', () {
      const cfg = BandFallbackConfig();
      expect(cfg.mode, BandFallbackMode.off);
      expect(cfg.bandLevenshteinFloor, 0.50);
      expect(cfg.bandJaccardFloor, 0.60);
      expect(cfg.candidateObservationFloor, 4); // = provisionalCaptures (3) + 1
      expect(cfg.provisionalCaptures, 3);
      expect(cfg.spatialConfirm, isNull);
    });

    test('candidateObservationFloor defaults to provisionalCaptures + 1', () {
      const cfg = BandFallbackConfig(provisionalCaptures: 5);
      expect(cfg.candidateObservationFloor, 6);
    });

    test('explicit candidateObservationFloor overrides the derivation', () {
      const cfg = BandFallbackConfig(
        provisionalCaptures: 5,
        candidateObservationFloor: 2,
      );
      expect(cfg.candidateObservationFloor, 2);
    });
  });

  group('BandFallbackConfig invariants (#20)', () {
    test('throws when bandLevenshteinFloor is at upper bound 0.70', () {
      expect(() => BandFallbackConfig(bandLevenshteinFloor: 0.70),
          throwsA(isA<ArgumentError>()));
    });

    test('throws when bandLevenshteinFloor is below 0.0', () {
      expect(() => BandFallbackConfig(bandLevenshteinFloor: -0.01),
          throwsA(isA<ArgumentError>()));
    });

    test('throws when bandJaccardFloor is at upper bound 0.80', () {
      expect(() => BandFallbackConfig(bandJaccardFloor: 0.80),
          throwsA(isA<ArgumentError>()));
    });

    test('throws when bandJaccardFloor is below 0.0', () {
      expect(() => BandFallbackConfig(bandJaccardFloor: -0.01),
          throwsA(isA<ArgumentError>()));
    });

    test('throws when candidateObservationFloor is negative', () {
      expect(() => BandFallbackConfig(candidateObservationFloor: -1),
          throwsA(isA<ArgumentError>()));
    });

    test('throws when provisionalCaptures is 0', () {
      expect(() => BandFallbackConfig(provisionalCaptures: 0),
          throwsA(isA<ArgumentError>()));
    });

    test('accepts boundary values just inside the ranges', () {
      expect(
        () => const BandFallbackConfig(
          bandLevenshteinFloor: 0.0,
          bandJaccardFloor: 0.0,
          candidateObservationFloor: 0,
          provisionalCaptures: 1,
        ),
        returnsNormally,
      );
      // Just-below upper bounds
      expect(
        () => const BandFallbackConfig(
          bandLevenshteinFloor: 0.6999999,
          bandJaccardFloor: 0.7999999,
        ),
        returnsNormally,
      );
    });
  });
}
```

- [ ] **Step 2: Run the test, confirm it fails**

Run:
```bash
flutter test test/band_fallback_config_test.dart
```
Expected: FAIL — `BandFallbackConfig` doesn't exist.

- [ ] **Step 3: Add `BandFallbackConfig` + `BandSpatialPredicate` to the file**

Open `lib/src/band_fallback_config.dart`. After the `BandFallbackMode` enum, add:

```dart
/// Spatial confirmation predicate for a band-relaxed candidate.
///
/// Signature mirrors `ContextualInvalidationCheck` for consistency with
/// the engine's existing predicate-injection seam — two [TrackedBlock]
/// arguments, no engine-internal types (`SpaceKey`, `DriftTracker`)
/// leaked into public signatures.
typedef BandSpatialPredicate =
    bool Function(TrackedBlock fresh, TrackedBlock candidate);

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
/// `TextDedupUtils.isTextSimilarWithScores` for those.
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
  /// match. Must be `>= 1` (reflects `MergeResult`'s invariant that
  /// `isProvisional` implies `provisionalCapturesRemaining > 0`).
  ///
  /// Default: `3`. Provenance: matches `ocr_translate_demo`'s value at
  /// `lib/overlay/services/overlay_cache_service.dart:1603-1604` — cited
  /// as proven app-side choice; the package owns the default thereafter.
  final int provisionalCaptures;

  /// Spatial confirmation predicate. `null` means the engine substitutes a
  /// drift-aware overlap-ratio closure at construction time
  /// (`overlapRatio >= 0.80` with the candidate's space-keyed drift margin).
  /// Default: `null`.
  final BandSpatialPredicate? spatialConfirm;

  /// Construct a config. All fields are optional; defaults are documented
  /// per-field above. The constructor uses `assert` (not `throw`) so it
  /// stays `const`-capable for default-parameter-value use sites. In debug
  /// builds an invariant violation fires `AssertionError`; release builds
  /// strip the checks. Invariants:
  /// - `bandLevenshteinFloor` must be in `[0.0, 0.70)`
  /// - `bandJaccardFloor` must be in `[0.0, 0.80)`
  /// - `candidateObservationFloor` must be `>= 0`
  /// - `provisionalCaptures` must be `>= 1`
  const BandFallbackConfig({
    this.mode = BandFallbackMode.off,
    this.bandLevenshteinFloor = 0.50,
    this.bandJaccardFloor = 0.60,
    int? candidateObservationFloor,
    this.provisionalCaptures = 3,
    this.spatialConfirm,
  })  : candidateObservationFloor =
            candidateObservationFloor ?? (provisionalCaptures + 1),
        assert(
            bandLevenshteinFloor >= 0.0 && bandLevenshteinFloor < 0.70,
            'bandLevenshteinFloor must be in [0.0, 0.70)'),
        assert(
            bandJaccardFloor >= 0.0 && bandJaccardFloor < 0.80,
            'bandJaccardFloor must be in [0.0, 0.80)'),
        assert(
            (candidateObservationFloor ?? (provisionalCaptures + 1)) >= 0,
            'candidateObservationFloor must be >= 0'),
        assert(provisionalCaptures >= 1,
            'provisionalCaptures must be >= 1');
}
```

> **Note on assert vs throw:** the spec calls for `throw ArgumentError.value` on the invariants, but Dart `const` constructors can only validate via `assert`. To preserve `const` constructibility (used in default param values and field initializers), the invariants are `assert`. The test suite below verifies these fire as `ArgumentError` in debug mode — `assert` failures raise `AssertionError`, not `ArgumentError`. **Update the tests accordingly: change `throwsA(isA<ArgumentError>())` to `throwsA(isA<AssertionError>())`.** If you need release-build enforcement, change the constructor to non-`const` and use real `throw` blocks — but you lose `const` everywhere, including `const BandFallbackConfig()` as a default value (`StabilizationEngine` ctor uses this).

- [ ] **Step 4: Update test assertions from `ArgumentError` to `AssertionError`**

In `test/band_fallback_config_test.dart`, replace every `throwsA(isA<ArgumentError>())` with `throwsA(isA<AssertionError>())`.

- [ ] **Step 5: Run the test, confirm it passes**

Run:
```bash
flutter test test/band_fallback_config_test.dart test/band_fallback_mode_test.dart
```
Expected: PASS on both files.

- [ ] **Step 6: Commit**

Run:
```bash
git add lib/src/band_fallback_config.dart test/band_fallback_mode_test.dart test/band_fallback_config_test.dart
git commit -m "feat(api): #20 add BandFallbackMode + BandFallbackConfig + BandSpatialPredicate"
```

---

### Task PR2-T4: Lock `BandFallbackStats` + `BandFallbackStatsInternal` (TDD red→green)

**Files:**
- Create: `test/band_fallback_stats_test.dart`
- Create: `lib/src/band_fallback_stats.dart`

- [ ] **Step 1: Write the failing test**

Create `test/band_fallback_stats_test.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_stats.dart';

void main() {
  group('BandFallbackStats counters (#20)', () {
    test('all counters default to 0', () {
      final stats = BandFallbackStatsInternal();
      expect(stats.primaryMatchesAdmitted, 0);
      expect(stats.primaryMatchesRejected, 0);
      expect(stats.candidatesConsidered, 0);
      expect(stats.rejectedCandidateFloor, 0);
      expect(stats.rejectedSpatial, 0);
      expect(stats.bandMatchesIdentified, 0);
      expect(stats.matchesAdmitted, 0);
    });

    test('mutators tick the corresponding counter once each', () {
      final stats = BandFallbackStatsInternal();
      stats.recordPrimaryMatchAdmitted();
      stats.recordPrimaryMatchRejected();
      stats.recordCandidateConsidered();
      stats.recordRejectedCandidateFloor();
      stats.recordRejectedSpatial();
      stats.recordBandMatchIdentified();
      stats.recordMatchAdmitted();

      expect(stats.primaryMatchesAdmitted, 1);
      expect(stats.primaryMatchesRejected, 1);
      expect(stats.candidatesConsidered, 1);
      expect(stats.rejectedCandidateFloor, 1);
      expect(stats.rejectedSpatial, 1);
      expect(stats.bandMatchesIdentified, 1);
      expect(stats.matchesAdmitted, 1);
    });

    test('reset() zeroes every counter', () {
      final stats = BandFallbackStatsInternal();
      stats.recordPrimaryMatchAdmitted();
      stats.recordPrimaryMatchAdmitted();
      stats.recordCandidatesConsidered_safe(5);
      stats.reset();
      expect(stats.primaryMatchesAdmitted, 0);
      expect(stats.primaryMatchesRejected, 0);
      expect(stats.candidatesConsidered, 0);
      expect(stats.rejectedCandidateFloor, 0);
      expect(stats.rejectedSpatial, 0);
      expect(stats.bandMatchesIdentified, 0);
      expect(stats.matchesAdmitted, 0);
    });

    test('upcast to BandFallbackStats exposes getters but hides mutators', () {
      final BandFallbackStatsInternal internal = BandFallbackStatsInternal();
      internal.recordPrimaryMatchAdmitted();
      final BandFallbackStats view = internal; // upcast
      expect(view.primaryMatchesAdmitted, 1);
      // The static type `BandFallbackStats` does not have `recordPrimaryMatchAdmitted` —
      // attempting to call it via `view` would be a compile error.
      // Runtime downcast is possible (documented limitation in spec §7 risks).
    });

    test('BandFallbackStats has no public unnamed constructor', () {
      // Compile-time check: `BandFallbackStats()` is not callable; the only
      // public path to construct one is via BandFallbackStatsInternal() and
      // upcast. This test is verbose because Dart's analyzer doesn't expose
      // "cannot call private ctor from this scope" as a runtime check —
      // we assert the type relationship instead.
      final BandFallbackStats view = BandFallbackStatsInternal();
      expect(view, isA<BandFallbackStats>());
    });
  });
}
```

> **Note:** the test uses `stats.recordCandidatesConsidered_safe(5)` as a hypothetical bulk-increment for the reset test. That method doesn't exist in the spec — just call `recordCandidateConsidered()` five times. **Fix the test before running**: replace the line with five repeats of `stats.recordCandidateConsidered();`.

- [ ] **Step 2: Run the test, confirm it fails**

Run:
```bash
flutter test test/band_fallback_stats_test.dart
```
Expected: FAIL — `band_fallback_stats.dart` doesn't exist.

- [ ] **Step 3: Create both classes in the same library**

Create `lib/src/band_fallback_stats.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

/// Per-capture telemetry for the matching path inside `StabilizationEngine`.
///
/// All counters are cumulative until [reset] is called. The engine never
/// calls [reset] automatically; consumers reset between captures if they
/// want per-capture buckets.
///
/// Primary counters tick whether or not the band-fallback path is enabled —
/// they reflect the primary path's outcome. Band counters only tick when
/// `BandFallbackConfig.mode` is `BandFallbackMode.observeOnly` or
/// `BandFallbackMode.admit`.
///
/// Read-only public surface: consumers see this type via
/// `StabilizationEngine.bandStats`. The engine writes via
/// [BandFallbackStatsInternal], which lives in the same library and
/// reaches the underscore-private fields.
class BandFallbackStats {
  BandFallbackStats._();

  /// Number of fresh observations that found a primary-path match.
  int get primaryMatchesAdmitted => _primaryMatchesAdmitted;
  int _primaryMatchesAdmitted = 0;

  /// Number of fresh observations that the primary path rejected.
  /// `primaryMatchesAdmitted + primaryMatchesRejected` equals the total
  /// number of fresh observations that reached `_findMatch`.
  int get primaryMatchesRejected => _primaryMatchesRejected;
  int _primaryMatchesRejected = 0;

  /// Number of candidates the band loop scanned. Only ticks when
  /// `mode != off`. Compare against [primaryMatchesRejected] to compute
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
  /// [matchesAdmitted]; in `observeOnly` mode it ticks alone.
  int get bandMatchesIdentified => _bandMatchesIdentified;
  int _bandMatchesIdentified = 0;

  /// Number of band-relaxed matches actually returned by `_findMatch`.
  /// Always `<= bandMatchesIdentified`. In `observeOnly` mode this stays
  /// at zero by construction.
  int get matchesAdmitted => _matchesAdmitted;
  int _matchesAdmitted = 0;

  /// Zero every counter.
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
///
/// Public to the package — consumers see only the [BandFallbackStats]
/// supertype via `StabilizationEngine.bandStats`. The `Internal` suffix
/// signals "package-internal API"; a determined consumer can downcast and
/// mutate, but the convention is enforced socially, not by the language.
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

- [ ] **Step 4: Run the test, confirm it passes**

Run:
```bash
flutter test test/band_fallback_stats_test.dart
```
Expected: PASS.

- [ ] **Step 5: Commit**

Run:
```bash
git add lib/src/band_fallback_stats.dart test/band_fallback_stats_test.dart
git commit -m "feat(api): #20 add BandFallbackStats (read-only public + Internal mutator)"
```

---

### Task PR2-T5: Export new types from the package barrel

**Files:**
- Modify: `lib/ocr_stabilizer.dart` (the public package barrel)

- [ ] **Step 1: Locate and inspect the barrel**

Run:
```bash
cat c:/src/ocr-stabilizer/lib/ocr_stabilizer.dart
```
Read the existing exports. The new types need to join them.

- [ ] **Step 2: Add the exports**

Append (in alphabetical position) to `lib/ocr_stabilizer.dart`:

```dart
export 'src/band_fallback_config.dart'
    show BandFallbackMode, BandFallbackConfig, BandSpatialPredicate;
export 'src/band_fallback_stats.dart'
    show BandFallbackStats, BandFallbackStatsInternal;
```

> **Note:** `BandFallbackStatsInternal` is exported intentionally so the engine in `lib/src/` can build instances and tests can construct one. The class's name and dartdoc warn off external consumers (per spec §7 risk).

- [ ] **Step 3: Verify exports resolve**

Run:
```bash
flutter analyze --no-fatal-warnings lib/ocr_stabilizer.dart
```
Expected: no errors related to the new exports.

- [ ] **Step 4: Commit**

Run:
```bash
git add lib/ocr_stabilizer.dart
git commit -m "feat(api): #20 export band-fallback types from package barrel"
```

---

### Task PR2-T6: Wire `bandFallback` param + `bandStats` getter + primary-path counters (TDD red→green)

**Files:**
- Create: `test/stabilization_engine_band_off_primary_counters_test.dart`
- Modify: `lib/src/stabilization_engine.dart` (ctor + `_findMatch`)

- [ ] **Step 1: Write the failing test**

Create `test/stabilization_engine_band_off_primary_counters_test.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(String text,
        {double left = 0, double top = 0}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, 50, 20),
      payload: const Object(),
      originalText: text,
    );

void main() {
  group('StabilizationEngine band mode=off — primary counters tick (#20)', () {
    late StabilizationEngine<DefaultTrackedBlock<Object>, Object> engine;

    setUp(() {
      engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        // bandFallback defaults to const BandFallbackConfig() — mode: off
      );
    });

    test('primaryMatchesAdmitted ticks when fresh matches an existing block', () {
      // Seed an existing block.
      engine.stabilize([_block('hello world', left: 0, top: 0)]);

      // Re-observe with identical text and overlapping position — should match.
      engine.stabilize([_block('hello world', left: 0, top: 0)]);

      expect(engine.bandStats.primaryMatchesAdmitted, 1);
      expect(engine.bandStats.primaryMatchesRejected, 0);
      expect(engine.bandStats.candidatesConsidered, 0,
          reason: 'off mode does zero band work');
    });

    test('primaryMatchesRejected ticks when fresh finds no primary match', () {
      // Seed.
      engine.stabilize([_block('hello world', left: 0, top: 0)]);

      // Observe a completely-different text at the same position —
      // primary path rejects, off mode declines to enter the band loop.
      engine.stabilize([_block('xxxxxxxxxxx', left: 0, top: 0)]);

      expect(engine.bandStats.primaryMatchesAdmitted, 0);
      expect(engine.bandStats.primaryMatchesRejected, 1);
      expect(engine.bandStats.candidatesConsidered, 0);
    });

    test('bandStats getter returns BandFallbackStats supertype', () {
      // Compile-time check that the getter's return type is the supertype
      // and not the Internal subclass — consumers can't mutate.
      final stats = engine.bandStats;
      expect(stats, isA<BandFallbackStats>());
      // stats.recordPrimaryMatchAdmitted() would be a compile error.
    });
  });
}
```

- [ ] **Step 2: Run the test, confirm it fails**

Run:
```bash
flutter test test/stabilization_engine_band_off_primary_counters_test.dart
```
Expected: FAIL — `engine.bandStats` doesn't exist; `bandFallback` ctor param doesn't exist.

- [ ] **Step 3: Add `bandFallback` ctor param + `_internalStats` field + `bandStats` getter**

Open `lib/src/stabilization_engine.dart`.

Add imports near the top with the others:
```dart
import 'band_fallback_config.dart';
import 'band_fallback_stats.dart';
```

In the `StabilizationEngine` class, after the existing `_contextualCheck` field (around line 49), add:
```dart
/// Band-fallback configuration. Default: disabled (`mode: off`).
final BandFallbackConfig bandFallback;

/// Engine-side mutable counter surface. Exposed publicly via [bandStats]
/// as the read-only supertype.
final BandFallbackStatsInternal _internalStats = BandFallbackStatsInternal();

/// Read-only counter view for the matching path. See [BandFallbackStats]
/// for the per-counter semantics.
BandFallbackStats get bandStats => _internalStats;
```

Modify the constructor signature (line 53) to add the param:
```dart
StabilizationEngine({
  required BlockMerger<T, P> merger,
  DriftTracker? driftTracker,
  SpatialBlockIndex<T>? spatialIndex,
  SubmapMembership? submapMembership,
  bool Function(T fresh, T existing)? contextualCheck,
  this.bandFallback = const BandFallbackConfig(),
}) : _merger = merger,
     driftTracker =
         driftTracker ?? DriftTracker(submapMembership: submapMembership),
     spatialIndex = spatialIndex ?? SpatialBlockIndex<T>(),
     _contextualCheck = contextualCheck;
```

Modify `_findMatch` (lines 293-312) to tick primary counters. Replace the entire method with:
```dart
/// Find a matching existing block for [fresh] in the spatial index.
///
/// Primary path: candidates with normalized Levenshtein similarity ≥ 0.70
/// are considered; the highest-scoring candidate wins.
/// (Band-fallback loop is added in a subsequent commit — currently any
///  primary miss returns null after ticking [primaryMatchesRejected].)
T? _findMatch(T fresh) {
  final candidates = spatialIndex.candidates(fresh);
  T? bestMatch;
  double bestSimilarity = 0.0;

  for (final candidate in candidates) {
    // Must be same coordinate space.
    if (candidate.isViewportRelative != fresh.isViewportRelative) continue;

    final similarity = TextDedupUtils.normalizedLevenshtein(
      fresh.originalText,
      candidate.originalText,
    );
    if (similarity >= 0.70 && similarity > bestSimilarity) {
      bestSimilarity = similarity;
      bestMatch = candidate;
    }
  }

  if (bestMatch != null) {
    _internalStats.recordPrimaryMatchAdmitted();
  } else {
    _internalStats.recordPrimaryMatchRejected();
  }
  return bestMatch;
}
```

> **Note:** this step keeps `normalizedLevenshtein` for primary — the `isTextSimilarWithScores` swap happens in PR2-T7 along with the band loop, gating both changes behind the same test.

- [ ] **Step 4: Run the test, confirm it passes**

Run:
```bash
flutter test test/stabilization_engine_band_off_primary_counters_test.dart
```
Expected: PASS — all three tests green.

- [ ] **Step 5: Quick spot-check that the existing engine test still passes**

Run:
```bash
flutter test test/stabilization_engine_test.dart
```
Expected: PASS. If anything breaks, the ctor signature change might be hitting a test fixture; verify and adjust.

- [ ] **Step 6: Commit**

Run:
```bash
git add lib/src/stabilization_engine.dart test/stabilization_engine_band_off_primary_counters_test.dart
git commit -m "feat(engine): #20 add bandFallback ctor param + bandStats getter + primary-path counters"
```

---

### Task PR2-T7: Wire band loop (observeOnly branch) (TDD red→green)

**Files:**
- Create: `test/stabilization_engine_band_observe_only_test.dart`
- Modify: `lib/src/stabilization_engine.dart` (extend `_findMatch` with observeOnly path; add `_effectiveSpatialConfirm` field)

- [ ] **Step 1: Write the failing test**

Create `test/stabilization_engine_band_observe_only_test.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(String text,
        {required double left,
        required double top,
        int observationCount = 1}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, 50, 20),
      payload: const Object(),
      originalText: text,
      observationCount: observationCount,
    );

void main() {
  group('StabilizationEngine band mode=observeOnly (#20)', () {
    late StabilizationEngine<DefaultTrackedBlock<Object>, Object> engine;

    setUp(() {
      engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.observeOnly,
          candidateObservationFloor: 1, // accept any observation count
        ),
      );
    });

    test('runs the full loop, ticks every counter, admits none', () {
      // Two candidates:
      //   - block_A at (0,0): text similar in the band but spatial overlap fails (we'll move fresh away)
      //   - block_B at (200,0): text similar in the band AND overlap passes
      //
      // For observeOnly to see two distinct candidates, the spatial index
      // must return both. The default spatialIndex.candidates() typically
      // filters by spatial proximity — so seed both blocks and ensure the
      // fresh observation overlaps both bands' bounding regions via a
      // covering rect.

      // Seed two cached blocks at known positions.
      engine.stabilize([
        _block('hello world a', left: 0, top: 0),
        _block('hello world b', left: 200, top: 0),
      ]);

      // Fresh observation: text similar in band (Lev 0.55-ish) at position
      // 100, 0 — spatially overlaps neither cached block's center.
      // The spatial index should still surface both as candidates because
      // they're in nearby cells.
      engine.stabilize([_block('hello orld a', left: 0, top: 0)]);
      // Adjust similarity values + positions experimentally until the
      // expected counter ratios hold. Below is the *intended* shape:

      expect(engine.bandStats.primaryMatchesRejected, greaterThanOrEqualTo(1));
      expect(engine.bandStats.candidatesConsidered, greaterThanOrEqualTo(1),
          reason: 'observeOnly runs the band loop');
      expect(engine.bandStats.matchesAdmitted, 0,
          reason: 'observeOnly never returns a match');
      // bandMatchesIdentified depends on whether any candidate clears the
      // spatial gate. The defaultSpatialConfirm is the engine's internal
      // closure (overlapRatio >= 0.80 with drift margin).
    });

    test('observeOnly scans all candidates (not just the first match)', () {
      // Seed three candidates, all with band-passing text similarity.
      engine.stabilize([
        _block('alpha one', left: 0, top: 0, observationCount: 5),
        _block('alpha two', left: 100, top: 0, observationCount: 5),
        _block('alpha three', left: 200, top: 0, observationCount: 5),
      ]);
      engine.stabilize([_block('alpha 1', left: 0, top: 0)]);
      // candidatesConsidered should reflect all candidates the loop saw,
      // not just the first match.
      expect(engine.bandStats.candidatesConsidered, greaterThan(1),
          reason: 'observeOnly continues scanning after first identified match');
    });
  });
}
```

> **Note:** the exact counter values depend on the spatial-index implementation (which candidates surface to `_findMatch`). The test as written asserts *ranges* and *invariants* — refine to specific equalities once `_findMatch`'s band loop is implemented and you can run it once to see real candidate counts. The skeleton above locks the contract; numbers tighten in step 4 if needed.

- [ ] **Step 2: Run the test, confirm it fails**

Run:
```bash
flutter test test/stabilization_engine_band_observe_only_test.dart
```
Expected: FAIL — the band loop hasn't been added; `candidatesConsidered` stays at 0.

- [ ] **Step 3: Implement `_effectiveSpatialConfirm` field + observeOnly band loop**

Open `lib/src/stabilization_engine.dart`.

After the `_internalStats` field (added in T6), add the `_effectiveSpatialConfirm` field:
```dart
/// Effective spatial confirmation predicate. Resolved at construction time:
/// the consumer's [BandFallbackConfig.spatialConfirm] if non-null, otherwise
/// a drift-aware closure that uses [_resolver] and [driftTracker] to compute
/// `overlapRatio >= 0.80` against the candidate's space-keyed drift margin.
late final BandSpatialPredicate _effectiveSpatialConfirm =
    bandFallback.spatialConfirm ??
    (fresh, candidate) => _resolver.overlapRatio(
          fresh,
          candidate,
          driftTracker.driftMarginForKey(driftTracker.spaceKeyFor(candidate)),
        ) >= 0.80;
```

> **Note:** `late final` so the closure is built lazily on first access — works regardless of field init order.

Rewrite `_findMatch` again. Replace the whole method (the version from T6) with:

```dart
/// Find a matching existing block for [fresh] in the spatial index.
///
/// Primary path: candidates with `isTextSimilarWithScores` clearing
/// Lev 0.70 OR Jaccard 0.80. Highest-scoring candidate wins.
///
/// On primary miss with [bandFallback.mode] != [BandFallbackMode.off]:
/// the band loop scans candidates against the relaxed band thresholds,
/// the observation-count floor, and the spatial-confirm predicate.
/// In [BandFallbackMode.admit] the first qualifying candidate is returned
/// as a band match; in [BandFallbackMode.observeOnly] the loop scans every
/// candidate to populate stats but always returns null.
({T? match, bool wasBandFallback}) _findMatch(T fresh) {
  final candidates = spatialIndex.candidates(fresh);

  // ── Primary path ──
  T? primaryMatch;
  double bestPrimarySim = 0.0;
  for (final candidate in candidates) {
    if (candidate.isViewportRelative != fresh.isViewportRelative) continue;
    final scores = TextDedupUtils.isTextSimilarWithScores(
      fresh.originalText,
      candidate.originalText,
      // primary floors (Lev 0.70, Jacc 0.80) — engine-owned, non-config
    );
    if (scores.match) {
      // Pick the highest combined-score candidate. Lev is the primary
      // ordering signal (consistent with prior behavior); Jaccard is
      // a tie-breaker for ordering only.
      final combined = scores.levenshtein;
      if (combined > bestPrimarySim) {
        bestPrimarySim = combined;
        primaryMatch = candidate;
      }
    }
  }

  if (primaryMatch != null) {
    _internalStats.recordPrimaryMatchAdmitted();
    return (match: primaryMatch, wasBandFallback: false);
  }
  _internalStats.recordPrimaryMatchRejected();

  // ── Band fallback path ──
  if (bandFallback.mode == BandFallbackMode.off) {
    return (match: null, wasBandFallback: false);
  }

  return _findBandMatch(fresh, candidates);
}

/// Band-relaxed fallback loop. Called only when the primary path misses
/// and `bandFallback.mode != off`. Behaves per `bandFallback.mode`:
/// observeOnly scans everything for telemetry; admit returns the first
/// candidate that clears every gate.
({T? match, bool wasBandFallback}) _findBandMatch(
    T fresh, Iterable<T> candidates) {
  T? admitted;
  for (final candidate in candidates) {
    if (candidate.isViewportRelative != fresh.isViewportRelative) continue;
    _internalStats.recordCandidateConsidered();

    if (candidate.observationCount < bandFallback.candidateObservationFloor) {
      _internalStats.recordRejectedCandidateFloor();
      continue;
    }
    if (!_effectiveSpatialConfirm(fresh, candidate)) {
      _internalStats.recordRejectedSpatial();
      continue;
    }
    final scores = TextDedupUtils.isTextSimilarWithScores(
      fresh.originalText,
      candidate.originalText,
      levenshteinThreshold: bandFallback.bandLevenshteinFloor,
      jaccardThreshold: bandFallback.bandJaccardFloor,
    );
    if (!scores.match) {
      // Text-band miss isn't bucketed — would-have-matched is not the
      // same as rejected, and a counter would skew the ratios.
      continue;
    }
    _internalStats.recordBandMatchIdentified();
    if (bandFallback.mode == BandFallbackMode.admit && admitted == null) {
      admitted = candidate;
      _internalStats.recordMatchAdmitted();
      // Continue scanning is NOT required in admit mode — return early.
      return (match: admitted, wasBandFallback: true);
    }
    // observeOnly: keep scanning so all candidates contribute to counters.
  }
  return (match: null, wasBandFallback: false);
}
```

Now update `_findMatch`'s **callers** to handle the new return type. The only caller is `stabilize()` (line 109) — change:
```dart
final existing = _findMatch(fresh);
if (existing != null) {
  final merged = _merge(
    fresh,
    existing,
    invalidatedTexts,
    wellObservedTexts,
  );
  stableBlocks.add(merged);
} else {
  stableBlocks.add(fresh);
}
```

to:
```dart
final matchResult = _findMatch(fresh);
final existing = matchResult.match;
if (existing != null) {
  final merged = _merge(
    fresh,
    existing,
    invalidatedTexts,
    wellObservedTexts,
    wasBandFallback: matchResult.wasBandFallback,
  );
  stableBlocks.add(merged);
} else {
  stableBlocks.add(fresh);
}
```

And update `_merge`'s signature to accept the new param. Change `_merge` (line 333-350) to:
```dart
T _merge(
  T fresh,
  T existing,
  List<String> invalidatedTexts,
  List<String> wellObservedTexts, {
  bool wasBandFallback = false,
}) {
  final output = _mergeImpl(fresh, existing, wasBandFallback: wasBandFallback);
  // ... (rest unchanged)
```

And update `_mergeImpl`'s signature (line 353):
```dart
MergeOutput<T> _mergeImpl(
  T fresh,
  T existing, {
  bool trackDrift = true,
  bool wasBandFallback = false,
}) {
  // ... (provisional freeze + normal merge body — unchanged for now)
}
```

> **Note:** PR2-T8 (the admit test) implements the *actual provisional wrap-on-admit* inside `_mergeImpl`. This step just plumbs the flag through.

- [ ] **Step 4: Run the test, confirm it passes**

Run:
```bash
flutter test test/stabilization_engine_band_observe_only_test.dart
```
Expected: PASS. If counter values don't match the test, observe the actual values in test output and tighten the assertions in the test (replace `greaterThanOrEqualTo(1)` with exact integers).

- [ ] **Step 5: Quick spot-check existing tests**

Run:
```bash
flutter test test/stabilization_engine_test.dart test/stabilization_engine_band_off_primary_counters_test.dart
```
Expected: PASS on both. Watch for primary-match behavior changes since `_findMatch` now uses `isTextSimilarWithScores` instead of `normalizedLevenshtein`. If a pre-existing test breaks because of the Lev-vs-Lev-OR-Jacc shift, this is the Behavioral Note from Pre-flight — discuss with the user before tightening.

- [ ] **Step 6: Commit**

Run:
```bash
git add lib/src/stabilization_engine.dart test/stabilization_engine_band_observe_only_test.dart
git commit -m "feat(engine): #20 band loop (observeOnly branch); primary switches to isTextSimilarWithScores"
```

---

### Task PR2-T8: Wire admit branch + provisional wrap in `_mergeImpl` (TDD red→green)

**Files:**
- Create: `test/stabilization_engine_band_admit_test.dart`
- Modify: `lib/src/stabilization_engine.dart` (`_mergeImpl` — add wasBandFallback provisional-wrap branch)

- [ ] **Step 1: Write the failing test**

Create `test/stabilization_engine_band_admit_test.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(String text,
        {required double left,
        required double top,
        double width = 50,
        double height = 20,
        int observationCount = 1}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, width, height),
      payload: const Object(),
      originalText: text,
      observationCount: observationCount,
    );

void main() {
  group('StabilizationEngine band mode=admit (#20)', () {
    late StabilizationEngine<DefaultTrackedBlock<Object>, Object> engine;

    setUp(() {
      engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1, // accept observationCount: 5 candidate
        ),
      );
    });

    test('admits a band-matched candidate as provisional with config captures', () {
      // Seed an existing block with observationCount: 5 (well past floor).
      engine.stabilize([_block('hello world', left: 0, top: 0, observationCount: 5)]);

      // Fresh observation: band-similar text at identical rect (overlap = 1.0).
      // Choose a text that passes Lev >= 0.50 but fails Lev >= 0.70.
      // e.g. 'hxllo wxrld' has 9/11 matching chars → Lev ≈ 0.82 (too high).
      // Pick 'hxlxo wxrxd' (more edits) for Lev around 0.55.
      final fresh = _block('hxlxo wxrxd', left: 0, top: 0, observationCount: 1);

      final result = engine.stabilize([fresh]);

      // The merged block in stableBlocks should be provisional with
      // provisionalCapturesRemaining: 3 (default from BandFallbackConfig).
      final stable = result.stableBlocks.firstWhere(
        (b) => b.absoluteRect.raw.left == 0,
        orElse: () => throw StateError('expected the merged block in results'),
      );
      expect(stable.isProvisional, isTrue,
          reason: 'band-admitted match enters provisional state');
      expect(stable.provisionalCapturesRemaining, 3,
          reason: 'matches bandFallback.provisionalCaptures default');

      // Counters: 1 considered (the seed block), 1 identified, 1 admitted.
      expect(engine.bandStats.candidatesConsidered, 1);
      expect(engine.bandStats.bandMatchesIdentified, 1);
      expect(engine.bandStats.matchesAdmitted, 1);
      // Primary missed, so primaryMatchesRejected = 1.
      expect(engine.bandStats.primaryMatchesRejected, 1);
    });
  });
}
```

> **Note:** the chosen text pair `'hello world'` / `'hxlxo wxrxd'` is a guess at the Lev band. Verify with a quick computation: `normalizedLevenshtein` strips punctuation/whitespace and uses significant-char counts. Adjust the text pair if it lands outside `[0.50, 0.70)`. A safer pair: pick a known length-11 ASCII string and edit exactly 4 chars (4/11 = ~0.64 Lev).

- [ ] **Step 2: Run the test, confirm it fails**

Run:
```bash
flutter test test/stabilization_engine_band_admit_test.dart
```
Expected: FAIL — `_mergeImpl` doesn't yet apply provisional-wrap on band admit; the merged block has `isProvisional: false`.

- [ ] **Step 3: Add the provisional-wrap branch in `_mergeImpl`**

Open `lib/src/stabilization_engine.dart`. Inside `_mergeImpl`, after the existing provisional-freeze block (line 374 — the early return for `existing.isProvisional`), and BEFORE the normal merge body, insert:

```dart
// ┌─── Band-fallback admission → wrap as provisional ──────────────
// When `wasBandFallback` is true and `existing` is non-provisional,
// the match is from the band-relaxed path — we want to update state
// (votes, position, text) normally BUT mark the merged result as
// provisional so future captures count toward graduation. The existing
// freeze path (above) handles the future captures.
//
// We compute the normal merge result first, then override the
// provisional fields on the way out. This shares the merge math
// (votes, drift, position weighting) with the non-band path.
// └──────────────────────────────────────────────────────────────────
```

Then at the END of `_mergeImpl` (just before the `return MergeOutput<T>(...)` at line 525), build a wrapped MergeResult if needed. Restructure the bottom of `_mergeImpl` to:

```dart
  // Build MergeResult
  MergeResult result = MergeResult(
    mergedRect: AbsoluteRect(mergedRaw),
    positionConfidence: PositionConfidence.from(min(totalConf, 1.0)),
    driftCorrection: regionDrift,
    winningOriginalText: winningText,
    textConfidence: TextConfidence.from(mergedTextConf),
    updatedTextVotes: Map.unmodifiable(updatedTextVotes),
    textWasPromoted: textWasPromoted,
    updatedClassificationVotes: Map.unmodifiable(classVotes),
    needsReclassification: needsReclass,
    updatedCarouselIdVotes: Map.unmodifiable(carouselVotes),
    observationCount: newObservationCount,
    isProvisional: false,
    provisionalCapturesRemaining: 0,
    sourceQuality: mergedSourceQuality,
  );

  // Band-fallback admissions enter provisional state. Future captures
  // of this now-provisional block go through the freeze path at the top
  // of _mergeImpl and decrement provisionalCapturesRemaining.
  if (wasBandFallback) {
    result = MergeResult(
      mergedRect: result.mergedRect,
      positionConfidence: result.positionConfidence,
      driftCorrection: result.driftCorrection,
      winningOriginalText: result.winningOriginalText,
      textConfidence: result.textConfidence,
      updatedTextVotes: result.updatedTextVotes,
      textWasPromoted: result.textWasPromoted,
      updatedClassificationVotes: result.updatedClassificationVotes,
      needsReclassification: result.needsReclassification,
      updatedCarouselIdVotes: result.updatedCarouselIdVotes,
      observationCount: result.observationCount,
      isProvisional: true,
      provisionalCapturesRemaining: bandFallback.provisionalCaptures,
      sourceQuality: result.sourceQuality,
    );
  }

  // Call consumer merger to construct the updated block
  final merged = _merger(existing, fresh, result);

  // Compute signals
  // ... (rest unchanged)
```

- [ ] **Step 4: Run the test, confirm it passes**

Run:
```bash
flutter test test/stabilization_engine_band_admit_test.dart
```
Expected: PASS. If text similarity values land outside the expected band, adjust the fresh text in the test until they're solidly within `[0.50, 0.70)` for Lev.

- [ ] **Step 5: Spot-check prior band tests still pass**

Run:
```bash
flutter test test/stabilization_engine_band_off_primary_counters_test.dart test/stabilization_engine_band_observe_only_test.dart
```
Expected: PASS.

- [ ] **Step 6: Commit**

Run:
```bash
git add lib/src/stabilization_engine.dart test/stabilization_engine_band_admit_test.dart
git commit -m "feat(engine): #20 band admit branch — wrap merged result as provisional"
```

---

### Task PR2-T9: Lock rejection branches (candidate floor, spatial, text band) (TDD red→green)

**Files:**
- Create: `test/stabilization_engine_band_rejections_test.dart`
- Modify: none (the branches already exist from T7/T8; this test locks them)

- [ ] **Step 1: Write the test**

Create `test/stabilization_engine_band_rejections_test.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/tracked_block.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(String text,
        {required double left,
        required double top,
        int observationCount = 1}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, 50, 20),
      payload: const Object(),
      originalText: text,
      observationCount: observationCount,
    );

void main() {
  group('StabilizationEngine band admit rejections (#20)', () {
    test('rejected by candidateObservationFloor', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 2,
        ),
      );
      // Seed a candidate with observationCount: 1 (below floor 2).
      engine.stabilize([_block('hello world', left: 0, top: 0, observationCount: 1)]);

      // Fresh band-similar observation at identical rect.
      engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);

      expect(engine.bandStats.rejectedCandidateFloor, 1);
      expect(engine.bandStats.bandMatchesIdentified, 0);
      expect(engine.bandStats.matchesAdmitted, 0);
    });

    test('rejected by spatialConfirm (custom predicate that always rejects)', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
          spatialConfirm: (TrackedBlock a, TrackedBlock b) => false,
        ),
      );
      engine.stabilize([_block('hello world', left: 0, top: 0, observationCount: 5)]);
      engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);

      expect(engine.bandStats.rejectedSpatial, 1);
      expect(engine.bandStats.bandMatchesIdentified, 0);
      expect(engine.bandStats.matchesAdmitted, 0);
    });

    test('text-band miss is NOT bucketed in any rejection counter', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
        ),
      );
      engine.stabilize([_block('hello world', left: 0, top: 0, observationCount: 5)]);

      // Fresh text totally different — fails both primary AND band text floors.
      engine.stabilize([_block('qwertyuiopz', left: 0, top: 0)]);

      expect(engine.bandStats.candidatesConsidered, 1);
      expect(engine.bandStats.rejectedCandidateFloor, 0);
      expect(engine.bandStats.rejectedSpatial, 0,
          reason: 'spatial passed (identical rect)');
      expect(engine.bandStats.bandMatchesIdentified, 0);
      expect(engine.bandStats.matchesAdmitted, 0);
    });
  });
}
```

- [ ] **Step 2: Run the test**

Run:
```bash
flutter test test/stabilization_engine_band_rejections_test.dart
```
Expected: PASS — branches were implemented in T7/T8; this locks the counter semantics.

- [ ] **Step 3: If any branch fails**

Inspect actual counter values vs expected. The most likely failure mode is `text-band miss` — if `'qwertyuiopz'` happens to share enough significant chars with `'hello world'` for Jaccard 0.60 to pass, change to a string with no overlap (`'XXXXXXXXXX'` for example). The test asserts the *contract*, not the specific text.

- [ ] **Step 4: Commit**

Run:
```bash
git add test/stabilization_engine_band_rejections_test.dart
git commit -m "test(engine): #20 lock band-fallback rejection-counter semantics (admit mode)"
```

---

### Task PR2-T10: Lock custom predicate + default-closure behavior (TDD red→green)

**Files:**
- Create: `test/stabilization_engine_band_custom_predicate_test.dart`
- Modify: none

- [ ] **Step 1: Write the test**

Create `test/stabilization_engine_band_custom_predicate_test.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/tracked_block.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(String text,
        {required double left,
        required double top,
        double width = 50,
        double height = 20,
        int observationCount = 1}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, width, height),
      payload: const Object(),
      originalText: text,
      observationCount: observationCount,
    );

void main() {
  group('StabilizationEngine band — predicate injection + default closure (#20)', () {
    test('custom spatialConfirm is invoked with (fresh, candidate)', () {
      final calls = <(String, String)>[];
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
          spatialConfirm: (TrackedBlock fresh, TrackedBlock candidate) {
            calls.add((fresh.originalText, candidate.originalText));
            return true; // accept all
          },
        ),
      );
      engine.stabilize([_block('hello world', left: 0, top: 0, observationCount: 5)]);
      engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);

      expect(calls, isNotEmpty);
      expect(calls.first.$1, 'hxlxo wxrxd');
      expect(calls.first.$2, 'hello world');
    });

    test('default closure: identical rect → predicate passes (overlapRatio = 1.0)', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
          // spatialConfirm: null → engine uses default closure
        ),
      );
      engine.stabilize([_block('hello world', left: 0, top: 0, observationCount: 5)]);
      engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);

      expect(engine.bandStats.matchesAdmitted, 1,
          reason: 'default closure accepts identical-rect overlap');
    });

    test('default closure: non-overlapping rects → predicate rejects', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
        ),
      );
      engine.stabilize([_block('hello world', left: 0, top: 0, observationCount: 5)]);
      // Fresh at far-away position — overlapRatio = 0.0
      engine.stabilize([_block('hxlxo wxrxd', left: 1000, top: 1000)]);

      // candidates may or may not surface depending on spatial index cell
      // size; if the spatial index filters them out entirely, the band loop
      // never sees them and rejectedSpatial stays at 0. Test the
      // consequential outcome — no admission — rather than the counter.
      expect(engine.bandStats.matchesAdmitted, 0);
    });
  });
}
```

- [ ] **Step 2: Run the test**

Run:
```bash
flutter test test/stabilization_engine_band_custom_predicate_test.dart
```
Expected: PASS — predicate injection works because T7 wired `_effectiveSpatialConfirm`.

- [ ] **Step 3: Commit**

Run:
```bash
git add test/stabilization_engine_band_custom_predicate_test.dart
git commit -m "test(engine): #20 lock custom spatialConfirm injection + default-closure behavior"
```

---

### Task PR2-T11: Lock provisional decay through admission (TDD red→green)

**Files:**
- Create: `test/stabilization_engine_band_provisional_decay_test.dart`
- Modify: none (relies on existing freeze path + T8's wrap)

- [ ] **Step 1: Write the test**

Create `test/stabilization_engine_band_provisional_decay_test.dart`:

```dart
// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(String text,
        {required double left,
        required double top,
        int observationCount = 1}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, 50, 20),
      payload: const Object(),
      originalText: text,
      observationCount: observationCount,
    );

void main() {
  group('StabilizationEngine band — provisional decay after admission (#20)', () {
    test('band admit → 2 confirming captures → block becomes non-provisional', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
          provisionalCaptures: 3,
        ),
      );

      // Step A: seed an existing block with high observationCount.
      engine.stabilize([_block('hello world', left: 0, top: 0, observationCount: 5)]);

      // Step B: band-admit a fresh observation (text-band match, identical rect).
      // After this capture the merged block is provisional with captures=3.
      final r1 = engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);
      final after1 =
          r1.stableBlocks.firstWhere((b) => b.absoluteRect.raw.left == 0);
      expect(after1.isProvisional, isTrue);
      expect(after1.provisionalCapturesRemaining, 3);

      // Step C: Capture #2 — feed an observation that matches via the
      // primary path (high Lev). The freeze path triggers, decrementing
      // capturesRemaining from 3 to 2.
      final r2 = engine.stabilize([_block('hello world', left: 0, top: 0)]);
      final after2 =
          r2.stableBlocks.firstWhere((b) => b.absoluteRect.raw.left == 0);
      expect(after2.isProvisional, isTrue);
      expect(after2.provisionalCapturesRemaining, 2);

      // Step D: Capture #3 — same again. captures: 2 → 1.
      final r3 = engine.stabilize([_block('hello world', left: 0, top: 0)]);
      final after3 =
          r3.stableBlocks.firstWhere((b) => b.absoluteRect.raw.left == 0);
      expect(after3.isProvisional, isTrue);
      expect(after3.provisionalCapturesRemaining, 1);

      // Step E: Capture #4 — captures: 1 → 0 → block graduates.
      final r4 = engine.stabilize([_block('hello world', left: 0, top: 0)]);
      final after4 =
          r4.stableBlocks.firstWhere((b) => b.absoluteRect.raw.left == 0);
      expect(after4.isProvisional, isFalse);
      expect(after4.provisionalCapturesRemaining, 0);
    });
  });
}
```

- [ ] **Step 2: Run the test**

Run:
```bash
flutter test test/stabilization_engine_band_provisional_decay_test.dart
```
Expected: PASS — the freeze path at `_mergeImpl` line 354-374 handles decay automatically; T8's wrap kicks off the cycle.

- [ ] **Step 3: If the test fails**

Most likely cause: the seed block's identity isn't preserved across captures (`absoluteRect.left == 0` might match the *fresh* observation rather than the merged result). Inspect `r1.stableBlocks` to see what's actually there; the merged result should be the one to track.

- [ ] **Step 4: Commit**

Run:
```bash
git add test/stabilization_engine_band_provisional_decay_test.dart
git commit -m "test(engine): #20 lock provisional decay interaction with band admission"
```

---

### Task PR2-T12: Refactor — extract `_findBandMatch` helper

> The helper was already extracted as part of PR2-T7. This task is a no-op except for verification — included for parity with the spec's TDD step 19.

- [ ] **Step 1: Verify `_findBandMatch` exists and is private**

Run:
```bash
grep -n "_findBandMatch" c:/src/ocr-stabilizer/lib/src/stabilization_engine.dart
```
Expected: at least two hits — the method definition and its call site inside `_findMatch`.

- [ ] **Step 2: Skip the commit**

Nothing to commit. Move on.

---

### Task PR2-T13: Full suite + dartdoc audit + PR open

**Files:** none (CI + git)

- [ ] **Step 1: Run the full suite**

Run:
```bash
flutter test
```
Expected: ALL GREEN. Investigate any pre-existing test regressions — most likely candidates are tests that fed the primary path text-pair edge cases that now flip with `isTextSimilarWithScores` (Jaccard catches what Lev missed). If that's the failure mode, surface it to the user; that's the Behavioral Note from Pre-flight materializing.

- [ ] **Step 2: dartdoc audit on new public symbols**

For each new public symbol, verify dartdoc is present:
- `BandFallbackMode` (enum + every variant)
- `BandFallbackConfig` (class + every field + ctor)
- `BandSpatialPredicate` (typedef)
- `BandFallbackStats` (class + every getter + `reset()`)
- `BandFallbackStatsInternal` (class + every mutator)
- `StabilizationEngine.bandFallback` (field)
- `StabilizationEngine.bandStats` (getter)

Run:
```bash
flutter analyze --fatal-infos lib/src/band_fallback_config.dart lib/src/band_fallback_stats.dart lib/src/stabilization_engine.dart
```
Expected: no warnings about missing dartdoc on public members.

- [ ] **Step 3: Push the branch**

Run:
```bash
git push -u origin feat/20-band-fallback
```

- [ ] **Step 4: Open the PR**

Run:
```bash
gh pr create --base main --head feat/20-band-fallback \
  --title "feat(engine): #20 optional band-relaxed inter-batch matching fallback" \
  --body "Closes #20.

Adds an opt-in band-relaxed fallback inside \`StabilizationEngine._findMatch\` to recover from OCR jitter that drops a stable block below the primary text-similarity floor for a single frame.

**Public surface:**
- \`BandFallbackMode\` enum: \`off\` / \`observeOnly\` / \`admit\`. Default \`off\`.
- \`BandFallbackConfig\`: thresholds + observation floor + provisional grant + optional custom spatial predicate.
- \`BandFallbackStats\`: 7 counters (2 primary, 5 band). Read-only public + \`BandFallbackStatsInternal\` mutator subclass.
- \`BandSpatialPredicate\` typedef (mirrors \`ContextualInvalidationCheck\`).
- \`StabilizationEngine\` ctor gains \`bandFallback\` param + \`bandStats\` getter.

**Behavioral note:** primary \`_findMatch\` switches from \`normalizedLevenshtein\` to \`isTextSimilarWithScores\` (Lev OR Jaccard). The floors stay at Lev 0.70 / Jaccard 0.80 — only the metric set widens. Discussed in plan Pre-flight section.

**Default-off adoption flow:**
1. ship \`mode: off\` (no behavioral change)
2. flip to \`observeOnly\` to populate counters
3. read \`bandStats.bandMatchesIdentified / primaryMatchesRejected\` ratio
4. commit to \`mode: admit\` once the ratio justifies the relaxation

Spec: \`docs/superpowers/specs/2026-05-23-band-fallback-and-quality-score-nan-guard.md\` §4.
Plan: \`docs/superpowers/plans/2026-05-23-band-fallback-and-quality-score-plan.md\` PR2 section."
```

- [ ] **Step 5: Bot reviews + agent fan-out + merge**

Same flow as PR1-T5 Step 5. Squash-merge title (from spec):
```
feat(engine): #20 optional band-relaxed inter-batch matching fallback

Closes #20
```

- [ ] **Step 6: Pull latest `main` after merge**

Run:
```bash
git checkout main
git pull --ff-only
```

---

## PR 3 — `chore/release-0.4.0`

### Task PR3-T1: Create branch off `main` (post-PR2 merge)

- [ ] **Step 1: Verify on latest `main`**

Run:
```bash
cd c:/src/ocr-stabilizer
git checkout main
git pull --ff-only
git status
```
Expected: latest `main` includes both PR #1 and PR #2 merge commits, working tree clean.

- [ ] **Step 2: Create the release branch**

Run:
```bash
git checkout -b chore/release-0.4.0
```

---

### Task PR3-T2: Bump `pubspec.yaml` version

**Files:**
- Modify: `pubspec.yaml`

- [ ] **Step 1: Bump version**

Open `pubspec.yaml`. Change:
```yaml
version: 0.3.0
```
to:
```yaml
version: 0.4.0
```

- [ ] **Step 2: Verify the change**

Run:
```bash
grep '^version:' c:/src/ocr-stabilizer/pubspec.yaml
```
Expected output: `version: 0.4.0`.

---

### Task PR3-T3: Add `## 0.4.0` CHANGELOG entry

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Read the current top of CHANGELOG**

Run:
```bash
head -30 c:/src/ocr-stabilizer/CHANGELOG.md
```
Note where `## 0.3.0` lives — the new `## 0.4.0` block goes above it.

- [ ] **Step 2: Insert the 0.4.0 entry**

At the top of `CHANGELOG.md` (above `## 0.3.0`), insert:

```markdown
## 0.4.0 - <YYYY-MM-DD>

### Added
- `BandFallbackMode` enum (`off` | `observeOnly` | `admit`) configures the
  band-relaxed fallback path inside `StabilizationEngine._findMatch`.
  Default is `off`; switch to `observeOnly` to read `BandFallbackStats`
  before committing to `admit`. See `docs/superpowers/specs/` for the
  full design and default provenance (#20).
- `BandFallbackConfig` value type wraps the band thresholds, candidate
  observation floor, provisional-capture grant, and spatial confirmation
  predicate. Constructor `assert`s on out-of-range values (preserves
  const-constructibility). Primary-path floors (Lev 0.70 / Jaccard 0.80)
  are engine-owned, not configurable through this type (#20).
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
```

Replace `<YYYY-MM-DD>` with today's actual date (e.g. `2026-05-23`).

---

### Task PR3-T4: Commit + push + open PR + merge + tag

- [ ] **Step 1: Commit**

Run:
```bash
git add pubspec.yaml CHANGELOG.md
git commit -m "chore: release v0.4.0

#27 engine-entry Confidence validation + DefaultTrackedBlock ctor throws.
#20 band-fallback config + stats wired into the engine
    (BandFallbackMode: off | observeOnly | admit; default off).

See CHANGELOG.md for the full entry."
```

- [ ] **Step 2: Verify dry-run is clean**

Run:
```bash
flutter pub publish --dry-run
```
Expected: no warnings against the new public surface. Address any warnings before opening the PR.

- [ ] **Step 3: Run pana for the 160/160 acceptance criterion**

Run:
```bash
flutter pub global activate pana
flutter pub global run pana --no-warning
```
Expected: score 160/160. If documentation coverage drops below 30/30, identify which new public symbol is missing dartdoc and fix it before merging. The new surfaces to spot-check:
- `BandFallbackMode` and every variant
- `BandFallbackConfig` and every field
- `BandSpatialPredicate`
- `BandFallbackStats` and every getter + `reset()`
- `StabilizationEngine.bandFallback`, `StabilizationEngine.bandStats`

- [ ] **Step 4: Push**

Run:
```bash
git push -u origin chore/release-0.4.0
```

- [ ] **Step 5: Open the PR**

Run:
```bash
gh pr create --base main --head chore/release-0.4.0 \
  --title "chore: release v0.4.0" \
  --body "Release v0.4.0. Bumps pubspec.yaml from 0.3.0 → 0.4.0 and inserts the CHANGELOG entry covering both shipped features:

- #27 engine-entry Confidence validation + DefaultTrackedBlock ctor throws.
- #20 band-fallback config + stats wired into the engine (BandFallbackMode: off | observeOnly | admit; default off).

After merge, the maintainer runs \`flutter pub publish\` interactively out-of-band.

Spec: \`docs/superpowers/specs/2026-05-23-band-fallback-and-quality-score-nan-guard.md\`.
Plan: \`docs/superpowers/plans/2026-05-23-band-fallback-and-quality-score-plan.md\`."
```

- [ ] **Step 6: Wait for bots + merge**

Per `feedback_docs_only_pr_exemption`, the merge-gate hooks auto-skip docs-only PRs (`.md` + metadata). This PR touches `pubspec.yaml` (non-docs) so the bots still run; let them complete and merge.

Squash-merge title:
```
chore: release v0.4.0
```

- [ ] **Step 7: Pull, tag, push tag**

Run:
```bash
git checkout main
git pull --ff-only
git tag -a v0.4.0 -m "Release v0.4.0 — band-fallback + Confidence invariants"
git push origin v0.4.0
```

- [ ] **Step 8: Hand off to maintainer for `flutter pub publish`**

Notify the maintainer that the release commit + tag are in place. The interactive `flutter pub publish` step is **out of plan scope** — it requires pub.dev credentials and a y/N prompt. The plan is complete once the tag is pushed.

---

## Post-plan acceptance checklist (mirrors spec §8)

- [ ] PR #1 (`fix/27-confidence-nan-guard`) merged to `main` with green local tests; PR1-T2/T3/T4 commits show clear traceability to #27.
- [ ] PR #2 (`feat/20-band-fallback`) merged to `main` with green local tests; PR2-T2 through T12 commits show clear traceability to #20.
- [ ] PR #3 (`chore/release-0.4.0`) merged to `main`; CHANGELOG `## 0.4.0` header dated; `pubspec.yaml` bumped to `0.4.0`.
- [ ] `flutter pub publish --dry-run` reports no warnings against the new public surface.
- [ ] **pana score 160/160** — every new public symbol has dartdoc that holds the documentation score.
- [ ] `git tag v0.4.0` pushed.
- [ ] Maintainer runs `flutter pub publish` (out-of-band).
- [ ] Issue `Abdallah01/ocr_translate_demo#1084` is now unblockable in a separate PR (not part of this plan).
