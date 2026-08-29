// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

// Unit tests for the pre-group transform (tool/replay/src/pregroup.dart):
// what a grouped unit carries, what passes through untouched, and what the
// summary surfaces. The dynamic-reflow corpus test pins the MEASUREMENT the
// transform enables; this file pins the transform itself.

import 'dart:convert';

import 'package:test/test.dart';

import '../../tool/replay/src/pregroup.dart';

/// One source block, the way a recorder writes it (rect = [l, t, r, b]).
Map<String, dynamic> block(
  String text,
  List<num> rect, {
  num pconf = 0.5,
  num tconf = 0.9,
  List<num>? sc,
  Map<String, dynamic> extra = const {},
}) =>
    {
      'rect': rect,
      'otext': text,
      'pconf': pconf,
      'tconf': tconf,
      'sc': sc ?? [0, 0, -1],
      ...extra,
    };

String obs(int cap, List<Map<String, dynamic>> blocks) => jsonEncode({
      't': 'obs',
      'ts': cap * 1000,
      'cap': cap,
      'raw': blocks.length,
      'blocks': blocks,
    });

const meta = '{"t":"meta","schema":1,"vp":"360x587","note":"fixture"}';

List<Map<String, dynamic>> blocksOf(String line) =>
    ((jsonDecode(line) as Map<String, dynamic>)['blocks'] as List)
        .cast<Map<String, dynamic>>();

