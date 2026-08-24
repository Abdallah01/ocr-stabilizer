// Dumps per-capture raw vs stabilized geometry for visualization (the
// README demo GIF). Replays a capture stream through the packaged engine
// with the same construction the ab-report agreement arm uses — the
// output is REAL engine behavior, not a mock-up.
//
// Usage: dart tool/replay/dump_frames.dart <capture.jsonl> <out.json>
import 'dart:convert';
import 'dart:io';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

import 'src/capture_stream.dart';
import 'src/replay_session.dart';

void main(List<String> args) {
  if (args.length != 2) {
    stderr.writeln('usage: dump_frames.dart <capture.jsonl> <out.json>');
    exit(64);
  }
  final stream = CaptureStream.parse(File(args[0]).readAsLinesSync());
  final engine = StabilizationEngine<ReplayBlock, Object>(
    positionMergeModel: PositionMergeModel.agreementWeighted,
    merger: (existing, fresh, m) => existing.applyMerge(m),
  );
  final frames = <Map<String, Object>>[];
  for (final batch in stream.batches) {
    final result = engine.stabilize(batch.blocks);
    Map<String, Object> enc(ReplayBlock b) => {
          'rect': [
            b.absoluteRect.raw.left,
            b.absoluteRect.raw.top,
            b.absoluteRect.raw.right,
            b.absoluteRect.raw.bottom,
          ],
          'text': b.originalText,
          'obs': b.observationCount,
        };
    frames.add({
      'cap': batch.captureId,
      'raw': [for (final b in batch.blocks) enc(b)],
      'stable': [for (final b in result.stableBlocks) enc(b)],
    });
  }
  File(args[1]).writeAsStringSync(const JsonEncoder.withIndent(' ')
      .convert({'source': args[0], 'frames': frames}));
  stdout.writeln('${frames.length} frames -> ${args[1]}');
}
