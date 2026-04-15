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
  int get regionIndex => int.parse(_raw.split(':').last);
}
