// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// Pre-group a line-level capture stream into paragraph units — a consumer's
// "group BEFORE tracking" order — so the same captures can be replayed under
// both unit choices (issue #101's caveat: identity is only as stable as the
// unit the engine is given).
//
// Pure: takes the stream's JSON lines, returns new JSON lines. `meta` and
// event records pass through untouched; each `obs` record's blocks become
// one-line OcrBlocks, run through [ParagraphGrouper] at [knobs], and every
// group is emitted as ONE block — union rect, member texts joined with a
// space (the join a translation consumer makes), mean confidences, the first
// member's scroll context. `raw` becomes the unit count.
//
// Limits, by design:
// * A grouped unit is a FRESH observation. Only `rect`, `otext`, `pconf`,
//   `tconf` and `sc` are carried; engine-side per-block fields a recorder may
//   emit (`cid`, `sf`, `srcQ`, `obsN`, `prov`, `cvotes`, ... — see
//   doc/replay/capture_schema.md) are dropped and reset to their defaults
//   downstream. [PregroupSummary.droppedFields] names what was dropped so the
//   caller can say whether the comparison is still apples to apples. The
//   dynamic-reflow corpora carry none of them.
// * An `obs` record the tool cannot transform (a block missing `pconf`, a
//   non-list `rect`, ...) is passed through UNCHANGED and counted in
//   [PregroupSummary.problems] — never dropped, so the downstream parser
//   sees the same record in both arms and rejects it the same way.
import 'dart:convert';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

/// The grouping knobs a consumer would use. The defaults are one consumer's
/// translation-sized units (three blocks / 200 runes per unit).
class PregroupKnobs {
  const PregroupKnobs({
    this.lineGapThreshold = 10.0,
    this.lineGapMultiplier = 0.75,
    this.maxParagraphBlocks = 3,
    this.maxParagraphRunes = 200,
  });

  final double lineGapThreshold;
  final double lineGapMultiplier;
  final int maxParagraphBlocks;
  final int maxParagraphRunes;

  @override
  String toString() => 'gap=$lineGapThreshold mult=$lineGapMultiplier '
      'blocks=$maxParagraphBlocks runes=$maxParagraphRunes';
}

/// The block fields a grouped unit carries. Everything else on a source
/// block is dropped (see the file header).
const Set<String> kCarriedBlockFields = {'rect', 'otext', 'pconf', 'tconf', 'sc'};

/// Counts for the caller's log line, plus everything the caller must
/// surface: records passed through untransformed and fields dropped.
class PregroupSummary {
  const PregroupSummary({
    required this.captures,
    required this.linesIn,
    required this.unitsOut,
    required this.problems,
    required this.droppedFields,
    required this.droppedFieldRecords,
  });

  /// `obs` records transformed.
  final int captures;

  /// Source blocks across the transformed records.
  final int linesIn;

  /// Grouped units emitted across the transformed records.
  final int unitsOut;

  /// One entry per `obs` record passed through unchanged, `line N: reason`
  /// (1-based over the input lines, blank lines skipped).
  final List<String> problems;

  /// Block fields seen on source blocks that a grouped unit does not carry.
  final Set<String> droppedFields;

  /// How many `obs` records had at least one such field.
  final int droppedFieldRecords;

  @override
  String toString() => 'captures=$captures lines=$linesIn units=$unitsOut '
      'passedThrough=${problems.length} '
      'droppedFieldRecords=$droppedFieldRecords';
}

