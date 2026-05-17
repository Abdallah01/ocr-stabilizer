import 'container_id.dart';

/// Typed key identifying a drift observation coordinate space.
///
/// Format: `"normal:<regionIndex>"`, `"ic:<containerId>:<regionIndex>"`,
/// or `"unknown:0"` (indeterminate space — no correction applied).
extension type const SpaceKey(String _raw) {
  /// Key for a normal (page-scroll) region.
  SpaceKey.normal(int regionIndex) : _raw = 'normal:$regionIndex';

  /// Key for an inner-scroller container region.
  SpaceKey.ic(ContainerId containerId, int regionIndex)
    : _raw = 'ic:${containerId.hash}:$regionIndex';

  /// Sentinel for blocks whose coordinate space is indeterminate.
  SpaceKey.unknown() : _raw = 'unknown:0';

  /// The region index encoded in this key.
  ///
  /// Returns 0 as a safe fallback if the trailing segment is not a valid
  /// integer (forward-compat: future format extensions and externally-
  /// constructed keys must not crash callers). See #1.
  int get regionIndex => int.tryParse(_raw.split(':').last) ?? 0;
}
