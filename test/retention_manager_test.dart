// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #150: retention and the transform estimator standing on their own. The
// engine-level behaviour (retention across captures, supersession on the
// corpus, the estimate's reading rules) stays pinned by the
// stabilization_engine_retention / supersession / transform test files
// and the differential harness (`retention2` arm); these pin the classes'
// own contracts.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:ocr_stabilizer/src/internal/retention_manager.dart';
import 'package:ocr_stabilizer/src/internal/transform_estimator.dart';
import 'package:test/test.dart';

DefaultTrackedBlock<Object> _block(String text,
        {double left = 10,
        double top = 100,
        double width = 200,
        double height = 30,
        bool provisional = false}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, width, height),
      originalText: text,
      positionConfidence: const PositionConfidence(0.8),
      textConfidence: const TextConfidence(0.9),
      payload: const Object(),
      isProvisional: provisional,
      provisionalCapturesRemaining: provisional ? 2 : 0,
    );

RetentionManager<DefaultTrackedBlock<Object>> _manager(
        SpatialBlockIndex<DefaultTrackedBlock<Object>> index,
        {int missedFrames = 2}) =>
    RetentionManager(
        missedFrames: missedFrames,
        index: index,
        resolver: const OverlapResolver());

void main() {
  group('RetentionManager.retain', () {
    test(
        'an unmatched block is retained for missedFrames captures, then '
        'dropped', () {
      final cached = _block('cached');
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..add(cached);
      final m = _manager(index, missedFrames: 2);
      final r1 = m.retain(stableBlocks: [], matchedExisting: {});
      expect(r1.retained, [cached]);
      expect(r1.dropped, 0);
      final r2 = m.retain(stableBlocks: [], matchedExisting: {});
      expect(r2.retained, [cached]);
      final r3 = m.retain(stableBlocks: [], matchedExisting: {});
      expect(r3.retained, isEmpty);
      expect(r3.dropped, 1);
    });

    test('a matched block is consumed, not retained', () {
      final cached = _block('cached');
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..add(cached);
      final r = _manager(index).retain(
          stableBlocks: [cached], matchedExisting: Set.identity()..add(cached));
      expect(r.retained, isEmpty);
      expect(r.dropped, 0);
    });

    test('a fresh block covering the cached region supersedes it', () {
      final cached = _block('old text', top: 100, width: 200, height: 30);
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..add(cached);
      final fresh = _block('new text', top: 100, width: 200, height: 30);
      final r = _manager(index)
          .retain(stableBlocks: [fresh], matchedExisting: Set.identity());
      expect(r.retained, isEmpty);
      expect(r.dropped, 1);
    });

    test('retention 0: nothing retained, every unmatched block dropped', () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..add(_block('a'))
        ..add(_block('b', top: 200));
      final r = _manager(index, missedFrames: 0)
          .retain(stableBlocks: [], matchedExisting: Set.identity());
      expect(r.retained, isEmpty);
      expect(r.dropped, 2);
    });
  });

  group('TransformEstimator', () {
    test('ineligible pairs never enter the fit', () {
      final e = TransformEstimator<DefaultTrackedBlock<Object>>(minPairs: 3);
      final a = _block('a');
      e.observe(a, _block('a', provisional: true), wasBandFallback: false);
      e.observe(a, a, wasBandFallback: true);
      e.observe(a.copyWith(coordinates: const CoordinateContext.viewport()), a,
          wasBandFallback: false);
      expect(e.estimate(), isNull);
    });

    test('a pure translation of three eligible pairs fits scale 1', () {
      final e = TransformEstimator<DefaultTrackedBlock<Object>>(minPairs: 3);
      for (final top in [100.0, 200.0, 300.0]) {
        e.observe(_block('t', top: top + 50), _block('t', top: top),
            wasBandFallback: false);
      }
      final est = e.estimate();
      expect(est, isNotNull);
      expect(est!.scale, closeTo(1.0, 1e-9));
      expect(est.translation.dy, closeTo(50, 1e-9));
      expect(est.pairCount, 3);
    });
  });
}
