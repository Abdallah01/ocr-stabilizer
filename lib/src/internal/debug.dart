/// Pure-Dart replacement for `package:flutter/foundation.dart`'s
/// `kDebugMode`.
///
/// True in debug builds and false in release/product builds, mirroring the
/// Flutter constant's behavior: `dart.vm.product` is defined as `true` only
/// for product (release) builds, so this evaluates to `true` under
/// `dart run` / `dart test` and to `false` under `dart compile exe` release
/// or AOT product builds. Being a `const`, debug-only branches guarded by
/// it are tree-shaken out of product builds exactly as with the Flutter
/// original.
library;

/// Whether the current build retains debug diagnostics (non-product mode).
const bool kDebugMode = !bool.fromEnvironment('dart.vm.product');
