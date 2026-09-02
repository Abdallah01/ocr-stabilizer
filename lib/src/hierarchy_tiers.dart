// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

/// Named constants for hierarchy weight tiers.
///
/// Used by [HierarchyWeightX] and [DriftTracker] to classify blocks
/// by coordinate-space constraints. Higher weight = more constrained.
abstract final class HierarchyTiers {
  /// Viewport-relative (fixed/sticky) — no scroll drift.
  static const int viewport = 40;

  /// Nested inner-scroller + carousel — compound coordinate space.
  static const int nested = 30;

  /// Inner-scroller or carousel — single-axis constraint.
  static const int constrained = 20;

  /// Normal page scroll — unrestricted.
  static const int normal = 10;
}
