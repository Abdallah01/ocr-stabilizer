// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

// Dumps per-capture raw vs stabilized geometry for visualization (the
// README demo GIF). Replays a capture stream through the packaged engine
// with the same construction the ab-report agreement arm uses — the
// output is REAL engine behavior, not a mock-up.
//
// Usage: dart tool/replay/dump_frames.dart <capture.jsonl> <out.json>
//            [retention] [--viewport=WxH]
//
// [retention] (default 0) sets missedFrameRetention — pass a small window
// (e.g. 2) for streams where the engine's tracked state, not the
// per-capture stable set, is the thing being visualized.
//
// Viewport (2.1.0): the engine is configured with the stream's `meta.vp`
// (or the --viewport override) exactly as a real consumer configures it
// via `updateViewport`; without either, the dump runs on the 200 px
// default buckets and says so on stderr.
import 'dart:convert';
import 'dart:io';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

import 'src/capture_stream.dart';
import 'src/replay_session.dart';

void main(List<String> args) {
  final positional = <String>[];
  Viewport? viewportOverride;
  var bucketPolicy = BucketPolicy.auto;
  for (final a in args) {
    if (a.startsWith('--buckets')) {
      final p = bucketPolicyFromArg(a);
      if (p == null) {
        stderr.writeln('--buckets must be auto|formula|median (got: $a)');
        exit(64);
      }
      bucketPolicy = p;
    } else if (a.startsWith('--viewport')) {
      // Same constraint as meta.vp: finite, positive CSS px.
      final v = a.startsWith('--viewport=')
          ? viewportFromWxH(a.substring('--viewport='.length))
          : null;
      if (v == null) {
        stderr.writeln('--viewport must be WxH in finite positive CSS px, '
            'e.g. --viewport=360x587 (got: $a)');
        exit(64);
      }
      viewportOverride = v;
    } else {
      positional.add(a);
    }
  }
  if (positional.length < 2 || positional.length > 3) {
    stderr.writeln('usage: dump_frames.dart <capture.jsonl> <out.json> '
        '[retention] [--viewport=WxH]');
    exit(64);
  }
  final retention = positional.length == 3 ? int.tryParse(positional[2]) : 0;
  if (retention == null || retention < 0) {
    stderr.writeln('[retention] must be a non-negative integer '
        '(got: ${positional[2]})');
    exit(64);
  }
  final stream = CaptureStream.parse(File(positional[0]).readAsLinesSync());
  final engine = StabilizationEngine<ReplayBlock, Object>(
    positionMergeModel: PositionMergeModel.agreementWeighted,
    missedFrameRetention: retention,
    merger: (existing, fresh, m) => existing.applyMerge(m),
  );
  final viewport = viewportOverride ?? stream.viewport;
  if (viewport == null) {
    stderr.writeln('warning: no viewport (meta.vp absent and no '
        '--viewport=WxH) — dumping on the engine\'s 200 px default '
        'buckets, which is NOT production geometry');
  } else {
    engine.updateViewport(
      viewportWidth: viewport.width,
      viewportHeight: viewport.height,
    );
  }
  final frames = <Map<String, Object>>[];
  // Same bucket policy as replay() (2.2.0, #113): the stream's `bk` where
  // present (auto), or the reference consumer's median-height emulation.
  Buckets? current;
  final applied = <Buckets>[];
  void apply(Buckets b) {
    if (b == current) return;
    engine.updateBucketSizes(bucketWidth: b.width, bucketHeight: b.height);
    current = b;
    applied.add(b);
  }

  for (final batch in stream.batches) {
    switch (bucketPolicy) {
      case BucketPolicy.auto:
        if (batch.buckets != null) apply(batch.buckets!);
      case BucketPolicy.medianHeight:
        final m = medianHeightBuckets(engine.spatialIndex.allBlocks);
        if (m != null) apply(m);
      case BucketPolicy.viewportFormula:
        break;
    }
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
  File(positional[1]).writeAsStringSync(const JsonEncoder.withIndent(' ')
      .convert({
    'source': positional[0],
    'viewport': viewport == null
        ? null
        : {'width': viewport.width, 'height': viewport.height},
    'retention': retention,
    'bucketPolicy': bucketPolicy.name,
    'bucketsApplied': [
      for (final b in applied) {'width': b.width, 'height': b.height},
    ],
    'frames': frames,
  }));
  stdout.writeln('${frames.length} frames -> ${positional[1]}');
}
