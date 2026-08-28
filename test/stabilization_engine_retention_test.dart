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
  SpatialBlockIndex<DefaultTrackedBlock<void>>? index,
}) {
  return StabilizationEngine<DefaultTrackedBlock<void>, void>(
    merger: (existing, fresh, merge) => existing.applyMerge(merge),
    missedFrameRetention: retention,
    spatialIndex: index,
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
      // Since 2.0.0 (#96) external eviction goes through the INJECTED
      // index — engine.spatialIndex is read-only.
      final index = SpatialBlockIndex<DefaultTrackedBlock<void>>();
      final engine = _engine(retention: 2, index: index);
      final first = engine.stabilize([_hello()]).stableBlocks.single;
      engine.stabilize(const []); // miss 1 — retained

      // App-side eviction through the injected index.
      index.remove(first);
      engine.stabilize(const []); // block absent — its counter must drop

      // App-side re-insertion (e.g. an external cache restoring it).
      index.add(first);
      engine.stabilize(const []); // must count as miss 1, not miss 3
      engine.stabilize(const []); // miss 2 — still inside the window

      final r = engine.stabilize([_hello()]);
      expect(r.stableBlocks.single.observationCount, 2,
          reason: 'a stale pre-removal miss count would have expired the '
              'block early and reset its identity');
    });
  });

  // 2.1.0 — cross-frame supersession. Retention keeps an unmatched block
  // as a match candidate; it must NOT keep it when a fresh block this
  // capture now covers most of its region with different text (the region
  // has visibly changed, or the old box was placed in a lagged coordinate
  // frame). Without this, a consumer rendering the tracked state draws the
  // old box on top of the new one for the whole retention window.
  group('cross-frame supersession (2.1.0)', () {
    DefaultTrackedBlock<void> at(Rect r, String text) =>
        DefaultTrackedBlock<void>(
          absoluteRect: AbsoluteRect(r),
          payload: null,
          originalText: text,
        );

    test('a fresh block covering a retained block with other text evicts it',
        () {
      final engine = _engine(retention: 2);
      engine.stabilize([_hello()]); // hello world @ (10,100,200x30)
      final r = engine.stabilize([
        at(const Rect.fromLTWH(10, 100, 200, 30), 'completely unrelated'),
      ]);
      expect(r.stableBlocks.single.originalText, 'completely unrelated',
          reason: 'no text match: the fresh block is a new block');
      expect(engine.spatialIndex.allBlocks, hasLength(1),
          reason: 'the superseded block must not be retained');
      expect(engine.spatialIndex.allBlocks.single.originalText,
          'completely unrelated');

      final back = engine.stabilize([_hello()]);
      expect(back.stableBlocks.single.observationCount, 1,
          reason: 'identity of the evicted block is gone');
    });

    test('a fresh block elsewhere leaves the retained block alone', () {
      final engine = _engine(retention: 2);
      engine.stabilize([_hello()]);
      engine.stabilize([
        at(const Rect.fromLTWH(10, 400, 200, 30), 'completely unrelated'),
      ]);
      expect(engine.spatialIndex.allBlocks, hasLength(2),
          reason: 'no overlap: retention keeps the missed block');
    });

    test('a small fresh line inside a retained paragraph does not evict it',
        () {
      // Supersession is measured against the RETAINED block's area: a
      // re-segmentation frame that reports one line of a paragraph covers
      // little of the paragraph, so the paragraph keeps its identity.
      final engine = _engine(retention: 2);
      final paragraph = at(const Rect.fromLTWH(10, 100, 300, 120), 'para');
      engine.stabilize([paragraph]);
      engine.stabilize([
        at(const Rect.fromLTWH(10, 100, 300, 18), 'one line of it'),
      ]);
      expect(engine.spatialIndex.allBlocks, hasLength(2),
          reason: 'an 18 px line covers 15% of a 120 px paragraph');
    });

    test('retention 0 is unaffected (nothing is retained to evict)', () {
      final engine = _engine();
      engine.stabilize([_hello()]);
      engine.stabilize([
        at(const Rect.fromLTWH(10, 100, 200, 30), 'completely unrelated'),
      ]);
      expect(engine.spatialIndex.allBlocks, hasLength(1));
    });

    // Review fix batch (PR #111): the coverage floor is script-independent.
    // The resolver's per-script NMS threshold gives CJK-dominant text the
    // LOOSEST value (0.35); reusing it verbatim let a sliver covering 40%
    // of a CJK block evict it while an equal Latin block survived.
    test('a sliver covering 40% of a retained CJK block does not evict it',
        () {
      final engine = _engine(retention: 2);
      final cjk = at(const Rect.fromLTWH(10, 100, 200, 30), '这是一段中文正文');
      engine.stabilize([cjk]);
      engine.stabilize([
        // 200 px wide × 12 px tall inside the block: 2,400 of 6,000 px².
        at(const Rect.fromLTWH(10, 100, 200, 12), 'unrelated latin sliver'),
      ]);
      expect(engine.spatialIndex.allBlocks, hasLength(2),
          reason: '40% coverage is under the 50% floor, whatever the script');
    });

    test('a fresh block fully covering a retained CJK block evicts it', () {
      final engine = _engine(retention: 2);
      engine.stabilize([
        at(const Rect.fromLTWH(10, 100, 200, 30), '这是一段中文正文'),
      ]);
      engine.stabilize([
        at(const Rect.fromLTWH(10, 100, 200, 30), 'completely unrelated'),
      ]);
      expect(engine.spatialIndex.allBlocks, hasLength(1),
          reason: 'CJK is not immune — full coverage still supersedes');
    });

    // checkOverlap refuses to match blocks from different carousels; the
    // supersession test must refuse the same way.
    DefaultTrackedBlock<void> carousel(int index, String text) =>
        DefaultTrackedBlock<void>(
          absoluteRect: AbsoluteRect(const Rect.fromLTWH(10, 100, 200, 30)),
          payload: null,
          originalText: text,
          isHorizontalScrollChild: true,
          scrollContext: ScrollContext(
            scrollY: 0,
            scrollX: 0,
            hzScrollerIndex: index,
          ),
        );

    test('a block from another carousel never evicts a retained one', () {
      final engine = _engine(retention: 2);
      engine.stabilize([carousel(0, 'slide one caption')]);
      engine.stabilize([carousel(1, 'completely unrelated')]);
      expect(engine.spatialIndex.allBlocks, hasLength(2),
          reason: 'different carousels never overlap-match (checkOverlap '
              'rule) — the same must hold for supersession');
    });

    test('a block from the same carousel does evict a retained one', () {
      final engine = _engine(retention: 2);
      engine.stabilize([carousel(0, 'slide one caption')]);
      engine.stabilize([carousel(0, 'completely unrelated')]);
      expect(engine.spatialIndex.allBlocks, hasLength(1));
    });

    // The candidate search must span the FRESH block's whole rect, not the
    // 3×3 cells around its centre: a tall paragraph covers a small cached
    // block near its top edge whose cell is far from the paragraph's
    // centre cell.
    test('a tall fresh paragraph evicts a covered block near its far edge',
        () {
      final engine = _engine(retention: 2); // default 200 px buckets
      engine.stabilize([
        at(const Rect.fromLTWH(10, 55, 200, 20), 'hello world'), // centre y 65
      ]);
      engine.stabilize([
        // centre y 300: cells around it do not include the y≈65 cell.
        at(const Rect.fromLTWH(10, 50, 300, 500), 'an unrelated paragraph'),
      ]);
      expect(engine.spatialIndex.allBlocks, hasLength(1),
          reason: 'fully covered, so it must be superseded even though it '
              'sits outside the 3×3 neighbourhood of the paragraph centre');
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
