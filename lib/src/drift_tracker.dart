// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// ============================================================================
// DRIFT TRACKER
// ============================================================================
// Extracted from a coordinate-space-aware overlay cache layer. Implements the
// coordinate-space-aware submap model from SLAM adaptation plan §2.1:
// tracks scroll-region-keyed drift observations (normal vs inner-scroller
// coordinate spaces) for OCR position correction.
// ============================================================================

import 'dart:collection' show Queue;

import 'package:meta/meta.dart' show visibleForTesting;

import 'css_submap_membership.dart';
import 'internal/debug.dart';
import 'robust_stats.dart';
import 'submap_membership.dart';
import 'tracked_block.dart';
import 'types/geometry.dart' show Offset, Rect;
import 'types/space_key.dart';

/// Tracks per-region OCR drift observations to compensate for systematic
/// position error introduced by the capture/recognition pipeline.
///
/// Observations are bucketed by [SpaceKey] (coordinate space + scroll region)
/// using a pluggable [SubmapMembership] strategy. Each bucket keeps a rolling
/// window of recent drifts; queries return the median, clamped to the median
/// block height for the region (boundedness invariant).
class DriftTracker {
  /// Drift observations keyed by [SpaceKey]. FIFO ring buffer per key,
  /// bounded by [_maxPerRegion].
  final Map<SpaceKey, Queue<Offset>> _regionDrifts = {};

  /// Block heights keyed by [SpaceKey] (same rolling window as drifts).
  final Map<SpaceKey, Queue<double>> _regionBlockHeights = {};

  /// Strategy for determining submap membership (default: CSS topology).
  final SubmapMembership submapMembership;

  /// Layout pixels per scroll region, from [submapMembership].
  int get regionSize => submapMembership.regionSize;

  /// Injectable sink for debug diagnostics.
  ///
  /// Pure-Dart replacement for Flutter's `debugPrint`. Two severities (#78):
  /// CHATTY lines (RECORDED, membership skips, clearKey no-ops) fire only in
  /// debug builds ([kDebugMode]) — they are tree-shaken out of profile and
  /// release. ANOMALY-class lines (non-finite drift/top skips) are delivered
  /// UNgated in every build mode: those inputs are dropped before `dump()` or
  /// the observation log see them, so a wired logger is the only trace.
  /// Defaults to null, which silences all diagnostic output. Pass `print` —
  /// or a logging framework hook — to restore visible output.
  final void Function(String message)? debugLogger;

  /// Create a new drift tracker with optional custom submap membership
  /// strategy and debug logger.
  DriftTracker({SubmapMembership? submapMembership, this.debugLogger})
      : submapMembership = submapMembership ?? const CssSubmapMembership();

  /// Maximum observations per region (rolling window).
  static const int _maxPerRegion = 20;

  /// Ring buffer of recent observations for debug export. Max 500 total.
  final Queue<_DriftLogEntry> _observationLog = Queue<_DriftLogEntry>();

  /// Ring buffer cap.
  static const int _logCapacity = 500;

  /// Per-key propagation count (number of times `_propagateRegionalDrift`
  /// has fired for this space key). Populated by an external call from
  /// the overlay cache layer via [recordPropagation] — not by the tracker
  /// itself.
  final Map<SpaceKey, int> _propagationCounts = {};

  /// All space keys that have recorded observations.
  Iterable<SpaceKey> get observedKeys => _regionDrifts.keys;

  /// Compute the coordinate-space key for a block.
  ///
  /// Delegates to the [submapMembership] strategy. See [CssSubmapMembership]
  /// for the default WebView implementation.
  SpaceKey spaceKeyFor(TrackedBlock block) =>
      submapMembership.spaceKeyFor(block);

