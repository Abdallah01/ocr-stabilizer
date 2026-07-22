/// Pure-Dart replacement for `package:flutter/foundation.dart`'s
/// `kDebugMode`.
///
/// True only in debug builds — false in both product (release) and
/// profile builds, mirroring the Flutter constant exactly
/// (`kDebugMode = !kReleaseMode && !kProfileMode`): it evaluates to
/// `true` under `dart run` / `dart test` and to `false` under
/// `dart compile exe` release, AOT product builds, and profile-mode
/// builds (`dart.vm.profile`). Being a `const`, debug-only branches
/// guarded by it are tree-shaken out of non-debug builds exactly as
/// with the Flutter original.
library;

/// Whether the current build retains debug diagnostics (debug mode only).
const bool kDebugMode = !bool.fromEnvironment('dart.vm.product') &&
    !bool.fromEnvironment('dart.vm.profile');
