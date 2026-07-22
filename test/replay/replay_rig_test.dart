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