/// Returns the pre-grouped stream as JSON lines. [summary] receives the
/// counts and the problems the caller must surface.
List<String> pregroupJsonl(
  List<String> lines, {
  PregroupKnobs knobs = const PregroupKnobs(),
  void Function(PregroupSummary summary)? summary,
}) {
  final grouper = ParagraphGrouper(
    lineGapThreshold: knobs.lineGapThreshold,
    lineGapMultiplier: knobs.lineGapMultiplier,
    maxParagraphBlocks: knobs.maxParagraphBlocks,
    maxParagraphRunes: knobs.maxParagraphRunes,
  );
  final out = <String>[];
  final problems = <String>[];
  final droppedFields = <String>{};
  var captures = 0, linesIn = 0, unitsOut = 0, droppedFieldRecords = 0;
  var lineNo = 0;
  for (final line in lines) {
    lineNo++;
    if (line.trim().isEmpty) continue;
    Map<String, dynamic> record;
    try {
      record = jsonDecode(line) as Map<String, dynamic>;
    } catch (e) {
      // Not even a JSON object: the parser will count it as skipped in
      // both arms. Pass it through so the arms stay symmetric.
      problems.add('line $lineNo: not a JSON object ($e)');
      out.add(line);
      continue;
    }
    if (record['t'] != 'obs') {
      out.add(line);
      continue;
    }
    final _Grouped grouped;
    try {
      grouped = _groupRecord(record, grouper);
    } catch (e) {
      // Surfaced, never dropped (file header). The downstream parser sees
      // the identical record in both arms.
      problems.add('line $lineNo: passed through unchanged ($e)');
      out.add(line);
      continue;
    }
    captures++;
    linesIn += grouped.sourceBlocks;
    unitsOut += grouped.units.length;
    if (grouped.droppedFields.isNotEmpty) {
      droppedFieldRecords++;
      droppedFields.addAll(grouped.droppedFields);
    }
    final copy = Map<String, dynamic>.from(record);
    copy['raw'] = grouped.units.length;
    copy['blocks'] = grouped.units;
    out.add(jsonEncode(copy));
  }
  summary?.call(PregroupSummary(
    captures: captures,
    linesIn: linesIn,
    unitsOut: unitsOut,
    problems: List.unmodifiable(problems),
    droppedFields: Set.unmodifiable(droppedFields),
    droppedFieldRecords: droppedFieldRecords,
  ));
  return out;
}

class _Grouped {
  const _Grouped(this.units, this.sourceBlocks, this.droppedFields);
  final List<Map<String, dynamic>> units;
  final int sourceBlocks;
  final Set<String> droppedFields;
}

_Grouped _groupRecord(Map<String, dynamic> record, ParagraphGrouper grouper) {
  final raw = (record['blocks'] as List).cast<Map<String, dynamic>>();
  final dropped = <String>{};
  // Each source record maps to the OcrBlock built from it BY IDENTITY.
  // The grouper hands back the very instances it was given for single-line
  // blocks (it only constructs new ones when splitting a multi-line block at
  // sentence punctuation, which one-line input never triggers), so two
  // blocks with the same text and top — a table row, a two-column layout —
  // still resolve to their own record. A value key would have collapsed
  // them (PR #118 review).
  final source = Map<OcrBlock, Map<String, dynamic>>.identity();
  final blocks = <OcrBlock>[];
  for (final b in raw) {
    for (final k in b.keys) {
      if (!kCarriedBlockFields.contains(k)) dropped.add(k);
    }
    final r = (b['rect'] as List).cast<num>();
    if (r.length != 4) {
      throw FormatException('rect must have 4 numbers, got ${r.length}');
    }
    // Validate up front what the grouped unit will read, so a bad block
    // fails this record before any of it is emitted.
    b['pconf'] as num;
    b['tconf'] as num;
    final rect = Rect.fromLTWH(r[0].toDouble(), r[1].toDouble(),
        (r[2] - r[0]).toDouble(), (r[3] - r[1]).toDouble());
    final text = b['otext'] as String;
    final block = OcrBlock(
      boundingBox: rect,
      text: text,
      lines: [
        OcrLine(
          boundingBox: rect,
          text: text,
          elements: [OcrElement(boundingBox: rect, text: text)],
        ),
      ],
      confidence: (b['tconf'] as num).toDouble(),
    );
    source[block] = b;
    blocks.add(block);
  }
  final units = <Map<String, dynamic>>[];
  for (final g in grouper.groupIntoParagraphs(blocks)) {
    final members = <Map<String, dynamic>>[];
    for (final ob in g) {
      final m = source[ob];
      if (m == null) {
        throw StateError(
            'grouper returned a block it was not given: "${ob.text}"');
      }
      members.add(m);
    }
    var l = double.infinity, t = double.infinity;
    var rr = double.negativeInfinity, bb = double.negativeInfinity;
    var pconf = 0.0, tconf = 0.0;
    for (final m in members) {
      final r = (m['rect'] as List).cast<num>();
      if (r[0] < l) l = r[0].toDouble();
      if (r[1] < t) t = r[1].toDouble();
      if (r[2] > rr) rr = r[2].toDouble();
      if (r[3] > bb) bb = r[3].toDouble();
      pconf += (m['pconf'] as num).toDouble();
      tconf += (m['tconf'] as num).toDouble();
    }
    units.add({
      'rect': [l, t, rr, bb],
      'otext': g.map((ob) => ob.text).join(' '),
      'pconf': pconf / members.length,
      'tconf': tconf / members.length,
      'sc': members.first['sc'],
    });
  }
  return _Grouped(units, raw.length, dropped);
}
