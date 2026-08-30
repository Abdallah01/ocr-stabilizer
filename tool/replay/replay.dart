// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

// Replay rig for consumer-captured stabilization streams (#57 / #58).
//
//   dart tool/replay/replay.dart freeze-report <capture.jsonl> [--floor=N]
//   dart tool/replay/replay.dart ab-report     <capture.jsonl>
//   dart tool/replay/replay.dart live-report   <capture.jsonl>
//
// Options: --viewport=WxH (2.1.0) overrides the stream's `meta.vp`;
// --buckets=auto|formula|median (2.2.0, #113) picks the bucket policy —
// `auto` (default) applies the stream's `meta.bk` where present, `formula`
// is the 2.1.0 viewport formula only, `median` emulates the reference
// consumer's 2× median block height rule; --coherent-floor=N (#119,
// ab-report only) adds a fifth `agreementCoherentFloor` arm —
// `StepResponse.coherentShift` with the absolute-pixel floor enabled at
// N px; --coherent-reanchor=N (#119, ab-report only) likewise adds an
// `agreementCoherentReanchor` arm with the batch-level re-anchor enabled
// at cluster size N; --coherent-adopt (#119 item 2, ab-report only, no
// value) adds an `agreementCoherentAdopt` arm — coherentShift with the
// agreeing under-gate pairs adopted into a decided shift. All omitted by
// default (no extra arms).
//
// Output is a single JSON document on stdout (pipe to `jq`/a file).
// Schema contract: doc/replay/capture_schema.md.

import 'dart:convert';
import 'dart:io';

import 'src/ab_report.dart';
import 'src/capture_stream.dart';
import 'src/freeze_report.dart';
import 'src/lever_args.dart';
import 'src/live_report.dart';
import 'src/replay_session.dart' show BucketPolicy, bucketPolicyFromArg;

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln(
        'usage: dart tool/replay/replay.dart '
        '<freeze-report|ab-report|live-report> <capture.jsonl> [--floor=N]');
    exitCode = 64;
    return;
  }
  final command = args[0];
  final path = args[1];
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('no such file: $path');
    exitCode = 66;
    return;
  }

  // The two #119 levers, parsed strictly (a malformed value is an error,
  // never a silent skip — PR #129 review CONF2) and recognised wherever
  // they sit in argv.
  final levers = parseLeverArgs(args);
  if (levers.error != null) {
    stderr.writeln(levers.error);
    exitCode = 64;
    return;
  }
  final coherentFloorPx = levers.coherentFloorPx;
  final coherentReanchorMinBlocks = levers.coherentReanchorMinBlocks;
  final coherentAdoptAgreeing = levers.coherentAdoptAgreeing;

  int? floor;
  Viewport? viewportOverride;
  var bucketPolicy = BucketPolicy.auto;
  for (final a in args.skip(2)) {
    final m = RegExp(r'^--floor=(\d+)$').firstMatch(a);
    if (m != null) floor = int.parse(m.group(1)!);
    if (a.startsWith('--buckets')) {
      final p = bucketPolicyFromArg(a);
      if (p == null) {
        stderr.writeln('--buckets must be auto|formula|median (got: $a)');
        exitCode = 64;
        return;
      }
      bucketPolicy = p;
    }
    if (a.startsWith('--viewport')) {
      // Same constraint as meta.vp: finite, positive CSS px (PR #111
      // review — a zero viewport reached updateViewport before).
      final v = a.startsWith('--viewport=')
          ? viewportFromWxH(a.substring('--viewport='.length))
          : null;
      if (v == null) {
        stderr.writeln('--viewport must be WxH in finite positive CSS px, '
            'e.g. --viewport=360x587 (got: $a)');
        exitCode = 64;
        return;
      }
      viewportOverride = v;
    }
  }

  final stream = CaptureStream.parse(file.readAsLinesSync());
  if (stream.schemaVersion != null && stream.schemaVersion != 1) {
    stderr.writeln(
        'unsupported schema version ${stream.schemaVersion} (rig speaks v1)');
    exitCode = 65;
    return;
  }
  // 2.1.0 — never replay on default buckets silently: a real consumer
  // always calls updateViewport, so numbers reported without a viewport
  // are not production geometry.
  final viewport = viewportOverride ?? stream.viewport;
  if (viewport == null && command != 'live-report') {
    stderr.writeln('warning: no viewport (meta.vp absent and no '
        '--viewport=WxH) — replaying on the engine\'s 200 px default '
        'buckets, which is NOT production geometry');
  }

  final Map<String, Object?> report;
  switch (command) {
    case 'freeze-report':
      report = freezeReport(stream,
          candidateObservationFloor: floor,
          viewport: viewport,
          bucketPolicy: bucketPolicy);
    case 'ab-report':
      report = abReport(stream,
          viewport: viewport,
          bucketPolicy: bucketPolicy,
          coherentShiftFloorPx: coherentFloorPx,
          coherentShiftReanchorMinBlocks: coherentReanchorMinBlocks,
          coherentShiftAdoptAgreeing: coherentAdoptAgreeing);
    case 'live-report':
      report = liveReport(stream);
    default:
      stderr.writeln('unknown command: $command');
      exitCode = 64;
      return;
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
}
