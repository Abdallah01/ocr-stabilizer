/// Stable content-hash identifier for a scrollable container element.
///
/// Wraps a hash string computed by the host application. Zero runtime cost —
/// Dart erases to raw [String].
extension type const ContainerId(String hash) {}
