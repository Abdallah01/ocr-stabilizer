// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

// Replay rig for consumer-captured stabilization streams (#57 / #58).
//
//   dart tool/replay/replay.dart freeze-report <capture.jsonl> [--floor=N]
//   dart tool/replay/replay.dart ab-report     <capture.jsonl>
//   dart tool/replay/replay.dart live-report   <capture.jsonl>
//
// Output is a single JSON document on stdout (pipe to `jq`/a file).
// Schema contract: doc/replay/capture_schema.md.

import 'dart:convert';
import 'dart:io';

import 'src/ab_report.dart';
import 'src/capture_stream.dart';
import 'src/freeze_report.dart';
import 'src/live_report.dart';

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

  int? floor;
  for (final a in args.skip(2)) {
    final m = RegExp(r'^--floor=(\d+)$').firstMatch(a);
    if (m != null) floor = int.parse(m.group(1)!);
  }

  final stream = CaptureStream.parse(file.readAsLinesSync());
  if (stream.schemaVersion != null && stream.schemaVersion != 1) {
    stderr.writeln(
        'unsupported schema version ${stream.schemaVersion} (rig speaks v1)');
    exitCode = 65;
    return;
  }

  final Map<String, Object?> report;
  switch (command) {
    case 'freeze-report':
      report = freezeReport(stream, candidateObservationFloor: floor);
    case 'ab-report':
      report = abReport(stream);
    case 'live-report':
      report = liveReport(stream);
    default:
      stderr.writeln('unknown command: $command');
      exitCode = 64;
      return;
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
}
