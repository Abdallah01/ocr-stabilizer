// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'hierarchy_tiers.dart';
import 'hierarchy_weight.dart';
import 'submap_membership.dart';
import 'tracked_block.dart';
import 'types/space_key.dart';

/// CSS-topology submap membership for WebView-based OCR.
///
/// Partitioning rules (applied symmetrically to drift *observation* and
/// drift *correction* — a tier that never contributes observations also
/// never receives corrections, #48):
/// - VR blocks (weight 40): `SpaceKey.unknown()` — viewport-fixed, page
///   scroll drift does not apply
/// - Nested IC+carousel (weight 30): `SpaceKey.unknown()` — compound
///   coordinate space
/// - Carousel-only (weight 20 + isHorizontalScrollChild): excluded from
///   observation but lives in normal vertical scroll space, so it maps to
///   `SpaceKey.normal(regionIndex)` and receives normal-space corrections
/// - IC with containerId: `SpaceKey.ic(containerId, regionIndex)`
/// - IC without containerId: `SpaceKey.unknown()` (indeterminate)
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
    // VR (40) and nested IC+carousel (30): these tiers are excluded from
    // drift observation, and before 0.6.0 they still fell through to
    // SpaceKey.normal — so a position:fixed header could *receive* the
    // page-scroll submap's median correction it never contributed to.
    // Mapping them to unknown() makes observation and correction
    // symmetric: medianDriftForKey(unknown) has no observations and
    // returns Offset.zero (#48).
    if (block.hierarchyWeight >= HierarchyTiers.nested) {
      return SpaceKey.unknown();
    }
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
