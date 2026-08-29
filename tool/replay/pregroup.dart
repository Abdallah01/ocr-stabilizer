// Pre-group a line-level capture stream into paragraph units, so the same
// captures can be replayed under both unit choices (see the dynamic-reflow
// entry's "Unit of identity" addendum and issue #101).
//
//   dart tool/replay/pregroup.dart <in.jsonl> <out.jsonl>
//       [--gap=10] [--mult=0.75] [--max-blocks=3] [--max-runes=200]
//
// The defaults are one consumer's translation-sized units. Pass the knobs a
// consumer actually uses to measure THAT consumer's identity unit.
import 'dart:io';

import 'src/pregroup.dart';

void main(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length != 2) {
    stderr.writeln('usage: pregroup.dart <in.jsonl> <out.jsonl> '
        '[--gap=10] [--mult=0.75] [--max-blocks=3] [--max-runes=200]');
    exit(2);
  }
  String? opt(String name) {
    final prefix = '--$name=';
    for (final a in args) {
      if (a.startsWith(prefix)) return a.substring(prefix.length);
    }
    return null;
  }

  final knobs = PregroupKnobs(
    lineGapThreshold: double.tryParse(opt('gap') ?? '') ?? 10.0,
    lineGapMultiplier: double.tryParse(opt('mult') ?? '') ?? 0.75,
    maxParagraphBlocks: int.tryParse(opt('max-blocks') ?? '') ?? 3,
    maxParagraphRunes: int.tryParse(opt('max-runes') ?? '') ?? 200,
  );
  final out = pregroupJsonl(
    File(positional[0]).readAsLinesSync(),
    knobs: knobs,
    summary: (s) => stdout.writeln(s),
  );
  File(positional[1]).writeAsStringSync('${out.join('\n')}\n');
}
