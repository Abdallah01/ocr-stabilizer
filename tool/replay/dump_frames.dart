// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

// Dumps per-capture raw vs stabilized geometry for visualization (the
// README demo GIF). Replays a capture stream through the packaged engine
// with the same construction the ab-report agreement arm uses — the
// output is REAL engine behavior, not a mock-up.
//
// Usage: dart tool/replay/dump_frames.dart <capture.jsonl> <out.json> [retention]
//
// [retention] (default 0) sets missedFrameRetention — pass a small window
// (e.g. 2) for streams where the engine's tracked state, not the
// per-capture stable set, is the thing being visualized.
import 'dart:convert';
import 'dart:io';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

import 'src/capture_stream.dart';
import 'src/replay_session.dart';

void main(List<String> args) {
  if (args.length < 2 || args.length > 3) {
    stderr.writeln(
        'usage: dump_frames.dart <capture.jsonl> <out.json> [retention]');
    exit(64);
  }
  final retention = args.length == 3 ? int.tryParse(args[2]) : 0;
  if (retention == null || retention < 0) {
    stderr.writeln('[retention] must be a non-negative integer '
        '(got: ${args[2]})');
    exit(64);
  }
  final stream = CaptureStream.parse(File(args[0]).readAsLinesSync());
  final engine = StabilizationEngine<ReplayBlock, Object>(
    positionMergeModel: PositionMergeModel.agreementWeighted,
    missedFrameRetention: retention,
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
      // The engine's full tracked state after this capture — what a
      // consumer's overlay actually renders from (stableBlocks alone is
      // only THIS capture's merged/new set and blinks when a block skips
      // a frame).
      'tracked': [for (final b in engine.spatialIndex.allBlocks) enc(b)],
    });
  }
  File(args[1]).writeAsStringSync(const JsonEncoder.withIndent(' ')
      .convert({'source': args[0], 'frames': frames}));
  stdout.writeln('${frames.length} frames -> ${args[1]}');
}
