import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// CONTRADICTION DETECTORS: VR COORDINATE BOUNDARY (#49 / v0.6.0)
// =============================================================================
// Regression for the v0.5.0 audit finding §1.6: neither detector filtered
// on isViewportRelative, so near scroll offset 0 — where viewport and page
// coordinates numerically coincide — a well-observed sticky header could be
// reported as "subdivided" by unrelated normal blocks (grouping), and a
// fresh VR block could "subsume" cached normal blocks (splitting).
// =============================================================================

/// Engine plus its injected index: since 2.0.0 (#96) `engine.spatialIndex`
/// is read-only, so fixtures pre-seed through the injected instance they
/// constructed — the injector-owns-mutation pattern.
({
  StabilizationEngine<DefaultTrackedBlock<void>, void> engine,
  SpatialBlockIndex<DefaultTrackedBlock<void>> index,
}) _engine() {
  final index = SpatialBlockIndex<DefaultTrackedBlock<void>>();
  final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
    merger: (existing, fresh, merge) => existing.applyMerge(merge),
    spatialIndex: index,
  );
  return (engine: engine, index: index);
}

DefaultTrackedBlock<void> _block({
  required String text,
  required Rect rect,
  bool vr = false,
  int observations = 1,
}) {
  return DefaultTrackedBlock<void>(
    absoluteRect: AbsoluteRect(rect),
    payload: null,
    originalText: text,
    isViewportRelative: vr,
    observationCount: observations,
  );
}

void main() {
  group('detectGroupingContradictions VR guard (#49)', () {
    test('VR cached block is never reported as subdivided by normal blocks',
        () {
      final (:engine, :index) = _engine();
      // Well-observed sticky header at scroll offset 0: its viewport
      // coordinates numerically coincide with page coordinates.
      final vrHeader = _block(
        text: 'hello world',
        rect: const Rect.fromLTWH(0, 0, 200, 100),
        vr: true,
        observations: 3,
      );
      index.add(vrHeader);

      // Two normal fresh blocks that would "subdivide" it numerically.
      final events = engine.detectGroupingContradictions([
        _block(text: 'hello', rect: const Rect.fromLTWH(0, 0, 200, 40)),
        _block(text: 'world', rect: const Rect.fromLTWH(0, 50, 200, 40)),
      ]);

      expect(events, isEmpty);
    });

    test('positive control: normal cached block still detected', () {
      final (:engine, :index) = _engine();
      final cached = _block(
        text: 'hello world',
        rect: const Rect.fromLTWH(0, 0, 200, 100),
        observations: 3,
      );
      index.add(cached);

      final events = engine.detectGroupingContradictions([
        _block(text: 'hello', rect: const Rect.fromLTWH(0, 0, 200, 40)),
        _block(text: 'world', rect: const Rect.fromLTWH(0, 50, 200, 40)),
      ]);

      expect(events, hasLength(1));
      expect(events.single.type, ContradictionType.grouping);
      expect(identical(events.single.target, cached), isTrue);
      expect(events.single.evidence, hasLength(2));
    });
  });

  group('detectSplittingContradictions VR guard (#49)', () {
    test('fresh VR block never subsumes cached normal blocks', () {
      final (:engine, :index) = _engine();
      index.add(_block(
        text: 'hello',
        rect: const Rect.fromLTWH(0, 0, 200, 40),
        observations: 3,
      ));
      index.add(_block(
        text: 'world',
        rect: const Rect.fromLTWH(0, 50, 200, 40),
        observations: 3,
      ));

      final events = engine.detectSplittingContradictions([
        _block(
          text: 'hello world',
          rect: const Rect.fromLTWH(0, 0, 200, 100),
          vr: true,
        ),
      ]);

      expect(events, isEmpty);
    });

    test('positive control: normal fresh block still detected', () {
      final (:engine, :index) = _engine();
      final cachedA = _block(
        text: 'hello',
        rect: const Rect.fromLTWH(0, 0, 200, 40),
        observations: 3,
      );
      final cachedB = _block(
        text: 'world',
        rect: const Rect.fromLTWH(0, 50, 200, 40),
        observations: 3,
      );
      index.add(cachedA);
      index.add(cachedB);

      final fresh = _block(
        text: 'hello world',
        rect: const Rect.fromLTWH(0, 0, 200, 100),
      );
      final events = engine.detectSplittingContradictions([fresh]);

      expect(events, hasLength(1));
      expect(events.single.type, ContradictionType.splitting);
      expect(identical(events.single.target, fresh), isTrue);
      expect(events.single.evidence, hasLength(2));
    });
  });

  group('ContradictionEvent invariant (#51)', () {
    test('throws ArgumentError on fewer than 2 evidence blocks', () {
      expect(
        () => ContradictionEvent<String>(
          type: ContradictionType.grouping,
          target: 'target',
          evidence: const ['only-one'],
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('>= 2'),
        )),
      );
      expect(
        () => ContradictionEvent<String>(
          type: ContradictionType.splitting,
          target: 'target',
          evidence: const [],
        ),
        throwsArgumentError,
      );
    });

    test('accepts exactly 2 evidence blocks', () {
      final event = ContradictionEvent<String>(
        type: ContradictionType.grouping,
        target: 'target',
        evidence: const ['a', 'b'],
      );
      expect(event.evidence, hasLength(2));
    });
  });
}