  /// Record a drift observation for a block.
  ///
  /// Delegates exclusion logic to [submapMembership]. Also skips blocks with
  /// non-finite drift values or block positions. Observations are bucketed by
  /// [spaceKeyFor] and kept in a rolling window of [_maxPerRegion] per key.
  ///
  /// Default exclusion rules (via [CssSubmapMembership]):
  /// - VR blocks: viewport-fixed, no scroll drift
  /// - Nested IC+carousel: compound coordinate space
  /// - Carousel-only: horizontal motion confounds vertical-drift signal
  /// - IC without containerId: indeterminate coordinate space
  void addObservation(TrackedBlock block, Offset drift, {double? blockHeight}) {
    // Check exclusion rules from membership strategy
    if (submapMembership.shouldExcludeFromObservation(block)) {
      if (kDebugMode) {
        debugLogger?.call('[DRIFT] skip: excluded by submap membership');
      }
      return;
    }

    // Anomaly-class (#78): delivered UNgated — a non-finite input is dropped
    // before dump()/the observation log ever see it, so a wired logger is the
    // only trace in profile/release builds.
    if (!drift.dx.isFinite || !drift.dy.isFinite) {
      debugLogger?.call('[DRIFT] skip non-finite drift');
      return;
    }

    // Guard against NaN/infinity in block position — anomaly-class (#78).
    if (!block.absoluteRect.top.isFinite) {
      debugLogger?.call('[DRIFT] skip non-finite top');
      return;
    }

    blockHeight ??= block.absoluteRect.height;
    if (!blockHeight.isFinite || blockHeight <= 0) blockHeight = 16.0;

    final spaceKey = spaceKeyFor(block);
    _invalidateMedianCaches(spaceKey);
    if (kDebugMode) {
      debugLogger?.call(
        '[DRIFT] RECORDED key=$spaceKey drift=(${drift.dx.toStringAsFixed(1)},${drift.dy.toStringAsFixed(1)}) total=${(_regionDrifts[spaceKey]?.length ?? 0) + 1}',
      );
    }
    final list = _regionDrifts.putIfAbsent(spaceKey, () => Queue<Offset>());
    list.addLast(drift);
    if (list.length > _maxPerRegion) list.removeFirst();

    final heightList =
        _regionBlockHeights.putIfAbsent(spaceKey, () => Queue<double>());
    heightList.addLast(blockHeight);
    if (heightList.length > _maxPerRegion) heightList.removeFirst();

    // Append to observation log (ring buffer)
    _observationLog.addLast(
      _DriftLogEntry(DateTime.now(), spaceKey, drift, blockHeight),
    );
    // Evict oldest if over capacity (FIFO)
    if (_observationLog.length > _logCapacity) {
      _observationLog.removeFirst();
    }
  }

  /// Observation count for a specific space key.
  int observationCountForKey(SpaceKey spaceKey) {
    return _regionDrifts[spaceKey]?.length ?? 0;
  }

  /// All space keys with recorded observations.
  ///
  /// Identical to [observedKeys]; this older alias is kept for source
  /// compatibility and will be removed in 1.0 (#53).
  @Deprecated('Use observedKeys instead — identical value, one name')
  Iterable<SpaceKey> get spaceKeys => _regionDrifts.keys;

  /// Debug helper: total observation count across all space keys. For testing only.
  /// Delegates to [totalObservations] so the two views cannot drift apart.
  @visibleForTesting
  int get debugTotalObservationCount => totalObservations;

  /// Median drift for a space key, computed separately for X and Y axes.
  ///
  /// Three guards in sequence:
  /// 1. Small-sample: < 3 observations → [Offset.zero] (not enough for median)
  /// 2. Median: [RobustStats.median] for proper even-length handling
  /// 3. Boundedness: clamped to ±[medianBlockHeightForKey]
  ///
  /// Per-key median caches (#55). The medians are queried several times
  /// per block per capture (dedup margin, NMS, band spatial confirm,
  /// merge correction) but only change when an observation lands in the
  /// key's window — so each cache entry is computed once per
  /// (key, window-state) instead of sort-per-call. Invalidated per key
  /// by [addObservation] and by every clearing path.
  final Map<SpaceKey, Offset> _medianDriftCache = {};
  final Map<SpaceKey, double> _medianHeightCache = {};

  /// Drop cached medians for [spaceKey] (its window changed).
  void _invalidateMedianCaches(SpaceKey spaceKey) {
    _medianDriftCache.remove(spaceKey);
    _medianHeightCache.remove(spaceKey);
  }

