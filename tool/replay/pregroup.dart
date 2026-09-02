// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// Pre-group a line-level capture stream into paragraph units, so the same
// captures can be replayed under both unit choices (see the dynamic-reflow
// entry's "Unit of identity" addendum and issue #101).
//
//   dart tool/replay/pregroup.dart <in.jsonl> <out.jsonl>
//       [--gap=10] [--mult=0.75] [--max-blocks=3] [--max-runes=200]
//
// The defaults are one consumer's translation-sized units. Pass the knobs a
// consumer actually uses to measure THAT consumer's identity unit. The knobs
// applied are printed with the summary, so a report can be labelled from the
// run's own output; a malformed or unknown flag is an error (exit 64), never
// a silent fallback to a default.
//
// A grouped unit carries only rect / text / confidences / scroll context —
// engine-side per-block fields a recorder emits are dropped and reported on
// stderr (see src/pregroup.dart's header for the full limits).
import 'dart:io';

import 'src/pregroup.dart';

const _usage = 'usage: dart tool/replay/pregroup.dart <in.jsonl> <out.jsonl> '
    '[--gap=10] [--mult=0.75] [--max-blocks=3] [--max-runes=200]';

void main(List<String> args) {
  final positional = args.where((a) => !a.startsWith('--')).toList();
  if (positional.length != 2) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  final input = File(positional[0]);
  if (!input.existsSync()) {
    stderr.writeln('no such file: ${positional[0]}');
    exitCode = 66;
    return;
  }

  var gap = 10.0, mult = 0.75, blocks = 3, runes = 200;
  for (final a in args.where((a) => a.startsWith('--'))) {
    final eq = a.indexOf('=');
    final name = eq < 0 ? a.substring(2) : a.substring(2, eq);
    final value = eq < 0 ? '' : a.substring(eq + 1);
    // Same shape as replay.dart's flag checks: a bad value is a usage error
    // with the offending argument echoed, not a fallback (PR #118 review).
    switch (name) {
      case 'gap':
        final v = double.tryParse(value);
        if (v == null || !v.isFinite || v < 0) return _bad(a, 'a number >= 0');
        gap = v;
      case 'mult':
        final v = double.tryParse(value);
        if (v == null || !v.isFinite || v < 0) return _bad(a, 'a number >= 0');
        mult = v;
      case 'max-blocks':
        final v = int.tryParse(value);
        if (v == null || v < 1) return _bad(a, 'an integer >= 1');
        blocks = v;
      case 'max-runes':
        final v = int.tryParse(value);
        if (v == null || v < 1) return _bad(a, 'an integer >= 1');
        runes = v;
      default:
        stderr.writeln('unknown flag: $a');
        stderr.writeln(_usage);
        exitCode = 64;
        return;
    }
  }
  final knobs = PregroupKnobs(
    lineGapThreshold: gap,
    lineGapMultiplier: mult,
    maxParagraphBlocks: blocks,
    maxParagraphRunes: runes,
  );

  PregroupSummary? result;
  final out = pregroupJsonl(
    input.readAsLinesSync(),
    knobs: knobs,
    summary: (s) => result = s,
  );
  File(positional[1]).writeAsStringSync('${out.join('\n')}\n');
  final s = result!;
  stdout.writeln('knobs $knobs');
  stdout.writeln(s);
  for (final p in s.problems) {
    stderr.writeln('warning: $p');
  }
  if (s.droppedFields.isNotEmpty) {
    stderr.writeln('warning: ${s.droppedFieldRecords} obs record(s) carried '
        'block fields a grouped unit does not keep '
        '(${(s.droppedFields.toList()..sort()).join(', ')}); they reset to '
        'engine defaults in the grouped arm — check the comparison is still '
        'apples to apples');
  }
}

void _bad(String arg, String expected) {
  stderr.writeln('$arg: expected $expected');
  stderr.writeln(_usage);
  exitCode = 64;
}
