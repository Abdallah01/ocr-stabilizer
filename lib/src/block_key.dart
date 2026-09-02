// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'text_dedup_utils.dart';
import 'tracked_block.dart';

/// Generates dedup keys from block position, text, and classification.
///
/// Keys encode coordinate space prefix + quantized position + scale band +
/// text hash + text head. VR blocks use text-only keys (no position).
class BlockKeyGenerator {
  BlockKeyGenerator._();

  /// Default bucket size (CSS px) before any viewport-adaptive update.
  static const double kDefaultBucketSize = 200.0;

  /// Build a dedup key for [block].
  ///
  /// [bucketWidth] and [bucketHeight] control position quantization.
  /// [scale] is the current visual viewport scale (quantized to tenths).
  static String keyFor(
    TrackedBlock block, {
    double bucketWidth = kDefaultBucketSize,
    double bucketHeight = kDefaultBucketSize,
    double scale = 1.0,
  }) {
    if (block.isViewportRelative) {
      return _vrKey(block);
    }
    final prefix = _prefixFor(block);
    return _positionKey(block, prefix, bucketWidth, bucketHeight, scale);
  }

  /// Build a dedup key with an explicit [prefix] override.
  ///
  /// Used by cross-prefix cold-tier lookup to find blocks cached under a
  /// stale classification prefix.
  static String keyWithPrefix(
    TrackedBlock block,
    String prefix, {
    double bucketWidth = kDefaultBucketSize,
    double bucketHeight = kDefaultBucketSize,
    double scale = 1.0,
  }) {
    if (block.isViewportRelative) {
      return _vrKey(block);
    }
    return _positionKey(block, prefix, bucketWidth, bucketHeight, scale);
  }

  /// Compute the classification-derived prefix for [block].
  static String prefixFor(TrackedBlock block) => _prefixFor(block);

  // ── Private ────────────────────────────────────────────────────────

  static String _prefixFor(TrackedBlock block) {
    final icPrefix = block.isInnerScrollerChild ? 'ic:' : '';
    final hzPrefix = block.isHorizontalScrollChild
        ? 'hz${block.scrollContext.hzScrollerIndex}:'
        : '';
    return '$icPrefix$hzPrefix';
  }

  static String _vrKey(TrackedBlock block) {
    final cjk = TextDedupUtils.cjkOnly(block.originalText);
    if (cjk.length >= 3) {
      return 'vr:${TextDedupUtils.shortHead(cjk, 20)}';
    }
    final head = TextDedupUtils.shortHead(
      TextDedupUtils.normalizeWhitespace(block.originalText),
      30,
    );
    return 'vr:$head';
  }

  static String _positionKey(
    TrackedBlock block,
    String prefix,
    double bucketWidth,
    double bucketHeight,
    double scale,
  ) {
    final r = block.absoluteRect;
    final kLeft = (r.left / bucketWidth).round();
    // IC blocks: use scroller-relative Y to eliminate vvPageTop drift.
    final dedupTop =
        block.isInnerScrollerChild ? (r.top - block.innerScrollerTop) : r.top;
    final kTop = (dedupTop / bucketHeight).round();
    final normalizedText = TextDedupUtils.normalizeWhitespace(
      block.originalText,
    );
    final head = TextDedupUtils.shortHead(normalizedText, 30);
    final hash = _textHash(normalizedText);
    final scaleBand = (scale * 10).round();
    return '$prefix$kLeft:$kTop:s$scaleBand:$hash:$head';
  }

  /// Generate ±1 neighbor keys for fuzzy dedup matching.
  ///
  /// Returns up to 8 keys (3x3 grid minus the center). VR blocks have
  /// text-only keys with no position component, so no neighbors are generated.
  static List<String> neighborKeys(
    TrackedBlock block, {
    double bucketWidth = kDefaultBucketSize,
    double bucketHeight = kDefaultBucketSize,
    double scale = 1.0,
  }) {
    if (block.isViewportRelative) return const [];

    final r = block.absoluteRect;
    final kLeft = (r.left / bucketWidth).round();
    final dedupTop =
        block.isInnerScrollerChild ? (r.top - block.innerScrollerTop) : r.top;
    final kTop = (dedupTop / bucketHeight).round();
    final prefix = _prefixFor(block);
    final normalizedText = TextDedupUtils.normalizeWhitespace(
      block.originalText,
    );
    final head = TextDedupUtils.shortHead(normalizedText, 30);
    final hash = _textHash(normalizedText);
    final scaleBand = (scale * 10).round();

    final keys = <String>[];
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        if (dx == 0 && dy == 0) continue;
        keys.add('$prefix${kLeft + dx}:${kTop + dy}:s$scaleBand:$hash:$head');
      }
    }
    return keys;
  }

  /// Base-36 rendering of [String.hashCode].
  ///
  /// **In-memory only:** [String.hashCode] is not stable across Dart
  /// runtimes (VM vs web) or necessarily across VM versions, so generated
  /// keys must never be persisted or compared across processes (#53).
  static String _textHash(String text) {
    return text.hashCode.toRadixString(36);
  }
}
