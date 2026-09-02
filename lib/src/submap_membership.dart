// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'tracked_block.dart';
import 'types/space_key.dart';

/// Strategy for determining which coordinate submap a block belongs to.
///
/// The SLAM engine partitions drift observations into independent submaps
/// so blocks in different coordinate spaces don't contaminate each other's
/// drift corrections. This interface allows platform-specific implementations
/// to define submap partitioning.
///
/// The default implementation ([CssSubmapMembership]) uses CSS topology:
/// viewport-relative blocks are excluded from drift, inner-scroller blocks
/// get container-specific submaps, and normal blocks use page-scroll regions.
///
/// Alternative implementations might use:
/// - PDF page numbers as submaps
/// - Camera frame regions
/// - Game world zones
abstract interface class SubmapMembership {
  /// Compute the coordinate-space key for a block.
  ///
  /// Returns the [SpaceKey] that determines which drift submap this block's
  /// observations are recorded in. Blocks with the same key share drift
  /// corrections; blocks with different keys are independent.
  SpaceKey spaceKeyFor(TrackedBlock block);

  /// Whether this block should be excluded from drift observation recording.
  ///
  /// Excluded blocks still receive drift corrections (via their space key's
  /// median) but don't contribute observations. Use this for blocks whose
  /// position changes aren't caused by scroll drift (e.g. viewport-fixed
  /// elements, animating carousels).
  bool shouldExcludeFromObservation(TrackedBlock block);

  /// Size of each scroll region in layout pixels.
  ///
  /// Used by [DriftTracker.clearSpatialRegion] to map vertical spans to
  /// region indices. Implementations should return the same value used
  /// in [spaceKeyFor] for region index computation.
  int get regionSize;
}
