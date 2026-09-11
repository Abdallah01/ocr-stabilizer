// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// #150 differential harness CLI. Run from the package root.
//
//   dart tool/replay/differential.dart regenerate
//       Rewrites every committed `<stream>.diff.json` (kDifferentialStreams in
//       tool/replay/src/corpus.dart) from the CURRENT engine. Run this
//       ONLY when a behaviour change is intended and reviewed — the test
//       test/replay/differential_committed_test.dart exists to make an
//       unintended change red, and regenerating is how it is silenced.
//
//   dart tool/replay/differential.dart report <capture.jsonl>
//       Prints the differential report for one stream to stdout.
//
//   dart tool/replay/differential.dart dump <capture.jsonl> --arm=NAME --capture=ID
//       Prints the canonical JSON the hash of capture ID under arm NAME
//       was taken over. Run it on both checkouts and diff the two outputs
//       to see exactly which field moved.
//
// Options: --viewport=WxH and --buckets=auto|formula|median as in
// tool/replay/replay.dart. The committed files use the defaults.

import 'dart:convert';
import 'dart:io';

import 'src/capture_stream.dart';
import 'src/corpus.dart';
import 'src/differential.dart';
import 'src/replay_session.dart' show BucketPolicy, bucketPolicyFromArg;

const _usage = 'usage: dart tool/replay/differential.dart '
    '<regenerate | report <capture.jsonl> | '
    'dump <capture.jsonl> --arm=NAME --capture=ID> '
    '[--viewport=WxH] [--buckets=auto|formula|median]';

const _encoder = JsonEncoder.withIndent('  ');

void main(List<String> args) {
  if (args.isEmpty) {
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  Viewport? viewport;
  var bucketPolicy = BucketPolicy.auto;
  String? armName;
  int? captureId;
  final positional = <String>[];
  for (final a in args) {
    if (a.startsWith('--viewport=')) {
      final parts = a.substring('--viewport='.length).split('x');
      final w = parts.length == 2 ? double.tryParse(parts[0]) : null;
      final h = parts.length == 2 ? double.tryParse(parts[1]) : null;
      if (w == null || h == null) {
        stderr.writeln('malformed --viewport (want WxH): $a');
        exitCode = 64;
        return;
      }
      viewport = (width: w, height: h);
    } else if (a.startsWith('--buckets=')) {
      final p = bucketPolicyFromArg(a);
      if (p == null) {
        stderr.writeln('malformed --buckets: $a');
        exitCode = 64;
        return;
      }
      bucketPolicy = p;
    } else if (a.startsWith('--arm=')) {
      armName = a.substring('--arm='.length);
    } else if (a.startsWith('--capture=')) {
      captureId = int.tryParse(a.substring('--capture='.length));
      if (captureId == null) {
        stderr.writeln('malformed --capture (want an integer): $a');
        exitCode = 64;
        return;
      }
    } else if (a.startsWith('--')) {
      stderr.writeln('unknown option: $a');
      exitCode = 64;
      return;
    } else {
      positional.add(a);
    }
  }

  switch (positional) {
    case ['regenerate']:
      for (final base in kDifferentialStreams) {
        final stream = _read('$base.jsonl');
        if (stream == null) return;
        final report = differentialReport(stream,
            viewport: viewport, bucketPolicy: bucketPolicy);
        File('$base.diff.json').writeAsStringSync('${_encoder.convert(report)}\n');
        stdout.writeln('wrote $base.diff.json');
      }
    case ['report', final path]:
      final stream = _read(path);
      if (stream == null) return;
      stdout.writeln(_encoder.convert(differentialReport(stream,
          viewport: viewport, bucketPolicy: bucketPolicy)));
    case ['dump', final path]:
      if (armName == null || captureId == null) {
        stderr.writeln('dump needs --arm=NAME and --capture=ID');
        exitCode = 64;
        return;
      }
      final arm = kDifferentialArms.where((a) => a.name == armName).firstOrNull;
      if (arm == null) {
        stderr.writeln('unknown arm: $armName (known: '
            '${kDifferentialArms.map((a) => a.name).join(', ')})');
        exitCode = 64;
        return;
      }
      final stream = _read(path);
      if (stream == null) return;
      final canonical = captureCanonicalJsonFor(stream, arm, captureId,
          viewport: viewport, bucketPolicy: bucketPolicy);
      if (canonical == null) {
        stderr.writeln('no capture $captureId in $path');
        exitCode = 65;
        return;
      }
      // Re-indent for reading; the hash was taken over the compact form.
      stdout.writeln(_encoder.convert(jsonDecode(canonical)));
    default:
      stderr.writeln(_usage);
      exitCode = 64;
  }
}

CaptureStream? _read(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    stderr.writeln('no such file: $path');
    exitCode = 66;
    return null;
  }
  return CaptureStream.parse(file.readAsLinesSync());
}
