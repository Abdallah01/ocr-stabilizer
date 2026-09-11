// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #150: the vote accumulator standing on its own. Engine-level text
// promotion / classification / carousel behaviour stays pinned by the
// stabilization_engine_*_test.dart files and the differential harness;
// these pin the class's own contract.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:ocr_stabilizer/src/internal/vote_accumulator.dart';
import 'package:test/test.dart';

DefaultTrackedBlock<Object> _block(String text,
        {double tconf = 0.8,
        int sourceQuality = 0,
        Map<String, TextVote> textVotes = const {}}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(10, 100, 200, 30),
      originalText: text,
      positionConfidence: const PositionConfidence(0.8),
      textConfidence: TextConfidence(tconf),
      payload: const Object(),
      sourceQuality: sourceQuality,
      textVotes: textVotes,
    );

void main() {
  const votes = VoteAccumulator();

  group('VoteAccumulator.accumulate', () {
    test(
        'first merge seeds the existing text, then a higher-scoring '
        'variant is promoted', () {
      final existing = _block('hello wor1d', tconf: 0.5);
      final first = votes.accumulate(
          fresh: _block('hello world', tconf: 0.9), existing: existing);
      expect(first.textVotes.keys, hasLength(2));
      expect(first.textWasPromoted, isTrue);
      expect(first.winningText, 'hello world');
      expect(first.mergedTextConfidence, 0.9, reason: 'snaps on promotion');
    });

    test('same text blends the confidence and is not a promotion', () {
      final r = votes.accumulate(
          fresh: _block('hello', tconf: 0.6),
          existing: _block('hello', tconf: 0.8));
      expect(r.textWasPromoted, isFalse);
      expect(r.mergedTextConfidence, closeTo(0.8 * 4 / 7 + 0.6 * 3 / 7, 1e-9));
    });

    test(
        'the text-vote map is capped at maxTextVotes, dropping the '
        'lowest score', () {
      final seeded = {
        for (var i = 0; i < 5; i++)
          'k$i': TextVote(rawText: 'k$i', score: 1.0 + i, bestConfidence: 0.5),
      };
      final r = const VoteAccumulator(maxTextVotes: 5).accumulate(
          fresh: _block('brand new', tconf: 0.9),
          existing: _block('k4', textVotes: seeded));
      expect(r.textVotes, hasLength(5));
      expect(r.textVotes.containsKey('brandnew'), isFalse,
          reason: 'the newcomer (score 0.9) scores below every seeded entry '
              '(k0 = 1.0) and is the one dropped');
      expect(r.textVotes.keys, unorderedEquals(seeded.keys));
    });

    test(
        'carousel and source quality accumulate; classification vote '
        'flags a reclassification only when the majority moves', () {
      final r = votes.accumulate(
          fresh: _block('t', sourceQuality: 2), existing: _block('t'));
      expect(r.sourceQuality, 2);
      expect(r.carouselVotes.hasObservedCarousel, isFalse,
          reason: 'a page block votes -1: not a carousel');
      expect(r.carouselVotes.votes, {-1: 1});
      expect(r.needsReclassification, isFalse);
    });
  });
}
