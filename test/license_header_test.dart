// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #137 — `LICENSE` and the per-file SPDX headers must name the SAME license.
// Until the #137 fix (shipped in 2.6.0) the root LICENSE was MIT (what pub.dev and GitHub display)
// while every source header said BSD-3-Clause (what a license scanner
// reads) — two licenses declared, only one true. This test derives the
// expected identifier from LICENSE's first line and checks every Dart
// file in the repository against it — a walk from the root that skips
// only tool caches and build output, not an allowlist of source roots,
// so a Dart file under a root added later (`bin/`, say) is checked the
// day it appears rather than silently exempt (PR #139 review).
import 'dart:io';

import 'package:test/test.dart';

/// LICENSE first line → SPDX identifier. Extend when the license changes.
const _spdxByLicenseTitle = {
  'MIT License': 'MIT',
  'BSD 3-Clause License': 'BSD-3-Clause',
};

/// Directories the walk never enters: tool caches, build output and
/// editor / agent state (the .gitignore + .pubignore set). Everything
/// else is walked, so a new source root needs no registration here.
const _skipDirs = {
  '.dart_tool',
  '.git',
  '.idea',
  '.vscode',
  '.claude',
  '.ultra',
  'build',
  'tmp',
};

Iterable<File> _dartFiles(Directory dir) sync* {
  for (final e in dir.listSync()) {
    final name = e.uri.pathSegments.lastWhere((s) => s.isNotEmpty);
    if (e is Directory) {
      if (!_skipDirs.contains(name)) yield* _dartFiles(e);
    } else if (e is File && name.endsWith('.dart')) {
      yield e;
    }
  }
}

void main() {
  final title = File('LICENSE').readAsLinesSync().first.trim();
  final expected = _spdxByLicenseTitle[title];

  test('LICENSE names a license this test knows how to map', () {
    expect(expected, isNotNull,
        reason: 'LICENSE starts with "$title" — add its SPDX identifier to '
            '_spdxByLicenseTitle');
  });

  test(
      'every Dart source file carries an SPDX identifier equal to '
      'LICENSE\'s ($expected)', () {
    final offenders = <String>[];
    final missing = <String>[];
    final files = _dartFiles(Directory.current).toList();
    // The walk found the package itself — an empty walk would pass
    // vacuously (wrong working directory, a broken skip set).
    expect(files.map((f) => f.path.replaceAll('\\', '/')),
        contains(endsWith('/lib/ocr_stabilizer.dart')));
    for (final f in files) {
      final head = f.readAsLinesSync().take(5).join('\n');
      final m = RegExp(r'SPDX-License-Identifier:\s*(\S+)').firstMatch(head);
      if (m == null) {
        missing.add(f.path);
      } else if (m.group(1) != expected) {
        offenders.add('${f.path}: ${m.group(1)}');
      }
    }
    expect(offenders, isEmpty,
        reason: 'headers naming a different license than LICENSE');
    expect(missing, isEmpty,
        reason: 'Dart files without an SPDX identifier in their first 5 '
            'lines');
  });
}
