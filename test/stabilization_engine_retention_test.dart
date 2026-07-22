import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// MISSED-FRAME RETENTION (#46 / v0.6.0)
// =============================================================================
// Regression for the v0.5.0 audit finding §1.1: with the index rebuilt from
// each frame's stableBlocks only, a block missed by OCR for a single
// capture lost its identity — observationCount reset, votes and drift
// lineage gone. missedFrameRetention keeps unmatched blocks matchable for
// N further stabilize() calls.
// =============================================================================

StabilizationEngine<DefaultTrackedBlock<void>, void> _engine({
  int retention = 0,
}) {
  return StabilizationEngine<DefaultTrackedBlock<void>, void>(
    merger: (existing, fresh, merge) => existing.applyMerge(merge),
    missedFrameRetention: retention,
  );
}

DefaultTrackedBlock<void> _hello() => DefaultTrackedBlock<void>(
      absoluteRect: const AbsoluteRect(Rect.fromLTWH(10, 100, 200, 30)),
      payload: null,
      originalText: 'hello world',
    );

void main() {
  group('missedFrameRetention (#46)', () {
    test('constructor rejects negative retention', () {
      expect(() => _engine(retention: -1), throwsArgumentError);
    });

    test('default (0): a one-frame miss resets block identity', () {
      final engine = _engine();
      engine.stabilize([_hello()]);
      engine.stabilize(const []); // miss frame — block leaves the index
      final r = engine.stabilize([_hello()]);
      expect(r.stableBlocks.single.observationCount, 1,
          reason: 'pre-0.6.0 behavior must be preserved at retention 0');
    });

    test('retention 1: block survives one missed frame and re-merges', () {
      final engine = _engine(retention: 1);
      engine.stabilize([_hello()]);
      final missFrame = engine.stabilize(const []);
      expect(missFrame.stableBlocks, isEmpty,
          reason: 'retained blocks are not part of stableBlocks');
      final r = engine.stabilize([_hello()]);
      expect(r.stableBlocks.single.observationCount, 2,
          reason: 'the retained block must be matched and its history kept');
    });

    test('retention 1: block expires after two consecutive misses', () {
      final engine = _engine(retention: 1);
      engine.stabilize([_hello()]);
      engine.stabilize(const []); // miss 1 — retained
      engine.stabilize(const []); // miss 2 — expired
      final r = engine.stabilize([_hello()]);
      expect(r.stableBlocks.single.observationCount, 1);
    });

    test('re-observation inside the window resets the miss counter', () {
      final engine = _engine(retention: 1);
      engine.stabilize([_hello()]);
      engine.stabilize(const []); // miss 1
      engine.stabilize([_hello()]); // re-observed: counter resets, count 2
      engine.stabilize(const []); // miss 1 again — still retained
      final r = engine.stabilize([_hello()]);
      expect(r.stableBlocks.single.observationCount, 3);
    });

    test('retention 2: survives two misses, expires after three', () {
      final engine = _engine(retention: 2);
      engine.stabilize([_hello()]);
      engine.stabilize(const []);
      engine.stabilize(const []);
      final back = engine.stabilize([_hello()]);
      expect(back.stableBlocks.single.observationCount, 2);

      engine.stabilize(const []);
      engine.stabilize(const []);
      engine.stabilize(const []);
      final gone = engine.stabilize([_hello()]);
      expect(gone.stableBlocks.single.observationCount, 1);
    });

    test('retained blocks stay out of stableBlocks but in the index', () {
      final engine = _engine(retention: 3);
      engine.stabilize([_hello()]);
      final miss = engine.stabilize(const []);
      expect(miss.stableBlocks, isEmpty);
      expect(engine.spatialIndex.allBlocks, hasLength(1),
          reason: 'the retained block must remain a match candidate');
    });

    test(
        'a block removed from the index externally does not keep a stale '
        'miss count when later re-inserted (PR #61 review)', () {
      final engine = _engine(retention: 2);
      final first = engine.stabilize([_hello()]).stableBlocks.single;
      engine.stabilize(const []); // miss 1 — retained

      // App-side eviction through the public index seam.
      engine.spatialIndex.remove(first);
      engine.stabilize(const []); // block absent — its counter must drop

      // App-side re-insertion (e.g. an external cache restoring it).
      engine.spatialIndex.add(first);
      engine.stabilize(const []); // must count as miss 1, not miss 3
      engine.stabilize(const []); // miss 2 — still inside the window

      final r = engine.stabilize([_hello()]);
      expect(r.stableBlocks.single.observationCount, 2,
          reason: 'a stale pre-removal miss count would have expired the '
              'block early and reset its identity');
    });
  });

  group('updateViewport re-keys the populated index (PR #61 review)', () {
    test('cached blocks deep in the page survive a bucket-size change', () {
      final engine = _engine();
      // Deep page position: old and new cell coordinates diverge far
      // beyond the ±1-neighbor scan (y≈3000: cell 15 at 200px buckets
      // vs cell 25 at 120px buckets).
      DefaultTrackedBlock<void> deep() => DefaultTrackedBlock<void>(
            absoluteRect: const AbsoluteRect(Rect.fromLTWH(10, 3000, 200, 30)),
            payload: null,
            originalText: 'deep content',
          );
      engine.stabilize([deep()]);

      engine.updateViewport(viewportWidth: 1200, viewportHeight: 800);

      final r = engine.stabilize([deep()]);
      expect(r.stableBlocks.single.observationCount, 2,
          reason: 'without re-keying, the cached block is filed under '
              'stale cells and the re-observation spawns a duplicate');
    });
  });
}
