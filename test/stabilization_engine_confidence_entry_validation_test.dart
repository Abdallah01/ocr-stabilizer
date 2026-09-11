// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/types/coordinate_context.dart';
import 'package:ocr_stabilizer/src/carousel_votes.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/track.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/text_vote.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';
import 'package:ocr_stabilizer/src/types/confidence_types.dart';
import 'package:ocr_stabilizer/src/types/container_id.dart';
import 'package:ocr_stabilizer/src/types/scroll_context.dart';
import 'package:ocr_stabilizer/src/types/sticky_fallback.dart';

/// A `Observation` implementor that bypasses [DefaultTrackedBlock] entirely.
/// Used to prove engine-entry validation catches non-`DefaultTrackedBlock`
/// implementors too, per spec §3 (Solution A).
class _BareTrackedBlock implements Track<Object> {
  // 3.0 (#147): the engine reads the frame through this one getter; the
  // flat fields below stay as this fixture's construction convenience.
  @override
  CoordinateContext get coordinates => CoordinateContext.fromFlags(
        isViewportRelative: isViewportRelative,
        isInnerScrollerChild: isInnerScrollerChild,
        innerScrollerTop: innerScrollerTop,
        isHorizontalScrollChild: isHorizontalScrollChild,
        containerId: containerId,
        scrollContext: scrollContext,
        isFromStickyElement: isFromStickyElement,
        stickyFallback: stickyFallback,
      );
  _BareTrackedBlock({
    required this.positionConfidence,
    required this.textConfidence,
  });

  @override
  final PositionConfidence positionConfidence;
  @override
  final TextConfidence textConfidence;

  @override
  AbsoluteRect get absoluteRect => AbsoluteRect.fromLTWH(0, 0, 10, 10);
  ContainerId? get containerId => null;
  bool get isViewportRelative => false;
  bool get isInnerScrollerChild => false;
  double get innerScrollerTop => 0;
  bool get isHorizontalScrollChild => false;
  @override
  Object get payload => const Object();
  @override
  String get originalText => 'hi';
  ScrollContext get scrollContext => ScrollContext.none;
  bool get isFromStickyElement => false;
  StickyFallback get stickyFallback => StickyFallback.none;
  @override
  int get sourceQuality => 0;
  @override
  int get observationCount => 1;
  @override
  Map<int, int> get classificationVotes => const {};
  @override
  CarouselVotes get carouselVotes => const CarouselVotes.none();
  @override
  Map<String, TextVote> get textVotes => const {};
  @override
  bool get isProvisional => false;
  @override
  int get provisionalCapturesRemaining => 0;
  @override
  int get groupSignature => 0;
  @override
  bool get needsReclassification => false;
  // hierarchyWeight is an extension method on Observation, not an interface
  // member — no @override here.
  int get hierarchyWeight => 0;
}

DefaultTrackedBlock<Object> _validBlock({String text = 'hi'}) {
  return DefaultTrackedBlock<Object>(
    absoluteRect: AbsoluteRect.fromLTWH(0, 0, 10, 10),
    payload: const Object(),
    originalText: text,
  );
}

