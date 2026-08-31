# Contributing to ocr_stabilizer

## Dev setup

```bash
flutter pub get
flutter test      # must be green before you start
```

## Branches

Prefix branches by intent: `feat/`, `fix/`, `perf/`, `refactor/`, `test/`, `ci/`, `docs/`, `chore/`, `release/`.

## Commits

Conventional Commits — `feat:`, `fix:`, `docs:`, `perf:`, `refactor:`, `test:`,
`ci:`, `chore:`. To auto-close an issue on merge, put a closing keyword
(`Closes #N`, `Fixes #N`) in the commit body or PR description — not the
`type:` subject prefix.

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

Within a major series (2.x today), API surface changes are additive.
Changes that alter the shape of `TrackedBlock`, `ObservableBlock`,
`MergeResult`, or `StabilizationEngine` are compile-breaking and wait for
the next major, with a `CHANGELOG.md` `### Breaking` entry carrying a
diff-style migration block. A behavioral-default change (numerics,
matching) may ride a minor version, but only with a CHANGELOG entry that
names an exact configuration reproducing the prior numerics bit-for-bit —
the escape-hatch convention; `doc/CONTRACT.md` G5 keeps the table.

## Release flow

1. Bump `version:` in `pubspec.yaml` and add a `CHANGELOG.md` entry.
2. Merge the `release/vX.Y.Z` PR.
3. Tag `vX.Y.Z` and create a GitHub release with notes copied from the CHANGELOG.
