import 'hierarchy_tiers.dart';
import 'hierarchy_weight.dart';
import 'submap_membership.dart';
import 'tracked_block.dart';
import 'types/space_key.dart';

/// CSS-topology submap membership for WebView-based OCR.
///
/// Partitioning rules:
/// - VR blocks (weight 40): excluded from observation (viewport-fixed)
/// - Nested IC+carousel (weight 30): excluded (compound coordinate space)
/// - Carousel-only (weight 20 + isHorizontalScrollChild): excluded
/// - IC with containerId: `SpaceKey.ic(containerId, regionIndex)`
/// - IC without containerId: `SpaceKey.unknown()` (excluded)
/// - Normal blocks: `SpaceKey.normal(regionIndex)`
class CssSubmapMembership implements SubmapMembership {
  /// CSS px per scroll region for region index computation.
  @override
  final int regionSize;

  /// Creates a CSS-topology submap membership strategy.
  const CssSubmapMembership({this.regionSize = 500})
    : assert(regionSize > 0, 'regionSize must be positive');

  @override
  SpaceKey spaceKeyFor(TrackedBlock block) {
    final regionIndex = (block.absoluteRect.top / regionSize).floor();
    if (block.hierarchyWeight == HierarchyTiers.constrained) {
      if (block.containerId != null) {
        return SpaceKey.ic(block.containerId!, regionIndex);
      }
      // IC block without containerId — indeterminate coordinate space.
      // Carousel-only blocks (isHorizontalScrollChild but not
      // isInnerScrollerChild) share the same weight but live in normal
      // vertical scroll space, so they fall through to normal.
      if (block.isInnerScrollerChild) return SpaceKey.unknown();
    }
    return SpaceKey.normal(regionIndex);
  }

  @override
  bool shouldExcludeFromObservation(TrackedBlock block) {
    // VR blocks (weight 40): viewport-fixed, no scroll drift
    if (block.hierarchyWeight >= HierarchyTiers.viewport) return true;
    // Nested IC+carousel: compound coordinate space
    if (block.hierarchyWeight >= HierarchyTiers.nested) return true;
    // Carousel-only
    if (block.hierarchyWeight == HierarchyTiers.constrained &&
        block.isHorizontalScrollChild) {
      return true;
    }
    // IC without containerId: indeterminate coordinate space
    if (block.hierarchyWeight == HierarchyTiers.constrained &&
        block.containerId == null) {
      return true;
    }
    return false;
  }
}
