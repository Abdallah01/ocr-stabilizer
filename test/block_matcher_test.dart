// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #150: the matcher standing on its own — an index, a config, a counter
// set and a SpatialEvidence. Engine-level matching behaviour (band
// counters across captures, the dry pre-pass contract, nested merges)
// stays pinned by the stabilization_engine_band_*_test.dart files and the
// differential replay harness; these tests pin the class's own contract.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:ocr_stabilizer/src/band_fallback_stats.dart';
import 'package:ocr_stabilizer/src/internal/block_matcher.dart';
import 'package:test/test.dart';

DefaultTrackedBlock<Object> _block(
  String text, {
  double left = 10,
  double top = 100,
  double width = 200,
  double height = 30,
  int observationCount = 1,
}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, width, height),
      originalText: text,
      positionConfidence: const PositionConfidence(0.8),
      textConfidence: const TextConfidence(0.9),
      payload: const Object(),
      observationCount: observationCount,
    );

/// Always confirms — the band branch's text floors decide alone.
final class _AlwaysConfirms implements SpatialEvidence {
  const _AlwaysConfirms();
  @override
  bool confirms(Observation fresh, Observation candidate) => true;
}

BlockMatcher<DefaultTrackedBlock<Object>> _matcher(
  SpatialBlockIndex<DefaultTrackedBlock<Object>> index, {
  BandFallbackConfig band = const BandFallbackConfig(),
  SpatialEvidence evidence = const _AlwaysConfirms(),
  BandFallbackStatsInternal? stats,
}) =>
    BlockMatcher<DefaultTrackedBlock<Object>>(
      band: band,
      index: index,
      stats: stats ?? BandFallbackStatsInternal(),
      spatialEvidence: evidence,
      regionCandidates: (fresh) => index.allBlocks,
      driftTracker: DriftTracker(),
    );

