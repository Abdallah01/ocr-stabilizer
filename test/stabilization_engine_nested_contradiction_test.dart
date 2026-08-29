import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// NESTED RE-OBSERVATION × GROUPING CONTRADICTIONS (#112 × #49, PR #114)
// =============================================================================
// Two detectors look at the same capture: the grouping-contradiction
// detector (#49) flags a cached block that two or more fresh blocks
// SUBDIVIDE (each ≥ 30 % of its area, texts reassembling its text) and
// hands it to the consumer as eviction evidence; the nested re-observation
// rule (#112) treats a fresh block inside a cached block, with a fragment
// of its text, as a CONFIRMATION of it. On a paragraph split into its
// lines both fire at once — and the first draft confirmed the very block
// it had just reported as split, while dropping one of the two subdividers
// without a trace (the review's P1). Now a host flagged by the grouping
// detector in this call is withheld from nested absorption: the
// contradiction stands, and the fragments enter as new blocks, exactly as
// before 2.2.0.
//
// Also pinned here: the merger contract on a nested confirmation (the
// engine passes the HOST as `fresh`, so a 2.1-contract merger that copies
// pass-through fields from `fresh` cannot overwrite the paragraph's), and
// the carousel guard of the nested predicate.
// =============================================================================

({
  StabilizationEngine<DefaultTrackedBlock<void>, void> engine,
  SpatialBlockIndex<DefaultTrackedBlock<void>> index,
}) _engine({
  BlockMerger<DefaultTrackedBlock<void>, void>? merger,
}) {
  final index = SpatialBlockIndex<DefaultTrackedBlock<void>>();
  final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
    merger: merger ?? (existing, fresh, merge) => existing.applyMerge(merge),
    spatialIndex: index,
  );
  return (engine: engine, index: index);
}

DefaultTrackedBlock<void> _block(
  String text,
  Rect rect, {
  int observations = 1,
  bool carousel = false,
  int carouselIndex = -1,
}) =>
    DefaultTrackedBlock<void>(
      absoluteRect: AbsoluteRect(rect),
      payload: null,
      originalText: text,
      observationCount: observations,
      isHorizontalScrollChild: carousel,
      scrollContext: ScrollContext(hzScrollerIndex: carouselIndex),
    );

// The grouping detector's own positive-control fixture: a paragraph seen
// three times (its floor), and its two lines, each 40 % of its area.
const Rect kPara = Rect.fromLTWH(0, 0, 200, 100);
const Rect kLine1 = Rect.fromLTWH(0, 0, 200, 40);
const Rect kLine2 = Rect.fromLTWH(0, 50, 200, 40);

void main() {
  group('nested rule vs grouping contradiction (#112 × #49)', () {
    test('a host the grouping detector flags this call is NOT confirmed by '
        'its own lines — they enter as new blocks and the contradiction '
        'stands', () {
      final (:engine, :index) = _engine();
      final host = _block('hello world', kPara, observations: 3);
      index.add(host);

      final r = engine.stabilize([
        _block('hello', kLine1),
        _block('world', kLine2),
      ]);

      expect(r.contradictions, hasLength(1));
      expect(r.contradictions.single.type, ContradictionType.grouping);
      expect(identical(r.contradictions.single.target, host), isTrue);
      expect(r.stableBlocks.map((b) => b.originalText).toSet(),
          {'hello', 'world'},
          reason: 'both subdividers enter as new blocks — none is silently '
              'absorbed as a confirmation, none is dropped');
      expect(r.stableBlocks.every((b) => b.observationCount == 1), isTrue);
      expect(r.wellObservedTexts, isEmpty,
          reason: 'the host is not confirmed (it would have reached the '
              'well-observed threshold)');
    });

    test('control: a single line (no contradiction possible) still confirms '
        'the host as a nested fragment', () {
      final (:engine, :index) = _engine();
      index.add(_block('hello world', kPara, observations: 3));

      final r = engine.stabilize([_block('hello', kLine1)]);

      expect(r.contradictions, isEmpty);
      expect(r.stableBlocks.single.originalText, 'hello world');
      expect(r.stableBlocks.single.observationCount, 4);
    });
  });

  group('merger contract on a nested confirmation (#112)', () {
    test('the engine hands the HOST as `fresh`, so pass-through copying '
        'cannot overwrite it; a full merge still passes the observation',
        () {
      final seen = <({bool nested, bool hostAsFresh})>[];
      final (:engine, :index) = _engine(
        merger: (existing, fresh, merge) {
          seen.add((
            nested: merge.isNestedFragment,
            hostAsFresh: identical(fresh, existing),
          ));
          return existing.applyMerge(merge);
        },
      );
      index.add(_block('hello world', kPara, observations: 2));

      // Full merge: the same paragraph again.
      engine.stabilize([_block('hello world', kPara)]);
      // Nested confirmation: one line alone (obs 3 now, but a single line
      // cannot form a grouping contradiction).
      engine.stabilize([_block('hello', kLine1)]);

      expect(seen, [
        (nested: false, hostAsFresh: false),
        (nested: true, hostAsFresh: true),
      ]);
    });
  });

  group('nested predicate carousel guard (#112)', () {
    test('a line inside a paragraph from a DIFFERENT carousel is not its '
        'fragment; the same carousel is', () {
      final other = _engine();
      other.index.add(_block('hello world', kPara,
          observations: 2, carousel: true, carouselIndex: 0));
      final rOther = other.engine.stabilize(
          [_block('hello', kLine1, carousel: true, carouselIndex: 1)]);
      expect(rOther.stableBlocks.single.originalText, 'hello',
          reason: 'different carousel index → a new block, not a '
              'confirmation');
      expect(rOther.stableBlocks.single.observationCount, 1);

      final same = _engine();
      same.index.add(_block('hello world', kPara,
          observations: 2, carousel: true, carouselIndex: 0));
      final rSame = same.engine.stabilize(
          [_block('hello', kLine1, carousel: true, carouselIndex: 0)]);
      expect(rSame.stableBlocks.single.originalText, 'hello world');
      expect(rSame.stableBlocks.single.observationCount, 3);
    });
  });
}
