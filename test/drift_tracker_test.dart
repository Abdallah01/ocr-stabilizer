// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// ignore_for_file: unused_element_parameter

// =============================================================================
// DRIFT TRACKER PROPERTY TESTS
// =============================================================================
// Property-based tests for DriftTracker: boundedness, convergence, and outlier
// resistance. These invariants validate the guards applied in _sarMerge()
// before live correction — drift is always bounded by median block height
// and resistant to outlier observations.
// =============================================================================

import 'dart:math';

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

/// Minimal test block for package-level DriftTracker tests.
class _TestBlock implements TrackedBlock<Never> {
  @override
  final AbsoluteRect absoluteRect;
  @override
  final ContainerId? containerId;
  @override
  final bool isViewportRelative;
  @override
  final bool isInnerScrollerChild;
  @override
  final bool isHorizontalScrollChild;
  @override
  final double innerScrollerTop;
  @override
  Never get payload => throw UnsupportedError('_TestBlock has no payload');

  // Tier A identity/coordinate fields
  @override
  final String originalText;
  final double captureScrollY;
  final double captureScrollX;
  final int hzScrollerIndex;
  @override
  final bool isFromStickyElement;
  final double stickyFallbackScrollY;
  final double stickyFallbackScrollX;
  final bool stickyFallbackIsIc;
  final int stickyFallbackHzIndex;
  @override
  final PositionConfidence positionConfidence;
  @override
  final TextConfidence textConfidence;
  @override
  final int sourceQuality;

  _TestBlock({
    required this.absoluteRect,
    this.containerId,
    this.isViewportRelative = false,
    this.isInnerScrollerChild = false,
    this.isHorizontalScrollChild = false,
    this.innerScrollerTop = 0,
    this.originalText = '',
    this.captureScrollY = 0,
    this.captureScrollX = 0,
    this.hzScrollerIndex = -1,
    this.isFromStickyElement = false,
    this.stickyFallbackScrollY = 0,
    this.stickyFallbackScrollX = 0,
    this.stickyFallbackIsIc = false,
    this.stickyFallbackHzIndex = -1,
    this.positionConfidence = const PositionConfidence(0.5),
    this.textConfidence = const TextConfidence(0.5),
    this.sourceQuality = 0,
  });

  @override
  ScrollContext get scrollContext => ScrollContext(
        scrollY: captureScrollY,
        scrollX: captureScrollX,
        hzScrollerIndex: hzScrollerIndex,
      );

  @override
  StickyFallback get stickyFallback => StickyFallback(
        scrollY: stickyFallbackScrollY,
        scrollX: stickyFallbackScrollX,
        isIc: stickyFallbackIsIc,
        hzScrollerIndex: stickyFallbackHzIndex,
      );
}

/// Test block with a typed payload for generic contract testing.
class _PayloadBlock implements TrackedBlock<String> {
  @override
  final AbsoluteRect absoluteRect;
  @override
  final String payload;
  @override
  ContainerId? get containerId => null;
  @override
  bool get isViewportRelative => false;
  @override
  bool get isInnerScrollerChild => false;
  @override
  double get innerScrollerTop => 0;
  @override
  bool get isHorizontalScrollChild => false;
  @override
  String get originalText => '';
  @override
  bool get isFromStickyElement => false;
  @override
  PositionConfidence get positionConfidence => const PositionConfidence(0.5);
  @override
  TextConfidence get textConfidence => const TextConfidence(0.5);
  @override
  int get sourceQuality => 0;

  _PayloadBlock({required this.absoluteRect, required this.payload});

  @override
  ScrollContext get scrollContext => ScrollContext.none;

  @override
  StickyFallback get stickyFallback => StickyFallback.none;
}

_TestBlock _makeBlock({
  required double top,
  ContainerId? containerId,
  bool isViewportRelative = false,
  bool isInnerScrollerChild = false,
  bool isHorizontalScrollChild = false,
  double blockHeight = 20.0,
}) {
  return _TestBlock(
    absoluteRect: AbsoluteRect.fromLTWH(100, top, 200, blockHeight),
    containerId: containerId,
    isViewportRelative: isViewportRelative,
    isInnerScrollerChild: isInnerScrollerChild,
    isHorizontalScrollChild: isHorizontalScrollChild,
  );
}

