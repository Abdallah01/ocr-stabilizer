# Contributing to ocr_stabilizer

## Dev setup

```bash
flutter pub get
flutter test      # must be green before you start
```

## Branches

Prefix branches by intent: `feat/`, `fix/`, `perf/`, `docs/`, `chore/`, `release/`.

## Commits

Conventional Commits — `feat:`, `fix:`, `docs:`, `perf:`, `chore:`. Reference an
issue with `fix: #N ...` to auto-close it on merge.

## Tests

- Every bug fix lands with a regression test.
- Every new feature lands with at least one test exercising the documented API.
- The analyzer must stay at zero issues — `public_member_api_docs: true` is on,
  so every public member needs a doc comment.

## Storage / state invariants

Production-critical invariants on stored state must `throw ArgumentError`, not
just `assert` — asserts strip in release builds. See `lib/src/merge_result.dart`
and `lib/src/default_tracked_block.dart` for the pattern.

## Public API discipline

Changes that alter the shape of `TrackedBlock`, `ObservableBlock`, `MergeResult`,
or `StabilizationEngine` are breaking. Pre-1.0, a breaking change requires a
minor version bump and a `CHANGELOG.md` `### Breaking` entry with a diff-style
migration block.

## Release flow

1. Bump `version:` in `pubspec.yaml` and add a `CHANGELOG.md` entry.
2. Merge the `release/vX.Y.Z` PR.
3. Tag `vX.Y.Z` and create a GitHub release with notes copied from the CHANGELOG.