void main() {
  group('BlockMatcher.find', () {
    test('primary: the highest-Levenshtein candidate over the floor wins', () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>();
      final close = _block('the quick brown fox jumps');
      final closer = _block('the quick brown fox jumped', top: 140);
      index
        ..add(close)
        ..add(closer);
      final out = _matcher(index).find(_block('the quick brown fox jumped'));
      expect(out.match, same(closer));
      expect(out.wasBandFallback, isFalse);
      expect(out.wasNestedFragment, isFalse);
    });

    test(
        'no candidate over the floor and band off → null, primary '
        'rejection counted', () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..add(_block('completely different words here'));
      final stats = BandFallbackStatsInternal();
      final out = _matcher(index, stats: stats).find(_block('nothing alike'));
      expect(out.match, isNull);
      expect(stats.primaryMatchesRejected, 1);
      expect(stats.candidatesConsidered, 0, reason: 'band off: no band scan');
    });

    test(
        'band admit: a weaker text match on an established, spatially '
        'confirmed candidate is admitted', () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..add(_block('paragraph one of the story text here',
            observationCount: 5));
      final stats = BandFallbackStatsInternal();
      final out = _matcher(
        index,
        band: const BandFallbackConfig(
            mode: BandFallbackMode.admit, bandLevenshteinFloor: 0.5),
        stats: stats,
      ).find(_block('paragraph one xx xxx xxxxx xxxx xxxx'));
      expect(out.match, isNotNull);
      expect(out.wasBandFallback, isTrue);
      expect(stats.matchesAdmitted, 1);
      expect(stats.bandMatchesIdentified, 1);
    });

    test(
        'band: a consumer predicate that throws surfaces as '
        'BandPredicateException', () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..add(_block('paragraph one of the story text here',
            observationCount: 5));
      final matcher = _matcher(
        index,
        band: const BandFallbackConfig(mode: BandFallbackMode.admit),
        evidence: ConsumerSpatialEvidence((_, __) => throw StateError('boom')),
      );
      expect(
        () => matcher.find(_block('paragraph one xx xxx xxxxx xxxx xxxx')),
        throwsA(isA<BandPredicateException>()
            .having((e) => e.cause, 'cause', isA<StateError>())),
      );
    });

    test(
        'nested: a line inside an established paragraph whose text it '
        'is a fragment of re-observes the paragraph', () {
      final paragraph = _block(
        'alpha beta gamma delta epsilon zeta eta theta iota kappa',
        top: 100,
        width: 300,
        height: 60,
      );
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..add(paragraph);
      final line =
          _block('epsilon zeta eta theta', top: 130, width: 280, height: 28);
      final out = _matcher(index).find(line);
      expect(out.match, same(paragraph));
      expect(out.wasNestedFragment, isTrue);
      expect(
          _matcher(index).find(line, allowNestedFallback: false).match, isNull,
          reason: 'the dry pre-pass skips the nested lookup');
    });

    test('recordStats: false leaves every counter untouched', () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..add(_block('some text'));
      final stats = BandFallbackStatsInternal();
      _matcher(index, stats: stats).find(_block('some text'),
          recordStats: false, allowBandFallback: false);
      expect(stats.primaryMatchesAdmitted, 0);
      expect(stats.primaryMatchesRejected, 0);
    });
  });
  group('#143 primary tie-break', () {
    // Default 200 px buckets (cell = round(centre / 200)): far centre
    // y = 490 → row 2, fresh y = 690 → row 3, near y = 710 → row 4. Both
    // candidates sit in the fresh block's 3×3 neighbourhood; identical
    // text makes their Levenshtein scores tie exactly.
    DefaultTrackedBlock<Object> far() =>
        _block('Chapter 4', left: 100, top: 480, height: 20);
    DefaultTrackedBlock<Object> near() =>
        _block('Chapter 4', left: 100, top: 700, height: 20);
    DefaultTrackedBlock<Object> fresh() =>
        _block('Chapter 4', left: 100, top: 680, height: 20);

    test(
        'an exact tie goes to the nearer candidate, whichever the index '
        'yields first', () {
      for (final order in [
        [far(), near()],
        [near(), far()],
      ]) {
        final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>();
        for (final b in order) {
          index.add(b);
        }
        final m = _matcher(index)..beginCapture([fresh()]);
        final out = m.find(fresh());
        expect(
            out.match, same(order.firstWhere((b) => b.absoluteRect.top == 700)),
            reason: 'insertion order ${order.map((b) => b.absoluteRect.top)}');
      }
    });

    test('a higher text score still beats a nearer candidate', () {
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>();
      final exact =
          _block('Chapter 4 - The River', left: 100, top: 480, height: 20);
      final off =
          _block('Chapter 4 - The Rivet', left: 100, top: 700, height: 20);
      index
        ..add(off)
        ..add(exact);
      final m = _matcher(index)..beginCapture([fresh()]);
      expect(
          m
              .find(_block('Chapter 4 - The River',
                  left: 100, top: 680, height: 20))
              .match,
          same(exact));
    });

    test(
        'the tie is measured against the DRIFT-CORRECTED fresh centre, '
        'from the snapshot beginCapture took', () {
      // A at y = 480, B at y = 700, fresh at y = 592: raw centre distances
      // 112 (A) vs 108 (B) → B. A learned drift of +15 px (fresh sits 15 px
      // below where its cached identity lies) corrects the fresh centre to
      // y = 587: 97 (A) vs 123 (B) → A. Three observations are needed
      // before the tracker reports a median, and 15 px stays under the
      // median-block-height clamp (20 px).
      final a = _block('Chapter 4', left: 100, top: 480, height: 20);
      final b = _block('Chapter 4', left: 100, top: 700, height: 20);
      final f = _block('Chapter 4', left: 100, top: 592, height: 20);
      final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>()
        ..add(b)
        ..add(a);
      final tracker = DriftTracker();
      final m = BlockMatcher<DefaultTrackedBlock<Object>>(
        band: const BandFallbackConfig(),
        index: index,
        stats: BandFallbackStatsInternal(),
        spatialEvidence: const _AlwaysConfirms(),
        regionCandidates: (fresh) => index.allBlocks,
        driftTracker: tracker,
      );
      m.beginCapture([f]);
      expect(m.find(f).match, same(b),
          reason: 'no drift learned yet: raw nearest');

      for (var i = 0; i < 3; i++) {
        tracker.addObservation(f, const Offset(0, 15), blockHeight: 20);
      }
      expect(m.find(f).match, same(b),
          reason: 'drift learned AFTER beginCapture must not change this '
              "capture's tie-break (the dry pre-pass and the real loop "
              'read one snapshot)');

      m.beginCapture([f]);
      expect(m.find(f).match, same(a),
          reason: 'next capture: drift-corrected nearest');
    });

    test(
        'at equal distance the smaller rect key wins, whichever the index '
        'yields first', () {
      // Fresh centre y = 690; `above` (top 660, centre 670) and `below`
      // (top 700, centre 710) are both 20 px away, so only the rect key
      // separates them.
      DefaultTrackedBlock<Object> above() =>
          _block('Chapter 4', left: 100, top: 660, height: 20);
      DefaultTrackedBlock<Object> below() =>
          _block('Chapter 4', left: 100, top: 700, height: 20);
      for (final order in [
        [above(), below()],
        [below(), above()],
      ]) {
        final index = SpatialBlockIndex<DefaultTrackedBlock<Object>>();
        for (final b in order) {
          index.add(b);
        }
        final m = _matcher(index)..beginCapture([fresh()]);
        expect(m.find(fresh()).match!.absoluteRect.top, 660,
            reason: 'insertion order ${order.map((b) => b.absoluteRect.top)}');
      }
    });
  });
}
