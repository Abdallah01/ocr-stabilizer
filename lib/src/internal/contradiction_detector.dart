// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// Contradiction detection (#49), extracted from `StabilizationEngine` in
// #150 with no behaviour change. The engine keeps the two public entry
// points (`detectGroupingContradictions`, `detectSplittingContradictions`)
// and delegates here.

import '../observation.dart';
import '../spatial_block_index.dart';
import '../stabilization_result.dart';
import '../text_dedup_utils.dart';
import '../track.dart';

/// Detects grouping and splitting contradictions between a capture's
/// fresh blocks and the well-observed cached blocks in [index].
/// Detection only: the consumer decides whether to evict.
class ContradictionDetector<T extends Track<Object?>> {
  /// Creates a detector over the engine's spatial index.
  const ContradictionDetector({required this.index});

  /// The engine's spatial index (the cached blocks).
  final SpatialIndexView<T> index;

  /// Minimum observation count for a cached block to be considered
  /// well-observed (eligible for contradiction detection).
  static const int _kMinObsForContradiction = 3;

  /// Grouping contradictions: ≥2 fresh blocks spatially subdivide a
  /// well-observed cached block. [freshIndex] is the batch grid over
  /// [freshBlocks] (the engine's dedup pipeline already built it, #55).
  ///
  /// Thresholds: height ratio < 0.70, overlap ratio ≥ 0.30, text
  /// similarity ≥ 0.60 (Levenshtein on space-joined subdivider texts).
  List<ContradictionEvent<T>> grouping(
    List<T> freshBlocks,
    SpatialIndexView<T> freshIndex,
  ) {
    if (freshBlocks.length < 2) return const [];

    final events = <ContradictionEvent<T>>[];

    // Scan all cached blocks via the engine's spatial index
    for (final cached in index.allBlocks) {
      if (cached.observationCount < _kMinObsForContradiction) continue;

      // VR blocks live in a different coordinate contract (viewport-
      // relative, not page-absolute) and blocksInRegion never returns VR
      // fresh blocks — so any "subdividers" found for a VR cached block
      // are numeric coincidences (e.g. near scroll offset 0, where the
      // two spaces coincide), not evidence. Same guard the matching path
      // and OverlapResolver.checkOverlap already apply (#49).
      if (cached.isViewportRelative) continue;

      final cRect = cached.absoluteRect.raw;
      if (cRect.width <= 0 || cRect.height <= 0) continue;

      // O(cells) spatial query against fresh index
      final nearby = freshIndex.blocksInRegion(cRect);

      // Height pre-filter: only blocks shorter than 70% of cached (subdivisions)
      // and overlap ≥30%.
      final cArea = cRect.width * cRect.height;
      final subdividers = <T>[];
      for (final fresh in nearby) {
        final fRect = fresh.absoluteRect.raw;
        if (fRect.height >= cRect.height * 0.7) continue;
        final intersection = cRect.intersect(fRect);
        if (intersection.isEmpty) continue;
        if ((intersection.width * intersection.height) / cArea < 0.3) continue;
        subdividers.add(fresh);
      }
      if (subdividers.length < 2) continue;

      // Sort by reading order before text comparison
      subdividers.sort(
        (a, b) => a.absoluteRect.raw.top.compareTo(b.absoluteRect.raw.top),
      );
      final sortedText = subdividers.map((b) => b.originalText).join(' ');

      final textSim = TextDedupUtils.normalizedLevenshtein(
        cached.originalText,
        sortedText,
      );
      if (textSim < 0.60) continue;

      events.add(
        ContradictionEvent<T>(
          type: ContradictionType.grouping,
          target: cached,
          evidence: subdividers,
        ),
      );
    }
    return events;
  }

  /// Splitting contradictions: a single fresh block subsumes ≥2
  /// well-observed cached blocks.
  ///
  /// Thresholds: height ratio < 0.70, containment ≥ 0.80, text
  /// similarity ≥ 0.60 (Levenshtein on space-joined subsumed texts).
  List<ContradictionEvent<T>> splitting(List<T> freshBlocks) {
    if (freshBlocks.isEmpty) return const [];

    final events = <ContradictionEvent<T>>[];
    final alreadyTargeted = <T>{};

    for (final fresh in freshBlocks) {
      // VR fresh blocks carry viewport-relative coordinates; the cached
      // blocks returned by blocksInRegion are page-absolute (VR cached
      // blocks live in a separate cell namespace and are never returned).
      // Comparing across the two contracts can only produce false
      // "subsumed" evidence near scroll offset 0 (#49).
      if (fresh.isViewportRelative) continue;

      final fRect = fresh.absoluteRect.raw;
      if (fRect.width <= 0 || fRect.height <= 0) continue;

      // O(cells) query against existing cached spatial index
      final nearby = index.blocksInRegion(fRect);

      final subsumed = <T>[];
      for (final cached in nearby) {
        if (cached.observationCount < _kMinObsForContradiction) continue;
        if (alreadyTargeted.contains(cached)) continue;

        final cRect = cached.absoluteRect.raw;
        if (cRect.height >= fRect.height * 0.7) continue;
        final cArea = cRect.width * cRect.height;
        if (cArea <= 0) continue;

        final intersection = fRect.intersect(cRect);
        if (intersection.isEmpty) continue;

        final containment = (intersection.width * intersection.height) / cArea;
        if (containment >= 0.80) {
          subsumed.add(cached);
        }
      }
      if (subsumed.length < 2) continue;

      // Sort by reading order before text comparison
      subsumed.sort(
        (a, b) => a.absoluteRect.raw.top.compareTo(b.absoluteRect.raw.top),
      );
      final sortedText = subsumed.map((b) => b.originalText).join(' ');

      final textSim = TextDedupUtils.normalizedLevenshtein(
        fresh.originalText,
        sortedText,
      );
      if (textSim < 0.60) continue;

      alreadyTargeted.addAll(subsumed);
      events.add(
        ContradictionEvent<T>(
          type: ContradictionType.splitting,
          target: fresh,
          evidence: subsumed,
        ),
      );
    }
    return events;
  }
}
