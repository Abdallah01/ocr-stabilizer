import 'hierarchy_tiers.dart';
import 'tracked_block.dart';

/// Hierarchy weight tiers for block classification.
///
/// Higher weight = more constrained coordinate space. The engine uses these
/// tiers to decide which blocks participate in drift computation and how
/// spatial conflicts are resolved.
///
/// Tiers: VR (40) > Nested IC+carousel (30) > IC or carousel (20) > Normal (10).
extension HierarchyWeightX on TrackedBlock {
  /// Compute hierarchy weight from coordinate-space flags.
  int get hierarchyWeight {
    if (isViewportRelative) return HierarchyTiers.viewport;
    if (isInnerScrollerChild && isHorizontalScrollChild) {
      return HierarchyTiers.nested;
    }
    if (isInnerScrollerChild || isHorizontalScrollChild) {
      return HierarchyTiers.constrained;
    }
    return HierarchyTiers.normal;
  }
}
