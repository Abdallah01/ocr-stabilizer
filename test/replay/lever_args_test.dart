// PR #129 review CONF2: `replay.dart` matched its two #119 lever flags
// with value regexes, so a malformed value (`--coherent-floor=abc`, a
// missing `=`) simply never matched — the run went ahead with the lever
// OFF and printed a baseline-looking report. A typo must be an error.
import 'package:test/test.dart';

import '../../tool/replay/src/lever_args.dart';

void main() {
  test('well-formed levers parse to their values with no error', () {
    final r = parseLeverArgs(
        ['ab-report', 'x.jsonl', '--coherent-floor=390', '--coherent-reanchor=2']);
    expect(r.error, isNull);
    expect(r.coherentFloorPx, 390);
    expect(r.coherentReanchorMinBlocks, 2);
  });

  test('absent levers parse to null with no error', () {
    final r = parseLeverArgs(['ab-report', 'x.jsonl', '--buckets=auto']);
    expect(r.error, isNull);
    expect(r.coherentFloorPx, isNull);
    expect(r.coherentReanchorMinBlocks, isNull);
  });

  test('a malformed floor is an error, never a silent skip', () {
    for (final bad in [
      '--coherent-floor=abc',
      '--coherent-floor',
      '--coherent-floor=',
      '--coherent-floor=0',
      '--coherent-floor=-5',
      '--coherent-floor=NaN',
      '--coherent-floor=Infinity',
    ]) {
      final r = parseLeverArgs([bad]);
      expect(r.error, isNotNull, reason: bad);
      expect(r.error, contains(bad), reason: 'the message names the arg');
      expect(r.coherentFloorPx, isNull, reason: bad);
    }
  });

  test('a malformed re-anchor count is an error, never a silent skip', () {
    for (final bad in [
      '--coherent-reanchor=x',
      '--coherent-reanchor',
      '--coherent-reanchor=',
      '--coherent-reanchor=0',
      '--coherent-reanchor=1.5',
    ]) {
      final r = parseLeverArgs([bad]);
      expect(r.error, isNotNull, reason: bad);
      expect(r.coherentReanchorMinBlocks, isNull, reason: bad);
    }
  });

  test('a lever is recognised wherever it appears in argv', () {
    final r = parseLeverArgs(['--coherent-floor=390', 'ab-report', 'x.jsonl']);
    expect(r.error, isNull);
    expect(r.coherentFloorPx, 390);
  });
}
