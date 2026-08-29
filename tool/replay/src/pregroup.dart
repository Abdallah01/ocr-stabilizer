// Pre-group a line-level capture stream into paragraph units — a consumer's
// "group BEFORE tracking" order — so the same captures can be replayed under
// both unit choices (issue #101's caveat: identity is only as stable as the
// unit the engine is given).
//
// Pure: takes the stream's JSON lines, returns new JSON lines. `meta` records
// pass through untouched; each `obs` record's blocks become one-line OcrBlocks,
// run through [ParagraphGrouper] at [knobs], and every group is emitted as ONE
// block — union rect, member texts joined with a space (the join a translation
// consumer makes), mean confidences, the first member's scroll context. `raw`
// becomes the unit count.
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
}

/// Counts for the caller's log line.
class PregroupSummary {
  const PregroupSummary(this.captures, this.linesIn, this.unitsOut);
  final int captures;
  final int linesIn;
  final int unitsOut;

  @override
  String toString() => 'captures=$captures lines=$linesIn units=$unitsOut';
}

/// Returns the pre-grouped stream as JSON lines. [summary] receives the counts.
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
  var captures = 0, linesIn = 0, unitsOut = 0;
  for (final line in lines) {
    if (line.trim().isEmpty) continue;
    final record = jsonDecode(line) as Map<String, dynamic>;
    if (record['t'] != 'obs') {
      out.add(line);
      continue;
    }
    final raw = (record['blocks'] as List).cast<Map<String, dynamic>>();
    // Index the source records by (text, top) so a grouped member maps back
    // to its confidences and scroll context.
    final byKey = <String, Map<String, dynamic>>{
      for (final b in raw)
        '${b['otext']}@${((b['rect'] as List)[1] as num).toDouble()}': b,
    };
    final blocks = <OcrBlock>[];
    for (final b in raw) {
      final r = (b['rect'] as List).cast<num>();
      final rect = Rect.fromLTWH(r[0].toDouble(), r[1].toDouble(),
          (r[2] - r[0]).toDouble(), (r[3] - r[1]).toDouble());
      final text = b['otext'] as String;
      blocks.add(OcrBlock(
        boundingBox: rect,
        text: text,
        lines: [
          OcrLine(
            boundingBox: rect,
            text: text,
            elements: [OcrElement(boundingBox: rect, text: text)],
          ),
        ],
        confidence: (b['tconf'] as num?)?.toDouble(),
      ));
    }
    final merged = <Map<String, dynamic>>[];
    for (final g in grouper.groupIntoParagraphs(blocks)) {
      final members = [
        for (final ob in g) byKey['${ob.text}@${ob.boundingBox.top}']!,
      ];
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
      merged.add({
        'rect': [l, t, rr, bb],
        'otext': g.map((ob) => ob.text).join(' '),
        'pconf': pconf / members.length,
        'tconf': tconf / members.length,
        'sc': members.first['sc'],
      });
    }
    captures++;
    linesIn += raw.length;
    unitsOut += merged.length;
    final copy = Map<String, dynamic>.from(record);
    copy['raw'] = merged.length;
    copy['blocks'] = merged;
    out.add(jsonEncode(copy));
  }
  summary?.call(PregroupSummary(captures, linesIn, unitsOut));
  return out;
}
