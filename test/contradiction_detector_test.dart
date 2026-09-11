// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #150: the contradiction detector and the batch dedup pipeline standing
// on their own. Engine-level behaviour stays pinned by the
// stabilization_engine_*contradiction* / dedup test files and the
// differential harness; these pin the classes' own contracts.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:ocr_stabilizer/src/internal/batch_dedup.dart';
import 'package:ocr_stabilizer/src/internal/contradiction_detector.dart';
import 'package:test/test.dart';

DefaultTrackedBlock<Object> _block(String text,
        {double left = 10,
        double top = 100,
        double width = 300,
        double height = 30,
        int observationCount = 1}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, width, height),
      originalText: text,
      positionConfidence: const PositionConfidence(0.8),
      textConfidence: const TextConfidence(0.9),
      payload: const Object(),
      observationCount: observationCount,
    );

void main() {
  group('ContradictionDetector', () {
    test(
        'grouping: two short fresh lines subdividing a well-observed '
        'paragraph whose text they reassemble', () {
      final paragraph = _block('alpha beta gamma delta',
          top: 100, height: 60, observationCount: 3);
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..add(paragraph);
      final lines = [
        _block('alpha beta', top: 100, height: 25),
        _block('gamma delta', top: 130, height: 25),
      ];
      final freshIndex = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..rebuild(lines);
      final events =
          ContradictionDetector(index: index).grouping(lines, freshIndex);
      expect(events, hasLength(1));
      expect(events.single.type, ContradictionType.grouping);
      expect(events.single.target, same(paragraph));
      expect(events.single.evidence, unorderedEquals(lines));
    });

    test(
        'grouping: a cached block under the observation floor is not a '
        'target', () {
      final young = _block('alpha beta gamma delta',
          top: 100, height: 60, observationCount: 2);
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..add(young);
      final lines = [
        _block('alpha beta', top: 100, height: 25),
        _block('gamma delta', top: 130, height: 25),
      ];
      final freshIndex = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..rebuild(lines);
      expect(ContradictionDetector(index: index).grouping(lines, freshIndex),
          isEmpty);
    });

    test('splitting: one fresh paragraph subsuming two well-observed lines',
        () {
      final lines = [
        _block('alpha beta', top: 100, height: 25, observationCount: 3),
        _block('gamma delta', top: 130, height: 25, observationCount: 3),
      ];
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..rebuild(lines);
      final paragraph = _block('alpha beta gamma delta', top: 100, height: 60);
      final events = ContradictionDetector(index: index).splitting([paragraph]);
      expect(events, hasLength(1));
      expect(events.single.type, ContradictionType.splitting);
      expect(events.single.target, same(paragraph));
      expect(events.single.evidence, unorderedEquals(lines));
    });
  });

  group('BatchDedup.run', () {
    BatchDedup<DefaultTrackedBlock<Object>> dedup() => BatchDedup(
          index: SpatialBlockIndex<DefaultTrackedBlock<Object>>(),
          resolver: const OverlapResolver(),
          driftTracker: DriftTracker(),
        );

    test(
        'whitespace-only text is dropped; identical position+text is '
        'kept once', () {
      final a = _block('hello');
      final r = dedup().run([a, _block('   '), _block('hello')],
          bucketWidth: 200, bucketHeight: 200, scale: 1.0);
      expect(r.blocks, [a]);
      expect(r.batchIndex.allBlocks, [a]);
    });

    test(
        'overlapping same-text blocks resolve to one; the kept one is in '
        'the batch grid', () {
      final a = _block('the same line of text', top: 100);
      final b = _block('the same line of text', top: 103);
      final r =
          dedup().run([a, b], bucketWidth: 200, bucketHeight: 200, scale: 1.0);
      expect(r.blocks, hasLength(1));
      expect(r.batchIndex.allBlocks.single, same(r.blocks.single));
    });

    test(
        'a same-text duplicate straddling a bucket boundary (no overlap) is '
        'dropped by the fuzzy neighbour-key check', () {
      // Bucket 200, keyed on round(left / bucket): left 50 → 0, left 110
      // → 1, adjacent buckets; the rects (width 20) do not overlap, so
      // NMS alone would keep both.
      final a = _block('boundary text', left: 50, width: 20);
      final b = _block('boundary text', left: 110, width: 20);
      final r =
          dedup().run([a, b], bucketWidth: 200, bucketHeight: 200, scale: 1.0);
      expect(r.blocks, [a]);
    });

    test(
        'after an NMS eviction the batch grid mirrors the output exactly '
        '(the evicted block is gone from the grid)', () {
      // Three DIFFERENT texts on one rect (same text would be caught by
      // the key dedup before NMS). b out-scores a → a is evicted; c then
      // overlaps the same region and must resolve against b, never a
      // stale a left in the grid.
      DefaultTrackedBlock<Object> at(String text, double conf) =>
          DefaultTrackedBlock<Object>(
            absoluteRect: AbsoluteRect.fromLTWH(10, 100, 300, 30),
            originalText: text,
            positionConfidence: PositionConfidence(conf),
            textConfidence: const TextConfidence(0.9),
            payload: const Object(),
          );
      final a = at('alpha beta gamma', 0.1);
      final b = at('delta epsilon zeta', 0.9);
      final c = at('eta theta iota', 0.5);
      final r = dedup()
          .run([a, b, c], bucketWidth: 200, bucketHeight: 200, scale: 1.0);
      expect(r.blocks, isNot(contains(same(a))),
          reason: 'a is evicted by the higher-quality b');
      expect(r.blocks, contains(same(b)));
      // The invariant the NMS relies on: the grid holds exactly the
      // output, by identity — an evicted block must leave the grid.
      expect(r.batchIndex.allBlocks.map((x) => identityHashCode(x)).toList(),
          r.blocks.map((x) => identityHashCode(x)).toList());
    });
  });
}