void main() {
  group('StabilizationEngine.stabilize entry validation (#27)', () {
    test('throws when bare-impl observation has NaN positionConfidence', () {
      final bareEngine = StabilizationEngine<Track<Object>, Object>(
        merger: (existing, fresh, m) => existing,
      );
      final bad = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(double.nan),
        textConfidence: const TextConfidence(0.5),
      );
      expect(
        () => bareEngine.stabilize([bad]),
        throwsA(isA<ArgumentError>()
            .having(
                (e) => e.toString(), 'message', contains('positionConfidence'))
            .having((e) => e.toString(), 'message', contains('index 0'))),
      );
    });

    test('throws when bare-impl observation has NaN textConfidence', () {
      final bareEngine = StabilizationEngine<Track<Object>, Object>(
        merger: (existing, fresh, m) => existing,
      );
      final bad = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(0.5),
        textConfidence: const TextConfidence(double.nan),
      );
      expect(
        () => bareEngine.stabilize([bad]),
        throwsA(isA<ArgumentError>().having(
            (e) => e.toString(), 'message', contains('textConfidence'))),
      );
    });

    test('throws when bare-impl observation has out-of-range confidence', () {
      final bareEngine = StabilizationEngine<Track<Object>, Object>(
        merger: (existing, fresh, m) => existing,
      );
      final bad = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(1.1),
        textConfidence: const TextConfidence(0.5),
      );
      expect(
        () => bareEngine.stabilize([bad]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when bare-impl observation has infinite confidence', () {
      final bareEngine = StabilizationEngine<Track<Object>, Object>(
        merger: (existing, fresh, m) => existing,
      );
      // +Infinity > 1.0 -> caught by upper-bound check;
      // -Infinity < 0.0 -> caught by lower-bound check.
      // Locks both branches against accidental removal of the range bounds.
      final posInf = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(double.infinity),
        textConfidence: const TextConfidence(0.5),
      );
      expect(
          () => bareEngine.stabilize([posInf]), throwsA(isA<ArgumentError>()));

      final negInf = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(double.negativeInfinity),
        textConfidence: const TextConfidence(0.5),
      );
      expect(
          () => bareEngine.stabilize([negInf]), throwsA(isA<ArgumentError>()));
    });

    test('throw message names the offending observation index', () {
      final bareEngine = StabilizationEngine<Track<Object>, Object>(
        merger: (existing, fresh, m) => existing,
      );
      final good = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(0.5),
        textConfidence: const TextConfidence(0.5),
      );
      final bad = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(double.nan),
        textConfidence: const TextConfidence(0.5),
      );
      try {
        bareEngine.stabilize([good, bad]);
        fail('expected ArgumentError');
      } on ArgumentError catch (e) {
        expect(e.toString(), contains('index 1'));
      }
    });

    test('sanity: a valid observation list passes entry validation', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
      );
      expect(
        () => engine.stabilize([_validBlock(text: 'hi')]),
        returnsNormally,
      );
    });
  });

  group('StabilizationEngine.merge entry validation (#27 follow-up)', () {
    StabilizationEngine<Track<Object>, Object> bareEngine() {
      return StabilizationEngine<Track<Object>, Object>(
        merger: (existing, fresh, m) => existing,
      );
    }

    test('throws when merge() receives fresh with NaN positionConfidence', () {
      final engine = bareEngine();
      final bad = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(double.nan),
        textConfidence: const TextConfidence(0.5),
      );
      final good = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(0.5),
        textConfidence: const TextConfidence(0.5),
      );
      expect(
        () => engine.merge(bad, good),
        throwsA(isA<ArgumentError>()
            .having((e) => e.toString(), 'message', contains('fresh:'))
            .having((e) => e.toString(), 'message',
                contains('positionConfidence'))),
      );
    });

    test('throws when merge() receives existing with NaN textConfidence', () {
      final engine = bareEngine();
      final good = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(0.5),
        textConfidence: const TextConfidence(0.5),
      );
      final bad = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(0.5),
        textConfidence: const TextConfidence(double.nan),
      );
      expect(
        () => engine.merge(good, bad),
        throwsA(isA<ArgumentError>()
            .having((e) => e.toString(), 'message', contains('existing:'))
            .having(
                (e) => e.toString(), 'message', contains('textConfidence'))),
      );
    });

    test(
        'throws when merge() receives existing with out-of-range positionConfidence',
        () {
      final engine = bareEngine();
      final goodFresh = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(0.5),
        textConfidence: const TextConfidence(0.5),
      );
      final badExisting = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(1.1),
        textConfidence: const TextConfidence(0.5),
      );
      expect(
        () => engine.merge(goodFresh, badExisting),
        throwsA(isA<ArgumentError>()
            .having((e) => e.toString(), 'message', contains('existing:'))
            .having((e) => e.toString(), 'message',
                contains('positionConfidence'))),
      );
    });

    test('throws when merge() receives infinite confidence', () {
      final engine = bareEngine();
      final bad = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(double.infinity),
        textConfidence: const TextConfidence(0.5),
      );
      final good = _BareTrackedBlock(
        positionConfidence: const PositionConfidence(0.5),
        textConfidence: const TextConfidence(0.5),
      );
      expect(
        () => engine.merge(bad, good),
        throwsA(isA<ArgumentError>()
            .having((e) => e.toString(), 'message', contains('fresh:'))
            .having((e) => e.toString(), 'message',
                contains('positionConfidence'))),
      );
    });
  });
}