void main() {
  group('pregroupJsonl', () {
    test('meta and event records pass through byte-identical; obs records '
        'get raw = unit count', () {
      const event = '{"t":"ev","kind":"scroll","ts":1500}';
      final out = pregroupJsonl([
        meta,
        obs(1, [
          block('first line', [10, 100, 300, 130]),
          block('second line', [10, 134, 300, 164]),
        ]),
        event,
      ]);
      expect(out, hasLength(3));
      expect(out[0], meta);
      expect(out[2], event);
      final rec = jsonDecode(out[1]) as Map<String, dynamic>;
      expect(rec['t'], 'obs');
      expect(rec['cap'], 1);
      expect(rec['raw'], 1, reason: 'two adjacent lines became one unit');
      expect(rec['blocks'], hasLength(1));
    });

    test('a grouped unit = union rect, texts joined with a space, mean '
        'confidences, the first member\'s scroll context', () {
      final out = pregroupJsonl([
        obs(1, [
          block('alpha', [10, 100, 280, 130],
              pconf: 0.2, tconf: 0.8, sc: [40, 0, -1]),
          block('beta', [12, 134, 300, 164],
              pconf: 0.6, tconf: 1.0, sc: [41, 0, -1]),
        ]),
      ]);
      final unit = blocksOf(out.single).single;
      expect(unit['rect'], [10, 100, 300, 164]);
      expect(unit['otext'], 'alpha beta');
      expect(unit['pconf'], closeTo(0.4, 1e-9));
      expect(unit['tconf'], closeTo(0.9, 1e-9));
      expect(unit['sc'], [40, 0, -1]);
      expect(unit.keys.toSet(), kCarriedBlockFields);
    });

    test('two blocks with the same text AND the same top keep their own '
        'rect, confidences and scroll context (PR #118 review: a value key '
        'collapsed them)', () {
      final out = pregroupJsonl([
        obs(1, [
          block('duplicate row text', [0, 100, 300, 130],
              pconf: 0.1, tconf: 0.5, sc: [1, 2, -1]),
          block('duplicate row text', [400, 100, 700, 130],
              pconf: 0.9, tconf: 0.95, sc: [9, 9, -1]),
        ]),
      ]);
      final units = blocksOf(out.single);
      expect(units, hasLength(2),
          reason: 'side-by-side blocks are inline peers, not one paragraph');
      final byLeft = {for (final u in units) (u['rect'] as List)[0]: u};
      expect(byLeft.keys, containsAll([0, 400]));
      expect(byLeft[0]!['pconf'], 0.1);
      expect(byLeft[0]!['sc'], [1, 2, -1]);
      expect(byLeft[400]!['pconf'], 0.9);
      expect(byLeft[400]!['sc'], [9, 9, -1]);
    });

    test('an obs record with no blocks stays an obs record with no units',
        () {
      final out = pregroupJsonl([obs(3, [])]);
      final rec = jsonDecode(out.single) as Map<String, dynamic>;
      expect(rec['raw'], 0);
      expect(rec['blocks'], isEmpty);
    });

    test('maxParagraphBlocks = 1 makes every line its own unit', () {
      final lines = [
        obs(1, [
          block('a', [10, 100, 300, 130]),
          block('b', [10, 134, 300, 164]),
          block('c', [10, 168, 300, 198]),
        ]),
      ];
      expect(blocksOf(pregroupJsonl(lines).single), hasLength(1));
      expect(
          blocksOf(pregroupJsonl(lines,
                  knobs: const PregroupKnobs(maxParagraphBlocks: 1))
              .single),
          hasLength(3));
    });

    test('summary counts captures, source lines and units', () {
      PregroupSummary? s;
      pregroupJsonl([
        meta,
        obs(1, [
          block('a', [10, 100, 300, 130]),
          block('b', [10, 134, 300, 164]),
        ]),
        obs(2, [block('c', [10, 100, 300, 130])]),
      ], summary: (x) => s = x);
      expect(s!.captures, 2);
      expect(s!.linesIn, 3);
      expect(s!.unitsOut, 2);
      expect(s!.problems, isEmpty);
      expect(s!.droppedFields, isEmpty);
      expect(s!.droppedFieldRecords, 0);
    });

    test('an obs record the transform cannot read is passed through '
        'UNCHANGED, counted with its line number, and the rest still group',
        () {
      final bad = jsonEncode({
        't': 'obs',
        'cap': 2,
        'raw': 1,
        'blocks': [
          {'rect': [10, 100, 300, 130], 'otext': 'no pconf', 'tconf': 0.9},
        ],
      });
      PregroupSummary? s;
      final out = pregroupJsonl([
        obs(1, [
          block('a', [10, 100, 300, 130]),
          block('b', [10, 134, 300, 164]),
        ]),
        '',
        bad,
        obs(3, [block('c', [10, 100, 300, 130])]),
      ], summary: (x) => s = x);
      expect(out, hasLength(3), reason: 'blank input line is skipped');
      expect(out[1], bad, reason: 'passed through byte-identical');
      expect(blocksOf(out[0]), hasLength(1));
      expect(blocksOf(out[2]), hasLength(1));
      expect(s!.captures, 2);
      expect(s!.problems, hasLength(1));
      expect(s!.problems.single, startsWith('line 3:'));
      expect(s!.problems.single, contains('passed through unchanged'));
    });

    test('a line that is not a JSON object is passed through and counted',
        () {
      PregroupSummary? s;
      final out = pregroupJsonl(['not json', obs(1, [])], summary: (x) => s = x);
      expect(out[0], 'not json');
      expect(s!.problems.single, startsWith('line 1: not a JSON object'));
    });

    test('block fields a grouped unit does not carry are reported by name '
        'and by record count', () {
      PregroupSummary? s;
      pregroupJsonl([
        obs(1, [
          block('a', [10, 100, 300, 130],
              extra: {'cid': 'main', 'obsN': 4, 'cvotes': {'10': 1}}),
          block('b', [10, 134, 300, 164], extra: {'cid': 'main'}),
        ]),
        obs(2, [block('c', [10, 100, 300, 130])]),
      ], summary: (x) => s = x);
      expect(s!.droppedFields, {'cid', 'obsN', 'cvotes'});
      expect(s!.droppedFieldRecords, 1,
          reason: 'per record, not per block; capture 2 carried nothing');
    });
  });
}
