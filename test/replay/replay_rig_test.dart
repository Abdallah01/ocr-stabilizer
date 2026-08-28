// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

// Rig tests over the committed fixture stream. The fixture is the
// cross-repo contract artifact: its field names mirror what the consumer's
// recorder emits (schema v1, doc/replay/capture_schema.md), so a loader
// change that breaks these tests would also break real captures.

import 'dart:io';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

import '../../tool/replay/src/ab_report.dart';
import '../../tool/replay/src/capture_stream.dart';
import '../../tool/replay/src/freeze_report.dart';
import '../../tool/replay/src/live_report.dart';
import '../../tool/replay/src/replay_session.dart';

CaptureStream loadFixture() => CaptureStream.parse(
    File('test/replay/fixtures/sample_stream.jsonl').readAsLinesSync());

void main() {
  group('loader', () {
    test('parses obs batches, events, and schema version', () {
      final s = loadFixture();
      expect(s.schemaVersion, 1);
      expect(s.batches, hasLength(8));
      expect(s.observationCount, 24,
          reason: 'chain block + two stationary drift anchors per batch');
      expect(s.events, hasLength(6));
      expect(s.skippedLines, 0);
      final b = s.batches.first.blocks.first;
      expect(b.originalText, 'hello world');
      expect(b.absoluteRect.raw.left, 0);
      expect(b.positionConfidence.raw, 0.5);
      expect(b.carouselIdVotes, {-1: 1},
          reason: 'absent carVotes must map to the phantom sentinel');
    });

    // 2.1.0 — the meta record may carry the producer's CSS viewport so the
    // rig can make the same updateViewport() call every real consumer
    // makes. Without it the engine's spatial index runs on its 200 px
    // default buckets, which is NOT production geometry (a 360 px phone
    // viewport buckets at 80x88 px) and changes which cached blocks are
    // match candidates.
    group('meta.vp (viewport, 2.1.0)', () {
      test('absent on the legacy fixture -> null', () {
        expect(loadFixture().viewport, isNull);
      });

      test('parses [width, height] CSS px', () {
        final s = CaptureStream.parse([
          '{"t":"meta","v":1,"ts":1,"note":"x","vp":[360,587]}',
        ]);
        expect(s.viewport, isNotNull);
        expect(s.viewport!.width, 360.0);
        expect(s.viewport!.height, 587.0);
        expect(s.invalidRecords, 0);
      });

      test('malformed vp is a recorder bug: counted, viewport null', () {
        for (final bad in [
          '{"t":"meta","v":1,"vp":"360x587"}',
          '{"t":"meta","v":1,"vp":[360]}',
          '{"t":"meta","v":1,"vp":[360,"tall"]}',
          '{"t":"meta","v":1,"vp":[0,587]}',
          '{"t":"meta","v":1,"vp":[360,-1]}',
        ]) {
          final s = CaptureStream.parse([bad]);
          expect(s.viewport, isNull, reason: bad);
          expect(s.invalidRecords, 1, reason: bad);
          expect(s.schemaVersion, 1,
              reason: 'a bad vp must not discard the version: $bad');
        }
      });
    });
  });

  group('--viewport=WxH parsing (2.1.0, PR #111 review)', () {
    test('accepts finite positive WxH, decimals allowed', () {
      expect(viewportFromWxH('360x587'), (width: 360.0, height: 587.0));
      expect(viewportFromWxH('360.5x587.25'), (width: 360.5, height: 587.25));
    });

    test('rejects malformed and non-positive values', () {
      // The CLI override must carry the same constraint as meta.vp: a zero
      // or negative viewport reached updateViewport before this fix.
      for (final bad in ['0x587', '360x0', '360x-1', '-1x587', 'abc',
          '360x', 'x587', '360', '360x587x1', '', ' 360x587']) {
        expect(viewportFromWxH(bad), isNull, reason: 'input: "$bad"');
      }
    });
  });

  group('replay() applies the stream viewport (2.1.0)', () {
    // PR #111 review (Copilot): a report must record the viewport that was
    // ACTUALLY applied. With no explicit viewport replay() falls back to
    // meta.vp, so recording the parameter alone would print null for a
    // replay that ran on production buckets.
    test('ab-report and freeze-report record the effective viewport', () {
      final stream = CaptureStream.parse(
          File('doc/replay/validation/2026-08-mlkit-on-device/dwell.jsonl')
              .readAsLinesSync());
      const header = {'width': 360.0, 'height': 587.0};
      expect((abReport(stream)['input'] as Map)['viewport'], header,
          reason: 'no parameter: the header viewport was applied, say so');
      expect((freezeReport(stream)['input'] as Map)['viewport'], header);
      expect(
          (abReport(stream, viewport: (width: 200, height: 200))['input']
              as Map)['viewport'],
          {'width': 200.0, 'height': 200.0},
          reason: 'an explicit viewport wins over the header and is recorded');
    });

    // The committed on-device dwell stream carries vp:[360,587] (read from
    // the recording WebView via CDP). Under production buckets two
    // long-distance text matches no longer find each other, so the merge
    // count is lower than under the 200 px default. This pins that the
    // header is HONOURED automatically, and that an explicit override wins.
    test('header viewport changes candidate geometry; override wins', () {
      final stream = CaptureStream.parse(
          File('doc/replay/validation/2026-08-mlkit-on-device/dwell.jsonl')
              .readAsLinesSync());
      expect(stream.viewport, isNotNull,
          reason: 'the committed on-device stream must carry vp');
      final auto = replay(stream).merges.length;
      final explicit =
          replay(stream, viewport: (width: 360, height: 587)).merges.length;
      final defaults = replay(stream, viewport: null, useStreamViewport: false)
          .merges
          .length;
      expect(auto, explicit, reason: 'header value honoured by default');
      expect(defaults, greaterThan(auto),
          reason: '200 px default buckets admit two extra long-distance '
              'text matches on this stream');
    });
  });

  group('freeze-report (#57)', () {
    test('band-admit replay measures freeze frequency, evidence, latency',
        () {
      final report = freezeReport(loadFixture());
      final freeze = report['freeze'] as Map<String, Object?>;
      final prov = report['provisional'] as Map<String, Object?>;

      // cap5 band-admits onto the 4-times-observed block; caps 6-8 all
      // merge onto the provisional chain and freeze; cap8 expires the
      // window (3 -> 0) and promotes.
      expect(freeze['frozenMerges'], 3);
      expect(freeze['totalMerges'], 21,
          reason: '3 chain merges (caps 2-4) + 1 admit + 3 frozen + '
              '2 anchors x 7 re-observations');
      expect(freeze['textDiffers'], 1,
          reason: 'only cap6 offers a text differing from the held vote');
      expect(freeze['highConfDiscardedVotes'], 1,
          reason: 'the cap6 discarded vote carries tconf 0.9');
      expect(prov['admissions'], 1);
      expect(prov['promoted'], 1);
      expect(prov['unresolved'], 0);
      final latency = prov['promotionLatencyCaptures'] as Map;
      expect(latency['p50'], 3, reason: 'admitted cap5, promoted cap8');
      final funnel = report['funnel'] as Map<String, Object?>;
      expect(funnel['matchesAdmitted'], greaterThanOrEqualTo(1));
    });
  });

  group('ab-report (#58)', () {
    test('agreementWeighted is positionally stickier than legacy on the '
        'same stream', () {
      final s = loadFixture();
      final legacy = replay(s);
      final agreement =
          replay(s, model: PositionMergeModel.agreementWeighted);

      expect(legacy.merges.length, agreement.merges.length,
          reason: 'arms must pair identically on this fixture for the '
              'displacement comparison to be meaningful');

      double sumDisp(ReplayResult r) => r.merges
          .fold(0.0, (sum, m) => sum + m.displacement);
      expect(sumDisp(agreement), lessThan(sumDisp(legacy)),
          reason: 'merge-weight decay must damp movement of '
              'well-observed blocks (#58)');

      // Legacy saturates position confidence (0.5 + 0.5 clamps to 1.0)
      // on the first re-observation; agreement-weighted keeps it
      // informative under the cap8 outlier.
      final legacyWell =
          legacy.merges.where((m) => m.obsNBefore >= 5).toList();
      expect(legacyWell.every((m) => m.pconfAfter >= 0.999), isTrue);
      final agreementWell =
          agreement.merges.where((m) => m.obsNBefore >= 5).toList();
      expect(agreementWell.any((m) => m.pconfAfter < 0.999), isTrue,
          reason: 'the cap8 6px outlier must reduce agreement-weighted '
              'confidence below saturation');
    });

    test('report shape carries both arms with bucketed displacement', () {
      final report = abReport(loadFixture());
      final legacy = report['legacy'] as Map<String, Object?>;
      expect(legacy['mergeCount'], isNonZero);
      expect(legacy['displacementByObsN'], isA<Map<String, Object?>>());
      expect(report['agreementWeighted'], isA<Map<String, Object?>>());
    });
  });

  group('loader hardening (review P1s)', () {
    test('malformed meta.v is skipped, not fatal', () {
      final s = CaptureStream.parse([
        '{"t":"meta","v":"not-a-number","ts":1}',
        '{"t":"obs","cap":1,"raw":0,"blocks":[]}',
      ]);
      expect(s.schemaVersion, isNull);
      expect(s.skippedLines, 1);
      expect(s.batches, hasLength(1));
    });

    test('non-string t is skipped and never reaches report code', () {
      final s = CaptureStream.parse([
        '{"t":42,"foo":"bar"}',
        '{"t":"freeze","cap":1,"differs":false,"freshTconf":0.5}',
      ]);
      expect(s.skippedLines, 1);
      expect(s.events, hasLength(1));
      // liveReport must not crash on the surviving stream.
      expect(liveReport(s)['mode'], 'live-report');
    });

    test('invariant-violating obs blocks count as invalidRecords, '
        'separate from line noise', () {
      final s = CaptureStream.parse([
        'not json at all',
        '{"t":"obs","cap":1,"raw":1,"blocks":['
            '{"rect":[0,0,50,20],"otext":"x","pconf":7.5,"tconf":0.5}]}',
      ]);
      expect(s.skippedLines, 1, reason: 'the non-JSON line');
      expect(s.invalidRecords, 1,
          reason: 'pconf 7.5 violates the confidence-range invariant');
      expect(s.batches, isEmpty);
    });

    test('latency join is rect-aware: recurring text across unrelated '
        'windows does not false-join', () {
      final s = CaptureStream.parse([
        '{"t":"band_stamp","cap":10,"fresh":{"otext":"dup","rect":[0,0,50,20]},'
            '"existing":{"otext":"other","rect":[0,10,50,30]}}',
        '{"t":"band_stamp","cap":50,"fresh":{"otext":"dup","rect":[0,500,50,520]},'
            '"existing":{"otext":"other2","rect":[0,510,50,530]}}',
        '{"t":"band_decrement","cap":52,"block":{"otext":"dup",'
            '"rect":[0,500,50,520]},"remaining":0,"expired":true,"inBatch":false}',
      ]);
      final lifecycle =
          liveReport(s)['provisionalLifecycle'] as Map<String, Object?>;
      final latency = lifecycle['promotionLatencyCaptures'] as Map;
      expect(latency['count'], 1);
      expect(latency['p50'], 2,
          reason: 'must join the cap-50 stamp at the same rect, '
              'not the cap-10 stamp 500px away (latency 42)');
      expect(lifecycle['unjoinedTerminals'], 0);
    });

    test('terminal with no stamp inside the join radius counts unjoined',
        () {
      final s = CaptureStream.parse([
        '{"t":"band_stamp","cap":10,"fresh":{"otext":"dup","rect":[0,0,50,20]},'
            '"existing":{"otext":"other","rect":[0,10,50,30]}}',
        '{"t":"band_decrement","cap":12,"block":{"otext":"dup",'
            '"rect":[0,900,50,920]},"remaining":0,"expired":true,"inBatch":false}',
      ]);
      final lifecycle =
          liveReport(s)['provisionalLifecycle'] as Map<String, Object?>;
      expect((lifecycle['promotionLatencyCaptures'] as Map)['count'], 0);
      expect(lifecycle['unjoinedTerminals'], 1);
    });
  });

  group('live-report (#57 consumer view)', () {
    test('aggregates lifecycle events and joins promotion latency', () {
      final report = liveReport(loadFixture());
      final freeze = report['freeze'] as Map<String, Object?>;
      final lifecycle =
          report['provisionalLifecycle'] as Map<String, Object?>;

      expect(freeze['frozenMerges'], 2);
      expect(freeze['merges'], 1);
      expect(freeze['textDiffers'], 1);
      expect(freeze['highConfDiscardedVotes'], 1);
      expect(lifecycle['bandStamps'], 1);
      expect(lifecycle['inlineExpiries'], 1);
      expect(lifecycle['clusterResolves'], 1);
      expect(lifecycle['evictedInResolution'], 1);
      final latency = lifecycle['promotionLatencyCaptures'] as Map;
      expect(latency['count'], 2,
          reason: 'expired decrement (alpha, 23-20=3) + cluster survivor '
              '(beta, 24-20=4) both join their band_stamp');
      expect(latency['p50'], anyOf(3, 4));
      expect(lifecycle['unjoinedTerminals'], 0);
    });
  });
}