  /// The returned value is always safe to apply directly as a correction.
  Offset medianDriftForKey(SpaceKey spaceKey) {
    return _medianDriftCache.putIfAbsent(spaceKey, () {
      final drifts = _regionDrifts[spaceKey];
      if (drifts == null || drifts.length < 3) return Offset.zero;

      final medianDx =
          RobustStats.median(drifts.map((d) => d.dx).toList()) ?? 0.0;
      final medianDy =
          RobustStats.median(drifts.map((d) => d.dy).toList()) ?? 0.0;

      final maxMargin = medianBlockHeightForKey(spaceKey);
      return Offset(
        medianDx.clamp(-maxMargin, maxMargin).toDouble(),
        medianDy.clamp(-maxMargin, maxMargin).toDouble(),
      );
    });
  }

  /// Median block height for a space key.
  ///
  /// Returns 16.0 if no observations for the key.
  double medianBlockHeightForKey(SpaceKey spaceKey) {
    return _medianHeightCache.putIfAbsent(spaceKey, () {
      final heights = _regionBlockHeights[spaceKey];
      if (heights == null || heights.isEmpty) return 16.0;

      return RobustStats.median(heights.toList()) ?? 16.0;
    });
  }

  /// Adaptive overlap detection threshold for a space key.
  ///
  /// Sums the absolute median drift on each axis and clamps to the median
  /// block height — the boundedness invariant. Ensures correction can never
  /// shift a block farther than the height of typical text in that region.
  double driftMarginForKey(SpaceKey spaceKey) {
    final median = medianDriftForKey(spaceKey);
    final margin = median.dy.abs() + median.dx.abs();
    return margin.clamp(0.0, medianBlockHeightForKey(spaceKey)).toDouble();
  }

  /// Remove a specific space key's observations and propagation count.
  ///
  /// Returns true if the key existed and was removed, false if it was a no-op.
  bool clearKey(SpaceKey spaceKey) {
    final hadDrifts = _regionDrifts.remove(spaceKey) != null;
    final hadHeights = _regionBlockHeights.remove(spaceKey) != null;
    _propagationCounts.remove(spaceKey);
    _invalidateMedianCaches(spaceKey);
    if (kDebugMode && !hadDrifts && !hadHeights) {
      debugLogger?.call('[DRIFT] clearKey no-op: "$spaceKey" not found');
    }
    return hadDrifts || hadHeights;
  }

  /// Clear drift observations for all space keys whose region index
  /// intersects the given vertical span [topY, bottomY] in CSS pixels.
  ///
  /// Both normal and IC submaps are cleared for intersecting regions.
  /// Use this when DOM mutation invalidates a vertical range of page content —
  /// stale drift corrections in that range would otherwise mis-position
  /// fresh observations after layout change.
  void clearSpatialRegion(double topY, double bottomY) {
    if (!topY.isFinite || !bottomY.isFinite) return;
    if (bottomY <= topY) return;
    final firstRegion = (topY / regionSize).floor();
    final lastRegion = (bottomY / regionSize).floor();
    _regionDrifts.removeWhere((key, _) {
      final region = key.regionIndex;
      return region >= firstRegion && region <= lastRegion;
    });
    _regionBlockHeights.removeWhere((key, _) {
      final region = key.regionIndex;
      return region >= firstRegion && region <= lastRegion;
    });
    _propagationCounts.removeWhere((key, _) {
      final region = key.regionIndex;
      return region >= firstRegion && region <= lastRegion;
    });
    _medianDriftCache.removeWhere((key, _) {
      final region = key.regionIndex;
      return region >= firstRegion && region <= lastRegion;
    });
    _medianHeightCache.removeWhere((key, _) {
      final region = key.regionIndex;
      return region >= firstRegion && region <= lastRegion;
    });
  }

  /// Apply drift correction to a fresh observation's rect.
  ///
  /// Translates [freshRect] by the negative of [regionDrift] to compensate
  /// for systematic OCR positioning error in a scroll region.
  static Rect applyCorrectedPosition(Rect freshRect, Offset regionDrift) {
    return freshRect.translate(-regionDrift.dx, -regionDrift.dy);
  }

