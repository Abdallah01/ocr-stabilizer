// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// The batch dedup pipeline (noise filter, key dedup, intra-batch NMS),
// extracted from `StabilizationEngine._dedup` in #150 with no behaviour
// change. Also yields the per-batch spatial grid the grouping
// contradiction detector reuses (#55).

import '../block_key.dart';
import '../drift_tracker.dart';
import '../overlap_resolver.dart';
import '../spatial_block_index.dart';
import '../track.dart';

/// The kept blocks of one capture, in input order after NMS, and the
/// batch grid mirroring them.
typedef BatchDedupResult<T extends Track<Object?>> = ({
  List<T> blocks,
  SpatialBlockIndex<T> batchIndex
});

/// Filters noise and removes intra-batch duplicates from one capture.
///
/// Pipeline:
/// 1. Noise filter — skip empty/whitespace-only text
/// 2. Key-based intra-batch dedup — same OCR frame producing identical
///    position+text twice
/// 3. Spatial overlap NMS — when two batch blocks overlap, higher quality
///    or higher hierarchy weight wins
class BatchDedup<T extends Track<Object?>> {
  /// Creates the pipeline over the engine's main [index] (whose bucket
  /// sizes the batch grid adopts), [resolver] and [driftTracker].
  const BatchDedup({
    required this.index,
    required this.resolver,
    required this.driftTracker,
  });

  /// The engine's main spatial index — read only for its bucket sizes.
  final SpatialBlockIndex<T> index;

  /// The engine's overlap resolver.
  final OverlapResolver resolver;

  /// The engine's drift tracker (drift margins for the NMS).
  final DriftTracker driftTracker;

  /// Run the pipeline. [bucketWidth], [bucketHeight] and [scale] are the
  /// engine's CURRENT key-quantisation parameters (they change with the
  /// viewport), so they are passed per call rather than captured.
  BatchDedupResult<T> run(
    List<T> blocks, {
    required double bucketWidth,
    required double bucketHeight,
    required double scale,
  }) {
    final out = <T>[];
    final seenKeys = <String>{};
    // Key each *kept* block was registered under, so an evicted block's
    // key can be retired with it. Identity-keyed: consumer blocks may
    // implement value equality (#50).
    final keptKeys = Map<T, String>.identity();
    // Per-batch spatial grid mirroring `out` (#55): overlap lookup was a
    // linear scan of the whole output per fresh block — O(n²) with a
    // drift-margin computation per pair. The grid makes it O(cells).
    // Bucket sizes adopt the main index's so quantization stays uniform.
    // Note the grid's 3×3-neighborhood semantics: a pair whose centers
    // sit more than one cell apart is not considered overlapping — the
    // same locality contract the inter-capture matching path already
    // uses via [SpatialBlockIndex.candidates].
    final batchIndex = SpatialBlockIndex<T>()..adoptBucketSizes(index);

    for (final b in blocks) {
      // 1. Noise filter: skip blocks with empty/whitespace-only text
      if (b.originalText.trim().isEmpty) continue;

      // 2. Key-based intra-batch dedup
      final key = BlockKeyGenerator.keyFor(
        b,
        bucketWidth: bucketWidth,
        bucketHeight: bucketHeight,
        scale: scale,
      );
      if (seenKeys.contains(key)) continue;

      // Also check ±1 neighbor buckets for boundary-straddling duplicates
      final neighbors = BlockKeyGenerator.neighborKeys(
        b,
        bucketWidth: bucketWidth,
        bucketHeight: bucketHeight,
        scale: scale,
      );
      if (neighbors.any(seenKeys.contains)) continue;

      // 3. Spatial overlap NMS within the batch. Keys are registered
      // only for blocks that survive NMS — a dropped block's key must
      // not suppress later same-bucket blocks, and an evicted block's
      // key retires with it (#50).
      final overlapping = _findBatchOverlap(b, batchIndex);
      if (overlapping != null) {
        final result = resolver.resolveOverlap(
          incoming: b,
          existing: overlapping,
          driftMargin: driftTracker.driftMarginForKey(
            driftTracker.spaceKeyFor(b),
          ),
          confidenceMad: 0.1,
        );
        switch (result) {
          case OverlapResult.evict:
            // Identity-based lookup: indexOf uses ==, which for
            // value-equal consumer blocks can hit a different element
            // than the one NMS resolved against (#50).
            final idx = _identityIndexOf(out, overlapping);
            out[idx] = b;
            batchIndex.remove(overlapping);
            batchIndex.add(b);
            final evictedKey = keptKeys.remove(overlapping);
            if (evictedKey != null) seenKeys.remove(evictedKey);
            seenKeys.add(key);
            keptKeys[b] = key;
          case OverlapResult.keep:
            out.add(b);
            batchIndex.add(b);
            seenKeys.add(key);
            keptKeys[b] = key;
          case OverlapResult.drop:
            // Discard incoming — key intentionally not registered.
            break;
        }
      } else {
        out.add(b);
        batchIndex.add(b);
        seenKeys.add(key);
        keptKeys[b] = key;
      }
    }
    return (blocks: out, batchIndex: batchIndex);
  }

  /// Index of [target] in [list] by object identity (never `==`).
  static int _identityIndexOf<E>(List<E> list, E target) {
    for (var i = 0; i < list.length; i++) {
      if (identical(list[i], target)) return i;
    }
    throw StateError(
      'NMS invariant: resolved overlap target not found in batch output — '
      'the existing block returned by _findBatchOverlap must be present '
      'in `out` by identity.',
    );
  }

  /// Find an overlapping block among [batchIndex]'s grid-neighborhood
  /// candidates for [block] (#55 — replaces the O(n²) full-batch scan).
  T? _findBatchOverlap(T block, SpatialBlockIndex<T> batchIndex) {
    final threshold = resolver.overlapThresholdFor(block);
    final dm = driftTracker.driftMarginForKey(driftTracker.spaceKeyFor(block));
    for (final existing in batchIndex.candidates(block)) {
      final match = resolver.checkOverlap(
        block,
        block.absoluteRect,
        existing,
        threshold,
        dm,
      );
      if (match != null) return match;
    }
    return null;
  }
}
