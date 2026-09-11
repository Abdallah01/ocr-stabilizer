// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #150: the coherent-shift detector standing on its own — no engine, no
// spatial index, just candidates, a config and a drift tracker. The
// engine-level behaviour (what a plan DOES to a merge, the frozen drift
// snapshot, order independence, the event summary) stays pinned by the
// stabilization_engine_coherent_shift_*_test.dart files and the
// differential replay harness; these tests pin the class's own contract.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:ocr_stabilizer/src/internal/coherent_shift_detector.dart';
import 'package:test/test.dart';

DefaultTrackedBlock<Object> _block(double top, {String text = 't'}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(10, top, 200, 30),
      originalText: text,
      positionConfidence: const PositionConfidence(0.8),
      textConfidence: const TextConfidence(0.9),
      payload: const Object(),
    );

/// A primary match of [fresh] onto [existing].
ShiftCandidate<DefaultTrackedBlock<Object>> _pair(
        DefaultTrackedBlock<Object> existing,
        DefaultTrackedBlock<Object> fresh) =>
    (
      fresh: fresh,
      result: (
        match: existing,
        wasBandFallback: false,
        wasNestedFragment: false
      ),
    );

CoherentShiftDetector<DefaultTrackedBlock<Object>> _detector(
        [CoherentShiftConfig config = const CoherentShiftConfig()]) =>
    CoherentShiftDetector<DefaultTrackedBlock<Object>>(
      config: config,
      driftTracker: DriftTracker(),
    );

void main() {
  // Height 30 → agreement scale 90 px: a displacement over 90 px is
  // "moved", one at or under it is not.
  group('CoherentShiftDetector.detect', () {
    test('three movers agreeing on a translation decide a quorum plan', () {
      final existing = [_block(100), _block(200), _block(300)];
      final candidates = [
        for (final e in existing)
          _pair(e, _block(e.absoluteRect.raw.top + 300)),
      ];
      final plan = _detector().detect(candidates);
      expect(plan, isNotNull);
      expect(plan!.source, CoherentShiftSource.quorum);
      expect(plan.translation, const Offset(0, 300));
      expect(plan.memberDrift.keys, unorderedEquals(existing));
      expect(plan.adopted, isEmpty);
    });

    test('too few movers → no plan (fallbacks off by default)', () {
      final e = _block(100);
      expect(_detector().detect([_pair(e, _block(400))]), isNull);
    });

    test(
        'an under-gate pair within tolerance of the decided translation '
        'is adopted into the merge, not the vote', () {
      // Movers at +100 (over the 90 px gate); one pair at +88 sits under
      // the gate but within 0.5 × 30 = 15 px of the translation.
      final movers = [_block(100), _block(200), _block(300)];
      final agreeing = _block(400);
      final plan = _detector().detect([
        for (final e in movers) _pair(e, _block(e.absoluteRect.raw.top + 100)),
        _pair(agreeing, _block(488)),
      ]);
      expect(plan, isNotNull);
      expect(plan!.translation, const Offset(0, 100),
          reason: 'the adoptee never enters the median');
      expect(plan.adopted, [agreeing]);
      expect(plan.memberDrift.keys, unorderedEquals([...movers, agreeing]));
    });

    test('adoption off leaves the under-gate pair out', () {
      final movers = [_block(100), _block(200), _block(300)];
      final plan =
          _detector(const CoherentShiftConfig(adoptAgreeing: false)).detect([
        for (final e in movers) _pair(e, _block(e.absoluteRect.raw.top + 100)),
        _pair(_block(400), _block(488)),
      ]);
      expect(plan!.adopted, isEmpty);
      expect(plan.memberDrift.keys, unorderedEquals(movers));
    });

    test('the floor fallback re-anchors a lone mover past the floor', () {
      final e = _block(100);
      final plan = _detector(const CoherentShiftConfig(
        experimental: ExperimentalCoherentShiftOptions(floorPx: 200),
      )).detect([_pair(e, _block(400))]);
      expect(plan, isNotNull);
      expect(plan!.source, CoherentShiftSource.floor);
      expect(plan.translation, const Offset(0, 300));
    });

    test(
        'ineligible pairs never vote: provisional, band, nested, '
        'viewport-relative', () {
      final provisional = _block(100).copyWith(isProvisional: true);
      final viewportFresh =
          _block(500).copyWith(coordinates: const CoordinateContext.viewport());
      final plain = _block(300);
      final plan = _detector().detect([
        _pair(provisional, _block(400)),
        _pair(_block(200), viewportFresh),
        (
          fresh: _block(600),
          result: (
            match: plain,
            wasBandFallback: true,
            wasNestedFragment: false
          ),
        ),
        (
          fresh: _block(600),
          result: (
            match: plain,
            wasBandFallback: false,
            wasNestedFragment: true
          ),
        ),
      ]);
      expect(plan, isNull);
    });
  });
}
