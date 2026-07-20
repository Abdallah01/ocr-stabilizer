import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// TEXT VOTE VALUE SEMANTICS (#53 / v0.6.0)
// =============================================================================

void main() {
  group('TextVote equality (#53)', () {
    test('equal fields compare equal with matching hashCodes', () {
      const a = TextVote(rawText: 'hello', score: 1.5, bestConfidence: 0.9);
      const b = TextVote(rawText: 'hello', score: 1.5, bestConfidence: 0.9);
      const c = TextVote(
        rawText: 'hello',
        score: 0.5 + 1.0,
        bestConfidence: 0.9,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, c);
    });

    test('each field participates in equality', () {
      const base = TextVote(rawText: 'hello', score: 1.5, bestConfidence: 0.9);
      expect(
        base,
        isNot(
            const TextVote(rawText: 'other', score: 1.5, bestConfidence: 0.9)),
      );
      expect(
        base,
        isNot(
            const TextVote(rawText: 'hello', score: 2.5, bestConfidence: 0.9)),
      );
      expect(
        base,
        isNot(
            const TextVote(rawText: 'hello', score: 1.5, bestConfidence: 0.1)),
      );
      expect(base, isNot('unrelated'));
    });

    test('toString names every field', () {
      const vote = TextVote(rawText: 'hi', score: 1.0, bestConfidence: 0.5);
      final s = vote.toString();
      expect(s, contains('hi'));
      expect(s, contains('1.0'));
      expect(s, contains('0.5'));
    });
  });
}