  /// Format all drift data as a human-readable string for export.
  String dump() {
    if (_regionDrifts.isEmpty) return 'No drift observations recorded.\n';
    final buffer = StringBuffer();
    buffer.writeln('=== Drift Tracker Dump ===');
    buffer.writeln('Region size: ${regionSize}px');
    buffer.writeln('');
    final sortedKeys = _regionDrifts.keys.toList()..sort();
    for (final spaceKey in sortedKeys) {
      final drifts = _regionDrifts[spaceKey]!;
      if (drifts.isEmpty) continue;
      final xs = drifts.map((d) => d.dx).toList()..sort();
      final ys = drifts.map((d) => d.dy).toList()..sort();
      final medX = RobustStats.medianOfSorted(xs) ?? 0.0;
      final medY = RobustStats.medianOfSorted(ys) ?? 0.0;
      buffer.writeln(
        'space=$spaceKey '
        'n=${drifts.length} '
        'medX=${medX.toStringAsFixed(1)} '
        'medY=${medY.toStringAsFixed(1)}',
      );
    }
    return buffer.toString();
  }

  /// Total observation count across all space keys.
  int get totalObservations =>
      _regionDrifts.values.fold(0, (sum, list) => sum + list.length);

  /// Clear all recorded observations, heights, log entries, and propagation counts.
  void clear() {
    _regionDrifts.clear();
    _regionBlockHeights.clear();
    _observationLog.clear();
    _propagationCounts.clear();
    _medianDriftCache.clear();
    _medianHeightCache.clear();
  }

  /// Number of drift propagations recorded for [spaceKey] via
  /// [recordPropagation]. 0 for keys never recorded (or cleared by
  /// [clearKey] / [clearSpatialRegion] / [clear]).
  int propagationCountFor(SpaceKey spaceKey) =>
      _propagationCounts[spaceKey] ?? 0;

  /// Record that a regional drift propagation occurred for this space key.
  /// Called by the overlay cache layer after each regional drift propagation.
  void recordPropagation(SpaceKey spaceKey) {
    _propagationCounts[spaceKey] = (_propagationCounts[spaceKey] ?? 0) + 1;
  }

  /// Serialize the drift log as human-readable text for debugging.
  /// Includes per-space-key summary (obs count, median dx/dy, max margin,
  /// propagation count) followed by the raw observation log.
  String exportDebugLog({DateTime? now}) {
    final buffer = StringBuffer();
    buffer.writeln('=== Drift Tracker Debug Log ===');
    final timestamp = now ?? DateTime.now();
    buffer.writeln('Generated at: ${timestamp.toIso8601String()}');
    buffer.writeln('Region size: $regionSize CSS px');
    buffer.writeln(
      'Log capacity: $_logCapacity (current: ${_observationLog.length})',
    );
    buffer.writeln('');
    buffer.writeln('--- Per-space-key summary ---');
    final sortedKeys = _regionDrifts.keys.toList()..sort();
    for (final spaceKey in sortedKeys) {
      final n = _regionDrifts[spaceKey]?.length ?? 0;
      final median = medianDriftForKey(spaceKey);
      final margin = driftMarginForKey(spaceKey);
      final propCount = _propagationCounts[spaceKey] ?? 0;
      buffer.writeln(
        'space=$spaceKey n=$n '
        'medX=${median.dx.toStringAsFixed(2)} '
        'medY=${median.dy.toStringAsFixed(2)} '
        'maxMargin=${margin.toStringAsFixed(2)} '
        'propagations=$propCount',
      );
    }
    buffer.writeln('');
    buffer.writeln(
      '--- Raw observation log (${_observationLog.length} entries) ---',
    );
    for (final e in _observationLog) {
      buffer.writeln(
        '${e.timestamp.toIso8601String()} '
        'key=${e.spaceKey} '
        'dx=${e.drift.dx.toStringAsFixed(2)} '
        'dy=${e.drift.dy.toStringAsFixed(2)} '
        'h=${e.blockHeight.toStringAsFixed(1)}',
      );
    }
    return buffer.toString();
  }
}

/// Private log entry class for drift observation recording.
class _DriftLogEntry {
  final DateTime timestamp;
  final SpaceKey spaceKey;
  final Offset drift;
  final double blockHeight;

  _DriftLogEntry(this.timestamp, this.spaceKey, this.drift, this.blockHeight);
}
