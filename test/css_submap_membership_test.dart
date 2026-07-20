// ignore_for_file: unused_element_parameter

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// CSS SUBMAP MEMBERSHIP TESTS (#48 / v0.6.0)
// =============================================================================
// First direct coverage of the tier → SpaceKey mapping. Regression for the
// v0.5.0 audit finding §1.5: VR (weight 40) and nested IC+carousel (weight
// 30) blocks fell through to SpaceKey.normal, so a position:fixed header
// received page-scroll drift corrections it never contributed to.
// =============================================================================

class _TestBlock implements TrackedBlock<Never> {
  @override
  final AbsoluteRect absoluteRect;
  @override
  final bool isViewportRelative;
  @override
  final bool isInnerScrollerChild;
  @override
  final double innerScrollerTop;
  @override
  final ContainerId? containerId;
  @override
  final bool isHorizontalScrollChild;
  @override
  final String originalText;
  @override
  final bool isFromStickyElement;
  @override
  final PositionConfidence positionConfidence;
  @override
  final TextConfidence textConfidence;
  @override
  final int sourceQuality;

  @override
  Never get payload => throw UnsupportedError('_TestBlock has no payload');

  _TestBlock({
    required this.absoluteRect,
    this.isViewportRelative = false,
    this.isInnerScrollerChild = false,
    this.innerScrollerTop = 0,
    this.containerId,
    this.isHorizontalScrollChild = false,
    this.originalText = '',
    this.isFromStickyElement = false,
    this.positionConfidence = const PositionConfidence(0.5),
    this.textConfidence = const TextConfidence(0.5),
    this.sourceQuality = 0,
  });

  @override
  ScrollContext get scrollContext => const ScrollContext(
        scrollY: 0,
        scrollX: 0,
        hzScrollerIndex: -1,
      );

  @override
  StickyFallback get stickyFallback => const StickyFallback(
        scrollY: 0,
        scrollX: 0,
        isIc: false,
        hzScrollerIndex: -1,
      );
}

_TestBlock _at(
  double top, {
  bool vr = false,
  bool ic = false,
  bool hz = false,
  ContainerId? containerId,
}) {
  return _TestBlock(
    absoluteRect: AbsoluteRect(Rect.fromLTWH(0, top, 100, 30)),
    isViewportRelative: vr,
    isInnerScrollerChild: ic,
    isHorizontalScrollChild: hz,
    containerId: containerId,
  );
}

void main() {
  const membership = CssSubmapMembership();

  group('CssSubmapMembership.spaceKeyFor', () {
    test('normal block maps to SpaceKey.normal with region from top', () {
      // regionSize default 500: top 1200 → region 2.
      expect(membership.spaceKeyFor(_at(1200)), SpaceKey.normal(2));
      expect(membership.spaceKeyFor(_at(0)), SpaceKey.normal(0));
    });

    test('VR block (weight 40) maps to unknown — regression #48', () {
      // Pre-0.6.0 this returned SpaceKey.normal(0): a position:fixed
      // header would receive the page-scroll submap's drift correction.
      expect(membership.spaceKeyFor(_at(0, vr: true)), SpaceKey.unknown());
    });

    test('nested IC+carousel (weight 30) maps to unknown — regression #48', () {
      final nested = _at(
        600,
        ic: true,
        hz: true,
        containerId: const ContainerId('c1'),
      );
      expect(nested.hierarchyWeight, HierarchyTiers.nested);
      expect(membership.spaceKeyFor(nested), SpaceKey.unknown());
    });

    test('IC block with containerId maps to SpaceKey.ic', () {
      final ic = _at(600, ic: true, containerId: const ContainerId('c1'));
      expect(
        membership.spaceKeyFor(ic),
        SpaceKey.ic(const ContainerId('c1'), 1),
      );
    });

    test('IC block without containerId maps to unknown', () {
      expect(membership.spaceKeyFor(_at(600, ic: true)), SpaceKey.unknown());
    });

    test('carousel-only block lives in normal vertical scroll space', () {
      // Excluded from observation, but its vertical coordinate space IS
      // the page scroll — it receives normal-space corrections.
      expect(membership.spaceKeyFor(_at(600, hz: true)), SpaceKey.normal(1));
    });

    test('custom regionSize changes region quantization', () {
      const coarse = CssSubmapMembership(regionSize: 1000);
      expect(coarse.spaceKeyFor(_at(1200)), SpaceKey.normal(1));
    });
  });

  group('observation/correction symmetry (#48)', () {
    test('tiers excluded from observation get no correction key', () {
      // The fix's core property: every tier where
      // shouldExcludeFromObservation is true AND which does not live in
      // normal scroll space maps to unknown — so it can neither feed nor
      // receive page-scroll corrections. Carousel-only is the documented
      // exception: excluded from observation, corrected as normal space.
      final vr = _at(0, vr: true);
      final nested = _at(
        0,
        ic: true,
        hz: true,
        containerId: const ContainerId('c1'),
      );
      for (final b in [vr, nested]) {
        expect(membership.shouldExcludeFromObservation(b), isTrue);
        expect(membership.spaceKeyFor(b), SpaceKey.unknown());
      }
    });

    test('drift recorded in normal space never shifts a VR block key', () {
      final tracker = DriftTracker();
      // Feed the normal-space submap enough observations for a median.
      for (var i = 0; i < 5; i++) {
        tracker.addObservation(
          _at(10),
          const Offset(6, 8),
          blockHeight: 30,
        );
      }
      expect(
        tracker.medianDriftForKey(SpaceKey.normal(0)),
        const Offset(6, 8),
      );
      // The VR block resolves to unknown, which has no observations —
      // its correction is zero, not the normal submap's median.
      final vrKey = tracker.spaceKeyFor(_at(10, vr: true));
      expect(vrKey, SpaceKey.unknown());
      expect(tracker.medianDriftForKey(vrKey), Offset.zero);
    });
  });
}