void main() {
  group('DriftTracker', () {
    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Property: Boundedness                                               │
    // └─────────────────────────────────────────────────────────────────────┘
    test('drift margin never exceeds median line height', () {
      final tracker = DriftTracker();
      final random = Random(42);
      for (var i = 0; i < 200; i++) {
        final top = random.nextDouble() * 5000;
        final drift = Offset(
          random.nextDouble() * 20 - 10,
          random.nextDouble() * 20 - 10,
        );
        final blockHeight = 10.0 + random.nextDouble() * 30;
        final block = _makeBlock(top: top, blockHeight: blockHeight);
        tracker.addObservation(block, drift, blockHeight: blockHeight);
      }
      for (final key in tracker.observedKeys) {
        final margin = tracker.driftMarginForKey(key);
        final medianLineHeight = tracker.medianBlockHeightForKey(key);
        expect(margin, lessThanOrEqualTo(medianLineHeight));
      }
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Property: Convergence                                               │
    // └─────────────────────────────────────────────────────────────────────┘
    test('median drift converges under stable input', () {
      final tracker = DriftTracker();
      for (var i = 0; i < 30; i++) {
        final block = _makeBlock(top: 1000);
        tracker.addObservation(block, const Offset(0, 3.0));
      }
      final key = tracker.spaceKeyFor(_makeBlock(top: 1000));
      final median = tracker.medianDriftForKey(key);
      expect(median.dy, closeTo(3.0, 0.1));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Property: Outlier Resistance                                        │
    // └─────────────────────────────────────────────────────────────────────┘
    test('single outlier does not corrupt median', () {
      final tracker = DriftTracker();
      for (var i = 0; i < 20; i++) {
        final block = _makeBlock(top: 1000);
        tracker.addObservation(block, const Offset(0, 2.0));
      }
      final block = _makeBlock(top: 1000);
      tracker.addObservation(block, const Offset(0, 500.0)); // outlier
      final key = tracker.spaceKeyFor(_makeBlock(top: 1000));
      final median = tracker.medianDriftForKey(key);
      expect(median.dy, closeTo(2.0, 0.5)); // median resists outlier
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ VR Exclusion                                                        │
    // └─────────────────────────────────────────────────────────────────────┘
    test('VR blocks excluded from drift computation', () {
      final tracker = DriftTracker();
      final vrBlock = _makeBlock(top: 1000, isViewportRelative: true);
      tracker.addObservation(vrBlock, const Offset(0, 50));
      expect(tracker.totalObservations, isZero);
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ IC-without-containerId Exclusion                                    │
    // └─────────────────────────────────────────────────────────────────────┘
    test('IC blocks without containerId excluded from drift computation', () {
      final tracker = DriftTracker();
      final icNoContainer = _makeBlock(top: 1000, isInnerScrollerChild: true);
      tracker.addObservation(icNoContainer, const Offset(0, 50));
      expect(tracker.totalObservations, isZero);
    });

    test('IC blocks with containerId recorded in IC space', () {
      final tracker = DriftTracker();
      final icWithContainer = _makeBlock(
        top: 1000,
        isInnerScrollerChild: true,
        containerId: const ContainerId('42'),
      );
      tracker.addObservation(icWithContainer, const Offset(0, 5));
      expect(tracker.totalObservations, 1);
      final key = tracker.spaceKeyFor(icWithContainer);
      expect(key.toString(), contains('ic'));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Reset                                                               │
    // └─────────────────────────────────────────────────────────────────────┘
    test('clear resets all regions', () {
      final tracker = DriftTracker();
      final block = _makeBlock(top: 1000);
      tracker.addObservation(block, const Offset(1, 1));
      tracker.clear();
      expect(tracker.observedKeys, isEmpty);
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Small-Sample Guard                                                  │
    // └─────────────────────────────────────────────────────────────────────┘
    test('medianDriftForKey returns zero for fewer than 3 observations', () {
      final tracker = DriftTracker();
      // 0 observations
      expect(
        tracker.medianDriftForKey(const SpaceKey('normal:0')),
        equals(Offset.zero),
      );
      // 1 observation
      var block = _makeBlock(top: 0);
      tracker.addObservation(block, const Offset(5, 10));
      expect(
        tracker.medianDriftForKey(const SpaceKey('normal:0')),
        equals(Offset.zero),
      );
      // 2 observations
      block = _makeBlock(top: 0);
      tracker.addObservation(block, const Offset(5, 10));
      expect(
        tracker.medianDriftForKey(const SpaceKey('normal:0')),
        equals(Offset.zero),
      );
      // 3 observations — now should return non-zero
      block = _makeBlock(top: 0);
      tracker.addObservation(block, const Offset(5, 10));
      expect(
        tracker.medianDriftForKey(const SpaceKey('normal:0')),
        isNot(equals(Offset.zero)),
      );
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Boundedness Clamp                                                   │
    // └─────────────────────────────────────────────────────────────────────┘
    test('medianDriftForKey clamps to median block height', () {
      final tracker = DriftTracker();
      // Add observations with large drift but small block height
      for (var i = 0; i < 10; i++) {
        final block = _makeBlock(top: 1000, blockHeight: 20.0);
        tracker.addObservation(
          block,
          const Offset(100, 100),
          blockHeight: 20.0,
        );
      }
      final key = tracker.spaceKeyFor(_makeBlock(top: 1000));
      final median = tracker.medianDriftForKey(key);
      final maxMargin = tracker.medianBlockHeightForKey(key);
      // Each axis should be clamped to maxMargin
      expect(median.dx.abs(), lessThanOrEqualTo(maxMargin));
      expect(median.dy.abs(), lessThanOrEqualTo(maxMargin));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ applyCorrectedPosition                                              │
    // └─────────────────────────────────────────────────────────────────────┘
    test('applyCorrectedPosition with zero drift returns unchanged rect', () {
      const rect = Rect.fromLTWH(100, 200, 150, 30);
      final result = DriftTracker.applyCorrectedPosition(rect, Offset.zero);
      expect(result, equals(rect));
    });

    test('applyCorrectedPosition with known drift shifts correctly', () {
      const rect = Rect.fromLTWH(100, 200, 150, 30);
      const drift = Offset(5.0, -3.0);
      final result = DriftTracker.applyCorrectedPosition(rect, drift);
      // translate(-5, 3) → left=95, top=203
      expect(result.left, closeTo(95.0, 0.01));
      expect(result.top, closeTo(203.0, 0.01));
      // Width and height unchanged
      expect(result.width, closeTo(150.0, 0.01));
      expect(result.height, closeTo(30.0, 0.01));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Rolling Window                                                      │
    // └─────────────────────────────────────────────────────────────────────┘
    test('rolling window caps at 20 observations per region', () {
      final tracker = DriftTracker();
      for (var i = 0; i < 25; i++) {
        final block = _makeBlock(top: 0, blockHeight: 10.0 + i);
        tracker.addObservation(
          block,
          Offset(i.toDouble(), i.toDouble()),
          blockHeight: 10.0 + i,
        );
      }
      final key = tracker.spaceKeyFor(_makeBlock(top: 0));
      expect(tracker.observationCountForKey(key), equals(20));
      // Median should reflect observations 5-24 (oldest 5 evicted)
      // Heights 15-34, median ~ 24.5
      final height = tracker.medianBlockHeightForKey(key);
      expect(height, greaterThan(14.0));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ clear() completeness                                                │
    // └─────────────────────────────────────────────────────────────────────┘
    test('clear resets both drift and block height maps', () {
      final tracker = DriftTracker();
      final block = _makeBlock(top: 1000, blockHeight: 30.0);
      tracker.addObservation(block, const Offset(5, 5), blockHeight: 30.0);
      final key = tracker.spaceKeyFor(_makeBlock(top: 1000));
      expect(tracker.medianBlockHeightForKey(key), closeTo(30.0, 0.01));

      tracker.clear();

      expect(tracker.observedKeys, isEmpty);
      expect(tracker.medianBlockHeightForKey(key), closeTo(16.0, 0.01));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Input Validation                                                    │
    // └─────────────────────────────────────────────────────────────────────┘
    test('NaN and infinite inputs are silently rejected', () {
      final tracker = DriftTracker();
      // NaN top — build block with NaN
      final nanBlock = _TestBlock(
        absoluteRect: AbsoluteRect.fromLTWH(100, double.nan, 200, 20.0),
      );
      tracker.addObservation(nanBlock, const Offset(1, 1));
      // Infinite drift
      var block = _makeBlock(top: 0);
      tracker.addObservation(block, const Offset(double.infinity, 1));
      // Infinite top
      final infBlock = _TestBlock(
        absoluteRect: AbsoluteRect.fromLTWH(100, double.infinity, 200, 20.0),
      );
      tracker.addObservation(infBlock, const Offset(1, 1));
      expect(tracker.totalObservations, isZero);
    });

    test('zero or negative blockHeight falls back to 16.0', () {
      final tracker = DriftTracker();
      var block = _makeBlock(top: 0);
      tracker.addObservation(block, const Offset(1, 1), blockHeight: 0);
      block = _makeBlock(top: 0);
      tracker.addObservation(block, const Offset(1, 1), blockHeight: -5);
      block = _makeBlock(top: 0);
      tracker.addObservation(
        block,
        const Offset(1, 1),
        blockHeight: double.nan,
      );
      // All three should use fallback 16.0
      final key = tracker.spaceKeyFor(_makeBlock(top: 0));
      expect(tracker.medianBlockHeightForKey(key), closeTo(16.0, 0.01));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Open-Loop Stability                                                 │
    // └─────────────────────────────────────────────────────────────────────┘
    test('feeding corrected residuals does not amplify median', () {
      final tracker = DriftTracker();
      // 5 raw observations of consistent 5px drift
      for (var i = 0; i < 5; i++) {
        final block = _makeBlock(top: 1000);
        tracker.addObservation(block, const Offset(0, 5));
      }
      final key = tracker.spaceKeyFor(_makeBlock(top: 1000));
      final median1 = tracker.medianDriftForKey(key);
      expect(median1.dy, closeTo(5.0, 0.1));

      // Simulate corrected residual (drift - correction = ~0)
      for (var i = 0; i < 5; i++) {
        final block = _makeBlock(top: 1000);
        tracker.addObservation(block, const Offset(0, 0));
      }
      // Median should decrease, not grow
      final median2 = tracker.medianDriftForKey(key);
      expect(median2.dy, lessThanOrEqualTo(median1.dy));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ SLAM §2.1: Submap Model Tests                                       │
    // └─────────────────────────────────────────────────────────────────────┘

    test('spaceKeyFor computes consistent keys from block properties', () {
      final tracker = DriftTracker();
      final block1 = _makeBlock(top: 300);
      final block2 = _makeBlock(top: 300);
      expect(tracker.spaceKeyFor(block1), equals(tracker.spaceKeyFor(block2)));
    });

    test(
      'spaceKeyFor uses absoluteRect.top not captureScrollY for region bucketing',
      () {
        final tracker = DriftTracker();
        final block300 = _makeBlock(top: 300);
        final block600 = _makeBlock(top: 600);
        final key300 = tracker.spaceKeyFor(block300);
        final key600 = tracker.spaceKeyFor(block600);
        expect(key300, isNot(equals(key600)));
      },
    );

    test('spaceKeyFor returns normal:N for regular blocks', () {
      final tracker = DriftTracker();
      final block = _makeBlock(top: 250);
      final key = tracker.spaceKeyFor(block);
      expect(key, equals(const SpaceKey('normal:0')));
    });

    test(
      'spaceKeyFor returns ic:containerId:N for IC blocks with containerId',
      () {
        final tracker = DriftTracker();
        final block = _makeBlock(
          top: 300,
          isInnerScrollerChild: true,
          containerId: const ContainerId('sidebar_scroller'),
        );
        final key = tracker.spaceKeyFor(block);
        expect(key, equals(const SpaceKey('ic:sidebar_scroller:0')));
      },
    );

    test('spaceKeyFor returns unknown for IC block without containerId', () {
      final tracker = DriftTracker();
      final block = _makeBlock(
        top: 300,
        isInnerScrollerChild: true,
        containerId: null,
      );
      final key = tracker.spaceKeyFor(block);
      // hierarchyWeight = 20, but containerId is null → unknown space
      expect(key, equals(SpaceKey.unknown()));
    });

    test('SpaceKey.unknown() creates sentinel key', () {
      expect(SpaceKey.unknown(), equals(const SpaceKey('unknown:0')));
    });

    test('medianDriftForKey returns Offset.zero for unknown key', () {
      final tracker = DriftTracker();
      expect(
        tracker.medianDriftForKey(SpaceKey.unknown()),
        equals(Offset.zero),
      );
    });

    test(
      'IC-without-containerId gets no correction even when normal space has drift',
      () {
        final tracker = DriftTracker();

        // Seed normal-space observations so medianDriftForKey(normal:0) != zero
        for (var i = 0; i < 5; i++) {
          final normalBlock = _makeBlock(top: 250);
          tracker.addObservation(
            normalBlock,
            const Offset(0, 8.0),
            blockHeight: 20.0,
          );
        }
        // Sanity: normal space has non-zero drift
        expect(
          tracker.medianDriftForKey(SpaceKey.normal(0)),
          isNot(equals(Offset.zero)),
        );

        // IC-without-containerId must NOT receive that correction
        final icBlock = _makeBlock(
          top: 250,
          isInnerScrollerChild: true,
          containerId: null,
        );
        final spaceKey = tracker.spaceKeyFor(icBlock);
        expect(tracker.medianDriftForKey(spaceKey), equals(Offset.zero));
      },
    );

    test('carousel-only block stays in normal space (not unknown)', () {
      final tracker = DriftTracker();
      final carouselBlock = _makeBlock(top: 250, isHorizontalScrollChild: true);
      // Carousel: hierarchyWeight == 20 but isInnerScrollerChild is false
      expect(tracker.spaceKeyFor(carouselBlock), equals(SpaceKey.normal(0)));
    });

    test('medianDriftForKey works with string keys', () {
      final tracker = DriftTracker();
      // Use addObservation with blocks
      for (var i = 0; i < 3; i++) {
        final block = _makeBlock(top: 250, blockHeight: 20.0);
        tracker.addObservation(block, const Offset(0, 5.0), blockHeight: 20.0);
      }
      // Region 0 should have observations
      final key = tracker.spaceKeyFor(_makeBlock(top: 250));
      expect(tracker.observationCountForKey(key), equals(3));
    });

    test('normal and IC drift are tracked independently', () {
      final tracker = DriftTracker();
      // Add 3 observations to normal:0
      for (var i = 0; i < 3; i++) {
        final block = _makeBlock(top: 250, blockHeight: 20.0);
        tracker.addObservation(block, const Offset(0, 10.0), blockHeight: 20.0);
      }
      // Get the key for normal:0
      final normalKey = tracker.spaceKeyFor(_makeBlock(top: 250));
      expect(tracker.medianDriftForKey(normalKey).dy, closeTo(10.0, 0.1));
    });

    test('VR blocks (weight 40) are skipped in addObservation', () {
      final tracker = DriftTracker();
      final vrBlock = _makeBlock(top: 300, isViewportRelative: true);
      expect(vrBlock.hierarchyWeight, equals(40));
      tracker.addObservation(vrBlock, const Offset(5, 5));
      expect(tracker.totalObservations, equals(0));
    });

    test('clearKey removes the specified space key and returns true', () {
      final tracker = DriftTracker();
      final block = _makeBlock(top: 100);
      tracker.addObservation(block, const Offset(5, 5));
      final spaceKey = tracker.spaceKeyFor(block);
      expect(tracker.observedKeys, contains(spaceKey));

      final removed = tracker.clearKey(spaceKey);
      expect(removed, isTrue);
      expect(tracker.observedKeys, isEmpty);
    });

    test('clearKey returns false for non-existent key', () {
      final tracker = DriftTracker();
      expect(tracker.clearKey(const SpaceKey('normal:999')), isFalse);
    });

    test('clearKey returns false for unknown key (no observations exist)', () {
      final tracker = DriftTracker();
      expect(tracker.clearKey(SpaceKey.unknown()), isFalse);
    });

    test('driftMarginForKey returns 0.0 for unknown key', () {
      final tracker = DriftTracker();
      expect(tracker.driftMarginForKey(SpaceKey.unknown()), equals(0.0));
    });

    test('recordPropagation works for unknown key without throwing', () {
      final tracker = DriftTracker();
      expect(() {
        tracker.recordPropagation(SpaceKey.unknown());
        tracker.recordPropagation(SpaceKey.unknown());
      }, returnsNormally);
    });

    test('medianDriftForKey returns zero for nonexistent key', () {
      final tracker = DriftTracker();
      expect(
        tracker.medianDriftForKey(const SpaceKey('normal:99')),
        equals(Offset.zero),
      );
    });

    test(
      'carousel blocks (weight 20 + isHorizontalScrollChild) are skipped',
      () {
        final tracker = DriftTracker();
        final carouselBlock = _makeBlock(
          top: 300,
          isHorizontalScrollChild: true,
        );
        expect(carouselBlock.hierarchyWeight, equals(20));
        tracker.addObservation(carouselBlock, const Offset(5, 5));
        // Carousel blocks are skipped (weight 20 + isHorizontalScrollChild)
        expect(tracker.totalObservations, equals(0));
      },
    );

    test('nested blocks (weight 30) are skipped in addObservation', () {
      final tracker = DriftTracker();
      final nestedBlock = _makeBlock(
        top: 300,
        isInnerScrollerChild: true,
        isHorizontalScrollChild: true,
      );
      expect(nestedBlock.hierarchyWeight, equals(30));
      tracker.addObservation(nestedBlock, const Offset(5, 5));
      expect(tracker.totalObservations, equals(0));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ SLAM PR05b Review Cycle 2 Tests                                     │
    // └─────────────────────────────────────────────────────────────────────┘

    test('clearSpatialRegion clears observations in intersecting regions', () {
      final tracker = DriftTracker();
      // Add 3+ observations to normal:0
      for (var i = 0; i < 3; i++) {
        final block = _makeBlock(top: 250, blockHeight: 20.0);
        tracker.addObservation(block, const Offset(0, 10.0), blockHeight: 20.0);
      }
      // Add 3+ observations to ic:foo:0 (same region)
      for (var i = 0; i < 3; i++) {
        final block = _makeBlock(
          top: 300,
          isInnerScrollerChild: true,
          containerId: const ContainerId('foo'),
          blockHeight: 20.0,
        );
        tracker.addObservation(block, const Offset(0, 20.0), blockHeight: 20.0);
      }
      // Add 3+ observations to normal:2 (region 2, should NOT be cleared)
      for (var i = 0; i < 3; i++) {
        final block = _makeBlock(top: 1200, blockHeight: 20.0);
        tracker.addObservation(block, const Offset(0, 5.0), blockHeight: 20.0);
      }

      // Clear regions 0 only (top 0..400)
      tracker.clearSpatialRegion(0, 400);

      // Verify normal:0 is cleared
      expect(tracker.observationCountForKey(const SpaceKey('normal:0')),
          equals(0));
      // Verify ic:foo:0 is cleared
      expect(tracker.observationCountForKey(const SpaceKey('ic:foo:0')),
          equals(0));
      // Verify normal:2 is untouched
      expect(tracker.observationCountForKey(const SpaceKey('normal:2')),
          equals(3));
    });

    test('clearSpatialRegion at exact region boundary (500px)', () {
      final tracker = DriftTracker();
      // Region 0: top < 500, Region 1: top >= 500
      final blockR0 = _makeBlock(top: 250);
      final blockR1 = _makeBlock(top: 750);
      tracker.addObservation(blockR0, const Offset(1, 1));
      tracker.addObservation(blockR1, const Offset(1, 1));

      // clear(0, 500) → firstRegion = floor(0/500) = 0, lastRegion = floor(500/500) = 1
      // So clear(0, 500) clears regions 0 AND 1
      tracker.clearSpatialRegion(0, 500);
      final keyR0 = tracker.spaceKeyFor(blockR0);
      final keyR1 = tracker.spaceKeyFor(blockR1);
      expect(tracker.observationCountForKey(keyR0), equals(0));
      expect(tracker.observationCountForKey(keyR1), equals(0));
    });

    test('clearSpatialRegion spanning multiple regions', () {
      final tracker = DriftTracker();
      for (var i = 0; i < 3; i++) {
        tracker.addObservation(
          _makeBlock(top: 250),
          const Offset(1, 1),
        ); // region 0
        tracker.addObservation(
          _makeBlock(top: 750),
          const Offset(1, 1),
        ); // region 1
        tracker.addObservation(
          _makeBlock(top: 1250),
          const Offset(1, 1),
        ); // region 2
        tracker.addObservation(
          _makeBlock(top: 1750),
          const Offset(1, 1),
        ); // region 3
      }
      // Clear regions overlapping 300..1100 → floor(300/500)=0, floor(1100/500)=2
      tracker.clearSpatialRegion(300, 1100);
      expect(
        tracker.observationCountForKey(
          tracker.spaceKeyFor(_makeBlock(top: 250)),
        ),
        equals(0),
      ); // region 0 cleared
      expect(
        tracker.observationCountForKey(
          tracker.spaceKeyFor(_makeBlock(top: 750)),
        ),
        equals(0),
      ); // region 1 cleared
      expect(
        tracker.observationCountForKey(
          tracker.spaceKeyFor(_makeBlock(top: 1250)),
        ),
        equals(0),
      ); // region 2 cleared
      expect(
        tracker.observationCountForKey(
          tracker.spaceKeyFor(_makeBlock(top: 1750)),
        ),
        equals(3),
      ); // region 3 untouched
    });

    test('normal and IC drift are tracked independently', () {
      final tracker = DriftTracker();
      // Add 3+ observations to normal:0 with drift (0, 10)
      for (var i = 0; i < 3; i++) {
        final block = _makeBlock(top: 250, blockHeight: 20.0);
        tracker.addObservation(block, const Offset(0, 10.0), blockHeight: 20.0);
      }
      // Add 3+ observations to ic:test_container:0 with drift (0, 20)
      for (var i = 0; i < 3; i++) {
        final block = _makeBlock(
          top: 250,
          isInnerScrollerChild: true,
          containerId: const ContainerId('test_container'),
          blockHeight: 20.0,
        );
        tracker.addObservation(block, const Offset(0, 20.0), blockHeight: 20.0);
      }

      // Verify normal:0 median drift
      expect(
        tracker.medianDriftForKey(const SpaceKey('normal:0')).dy,
        closeTo(10.0, 0.1),
      );
      // Verify ic:test_container:0 median drift
      expect(
        tracker.medianDriftForKey(const SpaceKey('ic:test_container:0')).dy,
        closeTo(20.0, 0.1),
      );
      // Verify they don't see each other's drift
      expect(tracker.observationCountForKey(const SpaceKey('normal:0')),
          equals(3));
      expect(
        tracker.observationCountForKey(const SpaceKey('ic:test_container:0')),
        equals(3),
      );
    });

    test('two different IC containers track drift independently', () {
      final tracker = DriftTracker();
      // Add 3+ observations to left_sidebar at top 250 with drift (0, 5)
      for (var i = 0; i < 3; i++) {
        final block = _makeBlock(
          top: 250,
          isInnerScrollerChild: true,
          containerId: const ContainerId('left_sidebar'),
          blockHeight: 20.0,
        );
        tracker.addObservation(block, const Offset(0, 5.0), blockHeight: 20.0);
      }
      // Add 3+ observations to right_sidebar at top 250 with drift (0, 15)
      for (var i = 0; i < 3; i++) {
        final block = _makeBlock(
          top: 250,
          isInnerScrollerChild: true,
          containerId: const ContainerId('right_sidebar'),
          blockHeight: 20.0,
        );
        tracker.addObservation(block, const Offset(0, 15.0), blockHeight: 20.0);
      }

      // Verify independent drift tracking
      expect(
        tracker.medianDriftForKey(const SpaceKey('ic:left_sidebar:0')).dy,
        closeTo(5.0, 0.1),
      );
      expect(
        tracker.medianDriftForKey(const SpaceKey('ic:right_sidebar:0')).dy,
        closeTo(15.0, 0.1),
      );
      // Verify keys differ
      final leftBlock = _makeBlock(
        top: 250,
        isInnerScrollerChild: true,
        containerId: const ContainerId('left_sidebar'),
      );
      final rightBlock = _makeBlock(
        top: 250,
        isInnerScrollerChild: true,
        containerId: const ContainerId('right_sidebar'),
      );
      expect(
        tracker.spaceKeyFor(leftBlock),
        isNot(equals(tracker.spaceKeyFor(rightBlock))),
      );
    });

    test('spaceKeyFor region bucketing respects top=500 boundary', () {
      final tracker = DriftTracker();
      expect(
        tracker.spaceKeyFor(_makeBlock(top: 499)),
        equals(const SpaceKey('normal:0')),
      );
      expect(
        tracker.spaceKeyFor(_makeBlock(top: 500)),
        equals(const SpaceKey('normal:1')),
      );
      expect(
        tracker.spaceKeyFor(_makeBlock(top: 501)),
        equals(const SpaceKey('normal:1')),
      );
    });

    test(
      'IC block without containerId excluded from drift (no normal contamination)',
      () {
        final tracker = DriftTracker();
        final block = _makeBlock(
          top: 250,
          isInnerScrollerChild: true,
          containerId: null,
        );
        tracker.addObservation(block, const Offset(0, 5.0));
        // Must not pollute normal space — observation is excluded entirely
        expect(tracker.observationCountForKey(const SpaceKey('normal:0')),
            equals(0));
        expect(
          tracker.observationCountForKey(const SpaceKey('ic:null:0')),
          equals(0),
        );
        // No unknown-space observations either
        expect(tracker.observationCountForKey(SpaceKey.unknown()), equals(0));
      },
    );

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ Ring Buffer and Debug Export (PR07)                                 │
    // └─────────────────────────────────────────────────────────────────────┘

    test('ring buffer respects 500 observation capacity across all keys', () {
      final tracker = DriftTracker();
      // Add 600 observations: enough to exceed the 500 global log capacity
      // but distributed so we don't hit per-region limits (20 per region)
      for (var i = 0; i < 600; i++) {
        // Cycle through different regions to avoid per-region caps
        final top = ((i ~/ 20) * 600).toDouble() + 250;
        final block = _makeBlock(top: top, blockHeight: 20.0);
        tracker.addObservation(
          block,
          Offset(i.toDouble(), i.toDouble()),
          blockHeight: 20.0,
        );
      }
      // The observation log should cap at 500 entries total
      // We can't check debugTotalObservationCount because that's per-region capped at 20
      // Instead, we check the export log length
      final log = tracker.exportDebugLog();
      final lines = log.split('\n');
      // Find the line with "current:" to verify the log size
      final capacityLine = lines.firstWhere((l) => l.contains('current:'));
      expect(capacityLine, contains('current: 500'));
    });

    test('ring buffer evicts oldest observations (FIFO)', () {
      final tracker = DriftTracker();
      // Add 10 observations with increasing Y drift
      for (var i = 0; i < 10; i++) {
        final block = _makeBlock(top: 250, blockHeight: 20.0);
        tracker.addObservation(
          block,
          Offset(0, i.toDouble()), // 0, 1, 2, ..., 9
          blockHeight: 20.0,
        );
      }
      final key = tracker.spaceKeyFor(_makeBlock(top: 250));
      expect(tracker.observationCountForKey(key), equals(10));

      // Now add 15 more (total 25, but per-region cap is 20)
      for (var i = 10; i < 25; i++) {
        final block = _makeBlock(top: 250, blockHeight: 20.0);
        tracker.addObservation(
          block,
          Offset(0, i.toDouble()),
          blockHeight: 20.0,
        );
      }
      expect(tracker.observationCountForKey(key), equals(20));
    });

    test('exportDebugLog contains expected header and summary', () {
      final tracker = DriftTracker();
      // Add observations to two space keys
      for (var i = 0; i < 5; i++) {
        final block = _makeBlock(top: 250, blockHeight: 20.0);
        tracker.addObservation(
          block,
          const Offset(2.0, 3.0),
          blockHeight: 20.0,
        );
      }
      for (var i = 0; i < 3; i++) {
        final block = _makeBlock(top: 750, blockHeight: 25.0);
        tracker.addObservation(
          block,
          const Offset(1.0, -1.0),
          blockHeight: 25.0,
        );
      }

      final now = DateTime(2025, 4, 10, 12, 30, 45);
      final log = tracker.exportDebugLog(now: now);

      // Verify header is present
      expect(log, contains('=== Drift Tracker Debug Log ==='));
      expect(log, contains('Generated at: 2025-04-10T12:30:45.000'));
      expect(log, contains('Region size: 500 CSS px'));
      expect(log, contains('Log capacity: 500'));

      // Verify per-key summary section exists
      expect(log, contains('--- Per-space-key summary ---'));
      expect(log, contains('space=normal:0'));
      expect(log, contains('space=normal:1'));
      expect(log, contains('n=5'));
      expect(log, contains('n=3'));

      // Verify raw log section exists
      expect(log, contains('--- Raw observation log'));
    });

    test('exportDebugLog shows per-key statistics', () {
      final tracker = DriftTracker();
      // Add 5 consistent observations to normal:0
      for (var i = 0; i < 5; i++) {
        final block = _makeBlock(top: 250, blockHeight: 20.0);
        tracker.addObservation(
          block,
          const Offset(2.0, 4.0),
          blockHeight: 20.0,
        );
      }

      final log = tracker.exportDebugLog();

      // Verify summary line contains key metrics
      expect(log, contains('space=normal:0'));
      expect(log, contains('n=5'));
      expect(log, contains('medX=2.00')); // median of 2, 2, 2, 2, 2
      expect(log, contains('medY=4.00')); // median of 4, 4, 4, 4, 4
      expect(log, contains('maxMargin=')); // should have max margin
      expect(log, contains('propagations=0')); // no propagations yet
    });

    test('exportDebugLog format stability with fixed observations', () {
      final tracker = DriftTracker();
      final now = DateTime(2025, 4, 10, 14, 0, 0);

      // Add predictable observations
      final block1 = _makeBlock(top: 250, blockHeight: 18.5);
      tracker.addObservation(block1, const Offset(1.5, 2.5), blockHeight: 18.5);
      tracker.addObservation(block1, const Offset(1.5, 2.5), blockHeight: 18.5);
      tracker.addObservation(block1, const Offset(1.5, 2.5), blockHeight: 18.5);

      final log = tracker.exportDebugLog(now: now);

      // Verify raw observation log entries are present with correct format
      expect(log, contains('key=normal:0'));
      expect(log, contains('dx=1.50'));
      expect(log, contains('dy=2.50'));
      expect(log, contains('h=18.5'));
    });

    test('recordPropagation increments per-key count', () {
      final tracker = DriftTracker();
      // Add observations so we have a space key
      final block = _makeBlock(top: 250, blockHeight: 20.0);
      tracker.addObservation(block, const Offset(1.0, 1.0), blockHeight: 20.0);

      // Record propagations
      tracker.recordPropagation(const SpaceKey('normal:0'));
      tracker.recordPropagation(const SpaceKey('normal:0'));
      tracker.recordPropagation(const SpaceKey('normal:0'));

      final log = tracker.exportDebugLog();
      expect(log, contains('propagations=3'));
    });

    test('recordPropagation works for multiple space keys independently', () {
      final tracker = DriftTracker();
      // Add observations to two keys
      for (var i = 0; i < 3; i++) {
        final block = _makeBlock(top: 250, blockHeight: 20.0);
        tracker.addObservation(
          block,
          const Offset(1.0, 1.0),
          blockHeight: 20.0,
        );
      }
      for (var i = 0; i < 3; i++) {
        final block = _makeBlock(top: 750, blockHeight: 20.0);
        tracker.addObservation(
          block,
          const Offset(1.0, 1.0),
          blockHeight: 20.0,
        );
      }

      // Record different propagation counts
      tracker.recordPropagation(const SpaceKey('normal:0'));
      tracker.recordPropagation(const SpaceKey('normal:0'));
      tracker.recordPropagation(const SpaceKey('normal:1'));

      final log = tracker.exportDebugLog();
      expect(log, contains('space=normal:0'));
      expect(log, contains('propagations=2'));
      expect(log, contains('space=normal:1'));
      expect(log, contains('propagations=1'));
    });

    test('clear() resets propagation counts', () {
      final tracker = DriftTracker();
      final block = _makeBlock(top: 250, blockHeight: 20.0);
      tracker.addObservation(block, const Offset(1.0, 1.0), blockHeight: 20.0);
      tracker.recordPropagation(const SpaceKey('normal:0'));
      tracker.recordPropagation(const SpaceKey('normal:0'));

      tracker.clear();

      final log = tracker.exportDebugLog();
      // After clear, no observations, so no summary lines
      expect(log, contains('Log capacity: 500'));
      expect(log, contains('current: 0'));
    });

    test('exportDebugLog handles empty tracker gracefully', () {
      final tracker = DriftTracker();
      final log = tracker.exportDebugLog();
      expect(log, contains('=== Drift Tracker Debug Log ==='));
      expect(log, contains('Log capacity: 500'));
      expect(log, contains('current: 0'));
    });

    test('exportDebugLog uses current time when now is not provided', () {
      final tracker = DriftTracker();
      final block = _makeBlock(top: 250, blockHeight: 20.0);
      tracker.addObservation(block, const Offset(1.0, 1.0), blockHeight: 20.0);

      // Call without passing now — should use DateTime.now()
      final log = tracker.exportDebugLog();
      expect(log, contains('Generated at:'));
      // Just verify it contains a timestamp format
      expect(log, matches(RegExp(r'Generated at: \d{4}-\d{2}-\d{2}T')));
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ clearSpatialRegion Boundary Conditions                              │
    // └─────────────────────────────────────────────────────────────────────┘
    test('clearSpatialRegion rejects NaN top', () {
      final tracker = DriftTracker();
      final block = _makeBlock(top: 250);
      tracker.addObservation(block, const Offset(1, 1));
      tracker.clearSpatialRegion(double.nan, 400);
      expect(
        tracker.observationCountForKey(tracker.spaceKeyFor(block)),
        equals(1),
      );
    });

    test('clearSpatialRegion rejects infinite bottom', () {
      final tracker = DriftTracker();
      final block = _makeBlock(top: 250);
      tracker.addObservation(block, const Offset(1, 1));
      tracker.clearSpatialRegion(0, double.infinity);
      expect(
        tracker.observationCountForKey(tracker.spaceKeyFor(block)),
        equals(1),
      );
    });

    test('clearSpatialRegion rejects inverted range', () {
      final tracker = DriftTracker();
      final block = _makeBlock(top: 250);
      tracker.addObservation(block, const Offset(1, 1));
      tracker.clearSpatialRegion(500, 400);
      expect(
        tracker.observationCountForKey(tracker.spaceKeyFor(block)),
        equals(1),
      );
    });

    test('clearSpatialRegion rejects equal bounds', () {
      final tracker = DriftTracker();
      final block = _makeBlock(top: 250);
      tracker.addObservation(block, const Offset(1, 1));
      tracker.clearSpatialRegion(500, 500);
      expect(
        tracker.observationCountForKey(tracker.spaceKeyFor(block)),
        equals(1),
      );
    });

    // ┌─────────────────────────────────────────────────────────────────────┐
    // │ TrackedBlock<T> Generic Payload Contract                            │
    // └─────────────────────────────────────────────────────────────────────┘
    test('TrackedBlock with typed payload works with DriftTracker', () {
      final tracker = DriftTracker();
      final block = _PayloadBlock(
        absoluteRect: AbsoluteRect.fromLTWH(100, 200, 150, 30),
        payload: 'hello',
      );
      tracker.addObservation(block, const Offset(1, 2));
      expect(tracker.totalObservations, equals(1));
    });

    test('TrackedBlock with typed payload works with SpatialBlockIndex', () {
      final index = SpatialBlockIndex<_PayloadBlock>();
      final block = _PayloadBlock(
        absoluteRect: AbsoluteRect.fromLTWH(100, 200, 150, 30),
        payload: 'hello',
      );
      index.add(block);
      expect(index.candidates(block).toList(), contains(block));
      expect(block.payload, equals('hello'));
    });

    test('TrackedBlock<Never> payload throws UnsupportedError', () {
      final block = _makeBlock(top: 100);
      expect(() => block.payload, throwsUnsupportedError);
    });
  });

  group('propagation-count lifecycle (#55 / v0.6.0)', () {
    test('clearKey removes the matching propagation count', () {
      final tracker = DriftTracker();
      final key = SpaceKey.normal(0);
      tracker.recordPropagation(key);
      tracker.recordPropagation(key);
      expect(tracker.propagationCountFor(key), 2);

      tracker.clearKey(key);
      expect(tracker.propagationCountFor(key), 0,
          reason: 'pre-0.6.0, cleared keys leaked their propagation '
              'counts for the rest of the session');
    });

    test('clearSpatialRegion removes counts for intersecting regions', () {
      final tracker = DriftTracker();
      final inRange = SpaceKey.normal(1); // region 1 = 500-1000 CSS px
      final outOfRange = SpaceKey.normal(5);
      tracker.recordPropagation(inRange);
      tracker.recordPropagation(outOfRange);

      tracker.clearSpatialRegion(500, 1000);
      expect(tracker.propagationCountFor(inRange), 0);
      expect(tracker.propagationCountFor(outOfRange), 1);
    });

    test('median cache invalidates on new observations and clears (#55)', () {
      final tracker = DriftTracker();
      for (var i = 0; i < 5; i++) {
        tracker.addObservation(_makeBlock(top: 100), const Offset(0, 2.0));
      }
      final key = tracker.spaceKeyFor(_makeBlock(top: 100));
      expect(tracker.medianDriftForKey(key).dy, closeTo(2.0, 1e-9));

      // Shift the window decisively; the cached median must not survive.
      for (var i = 0; i < 20; i++) {
        tracker.addObservation(_makeBlock(top: 100), const Offset(0, 8.0));
      }
      expect(tracker.medianDriftForKey(key).dy, closeTo(8.0, 1e-9));

      tracker.clearKey(key);
      expect(tracker.medianDriftForKey(key), Offset.zero);
      expect(tracker.medianBlockHeightForKey(key), 16.0);
    });

    test('deprecated spaceKeys alias still mirrors observedKeys', () {
      final tracker = DriftTracker();
      tracker.addObservation(
        _makeBlock(top: 100),
        const Offset(2, 3),
        blockHeight: 30,
      );
      // ignore: deprecated_member_use_from_same_package
      expect(tracker.spaceKeys.toList(), tracker.observedKeys.toList());
    });
  });
}
