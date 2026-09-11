// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #150 differential guard: every committed `<stream>.diff.json` holds one
// hash per capture per arm over the canonical JSON of that capture's
// engine state (see tool/replay/src/differential.dart). Replaying the
// corpus now and comparing hash by hash pins that a refactor of the
// engine changed NOTHING it returns or holds — not a rect, not a text
// winner, not a vote, not an event — on any capture of any stream under
// any of the nine arms.
//
// A red line names the stream, the arm and the FIRST capture that
// diverged (later captures usually diverge as a consequence). To see
// what moved, run on both checkouts:
//   dart tool/replay/differential.dart dump <stream>.jsonl --arm=<arm> --capture=<id>
// and diff the outputs. To accept an INTENDED change, regenerate:
//   dart tool/replay/differential.dart regenerate
// and commit the new files with the change that caused them.
import 'dart:convert';
import 'dart:io';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

import '../../tool/replay/src/capture_stream.dart';
import '../../tool/replay/src/corpus.dart';
import '../../tool/replay/src/differential.dart';

void main() {
  group('committed *.diff.json equivalence (#150)', () {
    for (final base in kCommittedStreams) {
      test(base, () {
        final stream =
            CaptureStream.parse(File('$base.jsonl').readAsLinesSync());
        final committed =
            jsonDecode(File('$base.diff.json').readAsStringSync())
                as Map<String, Object?>;
        final committedArms = committed['arms'] as Map<String, Object?>;

        final fresh = differentialReport(stream);
        final freshArms = fresh['arms'] as Map<String, Object?>;

        // Exact arm set, both ways: an arm added to the table and not
        // regenerated, or one dropped from the table, is a red line — not
        // an arm silently compared against nothing.
        expect(freshArms.keys.toList(), committedArms.keys.toList(),
            reason: '$base: the arm table (kDifferentialArms) and the '
                'committed .diff.json disagree on the arm set/order — '
                'regenerate after changing the table');

        for (final armName in freshArms.keys) {
          final freshArm = freshArms[armName] as Map<String, Object?>;
          final committedArm = committedArms[armName] as Map<String, Object?>;
          final freshCaptures = freshArm['captures'] as List;
          final committedCaptures = committedArm['captures'] as List;
          expect(freshCaptures.length, committedCaptures.length,
              reason: '$base/$armName: capture count differs from the '
                  'committed reference');
          for (var i = 0; i < freshCaptures.length; i++) {
            final f = freshCaptures[i] as Map;
            final c = committedCaptures[i] as Map;
            expect(f['capture'], c['capture'],
                reason: '$base/$armName: capture id at position $i differs');
            expect(f['hash'], c['hash'],
                reason: '$base/$armName: capture ${f['capture']} — the '
                    'engine state digest differs from the committed '
                    'reference (first divergence; dump both checkouts to '
                    'see which field moved)');
          }
          expect(freshArm['digest'], committedArm['digest'],
              reason: '$base/$armName: sequence digest differs');
        }
      });
    }
  });

  group('digest sensitivity', () {
    // The guard above is only as good as the digest's reach: a field the
    // digest does not read is a field a refactor can change unseen. These
    // pin that each class of state reaches the hash.
    final base = DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(10, 20, 100, 30),
      originalText: 'hello',
      positionConfidence: const PositionConfidence(0.5),
      textConfidence: const TextConfidence(0.9),
      payload: const Object(),
    );

    String digest(Track<Object> b) => fnv1a64Hex(jsonEncode(blockDigestMap(b)));

    test('a one-pixel rect move changes the block digest', () {
      final moved = base.copyWith(
          absoluteRect: AbsoluteRect.fromLTWH(11, 20, 100, 30));
      expect(digest(moved), isNot(digest(base)));
    });

    test('a text vote, a carousel vote and a provisional flag each change '
        'the block digest', () {
      final voted = base.copyWith(textVotes: {
        'hello': const TextVote(
            rawText: 'hello', score: 1.0, bestConfidence: 0.9),
      });
      final carousel = base.copyWith(
          carouselVotes: const CarouselVotes.none().record(2));
      final provisional =
          base.copyWith(isProvisional: true, provisionalCapturesRemaining: 3);
      final digests = {
        digest(base),
        digest(voted),
        digest(carousel),
        digest(provisional),
      };
      expect(digests, hasLength(4),
          reason: 'each state change must produce a distinct digest');
    });

    test('a coordinate context change changes the block digest', () {
      final viewport = base.copyWith(
          coordinates: const CoordinateContext.viewport());
      expect(digest(viewport), isNot(digest(base)));
    });

    test('the same state digests identically across two instances', () {
      final twin = DefaultTrackedBlock<Object>(
        absoluteRect: AbsoluteRect.fromLTWH(10, 20, 100, 30),
        originalText: 'hello',
        positionConfidence: const PositionConfidence(0.5),
        textConfidence: const TextConfidence(0.9),
        payload: const Object(),
      );
      expect(digest(twin), digest(base));
    });
  });

  group('fnv1a64Hex', () {
    test('matches the published FNV-1a 64 reference vectors', () {
      expect(fnv1a64Hex(''), 'cbf29ce484222325');
      expect(fnv1a64Hex('a'), 'af63dc4c8601ec8c');
      expect(fnv1a64Hex('foobar'), '85944171f73967e8');
    });
  });

  group('arm table', () {
    test('the first four arms are abReport()\'s default arms, in its order, '
        'so the digest covers what the committed .ab.json numbers came '
        'from', () {
      expect(kDifferentialArms.take(4).map((a) => a.name).toList(), [
        'legacy',
        'agreementWeighted',
        'agreementSnap',
        'agreementCoherent',
      ]);
    });

    test('arm names are unique', () {
      final names = kDifferentialArms.map((a) => a.name).toSet();
      expect(names, hasLength(kDifferentialArms.length));
    });
  });
}
