// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/tracked_block.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(String text,
        {required double left,
        required double top,
        double width = 50,
        double height = 20,
        int observationCount = 1}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, width, height),
      payload: const Object(),
      originalText: text,
      observationCount: observationCount,
    );

void main() {
  group(
      'StabilizationEngine band — predicate injection + default closure (#20)',
      () {
    test('custom spatialConfirm is invoked with (fresh, candidate)', () {
      final calls = <(String, String)>[];
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
          spatialConfirm: (TrackedBlock fresh, TrackedBlock candidate) {
            calls.add((fresh.originalText, candidate.originalText));
            return true; // accept all
          },
        ),
      );
      engine.stabilize(
          [_block('hello world', left: 0, top: 0, observationCount: 5)]);
      engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);

      expect(calls, isNotEmpty);
      // calls is a list of (fresh.originalText, candidate.originalText) tuples.
      expect(calls.first.$1, 'hxlxo wxrxd');
      expect(calls.first.$2, 'hello world');
    });

    test(
        'default closure: identical rect → predicate passes (overlapRatio = 1.0)',
        () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
          // spatialConfirm: null → engine uses default drift-aware closure
        ),
      );
      engine.stabilize(
          [_block('hello world', left: 0, top: 0, observationCount: 5)]);
      engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);

      expect(engine.bandStats.matchesAdmitted, 1,
          reason:
              'default closure accepts identical-rect overlap (1.0 >= 0.80)');
    });

    test(
        'default closure: non-overlapping rects → predicate rejects (or candidate filtered)',
        () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
        ),
      );
      engine.stabilize(
          [_block('hello world', left: 0, top: 0, observationCount: 5)]);
      // Fresh at far-away position — overlapRatio = 0.0. The spatial index
      // may filter the seed out before the band loop sees it (different cell);
      // if so, candidatesConsidered stays at 0. Either way, no admission.
      engine.stabilize([_block('hxlxo wxrxd', left: 5000, top: 5000)]);

      // Test the consequential outcome — no admission — rather than the
      // counter, since the spatial index's cell filter may or may not
      // surface the candidate.
      expect(engine.bandStats.matchesAdmitted, 0);
    });

    test(
        'throwing predicate is wrapped in BandPredicateException and surfaced — admit mode (#35 S1)',
        () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
          spatialConfirm: (TrackedBlock fresh, TrackedBlock candidate) {
            throw StateError('consumer-supplied predicate failed');
          },
        ),
      );
      engine.stabilize(
          [_block('hello world', left: 0, top: 0, observationCount: 5)]);
      expect(
        () => engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]),
        throwsA(isA<BandPredicateException>()
            .having((e) => e.cause, 'cause', isA<StateError>())
            .having((e) => e.predicateStackTrace, 'predicateStackTrace',
                isNot(same(StackTrace.empty)))
            .having(
                (e) => e.message, 'message', contains('BandPredicateException'))
            .having((e) => e.toString(), 'toString',
                contains('Predicate stack trace:'))),
        reason: 'engine must rewrap predicate throw, never swallow it; '
            'predicateStackTrace + message must carry through for logging',
      );
    });

    test(
        'throwing predicate is wrapped in BandPredicateException — observeOnly mode (#35 S1)',
        () {
      // observeOnly runs the band loop including spatialConfirm; if the
      // predicate throws, the engine must wrap and rethrow exactly as in
      // admit mode (the catch is mode-agnostic by construction).
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: BandFallbackConfig(
          mode: BandFallbackMode.observeOnly,
          candidateObservationFloor: 1,
          spatialConfirm: (TrackedBlock fresh, TrackedBlock candidate) {
            throw const FormatException('predicate boom (observeOnly)');
          },
        ),
      );
      engine.stabilize(
          [_block('hello world', left: 0, top: 0, observationCount: 5)]);
      expect(
        () => engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]),
        throwsA(isA<BandPredicateException>()
            .having((e) => e.cause, 'cause', isA<FormatException>())),
        reason:
            'observeOnly must surface predicate throws the same way admit does',
      );
    });
  });
}
