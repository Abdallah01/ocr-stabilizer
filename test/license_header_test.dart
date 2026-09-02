// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #137 — `LICENSE` and the per-file SPDX headers must name the SAME license.
// Until 2.5.1 the root LICENSE was MIT (what pub.dev and GitHub display)
// while every source header said BSD-3-Clause (what a license scanner
// reads) — two licenses declared, only one true. This test derives the
// expected identifier from LICENSE's first line and checks every Dart
// file that ships or supports the package against it, so the two cannot
// drift apart again.
import 'dart:io';

import 'package:test/test.dart';

/// LICENSE first line → SPDX identifier. Extend when the license changes.
const _spdxByLicenseTitle = {
  'MIT License': 'MIT',
  'BSD 3-Clause License': 'BSD-3-Clause',
};

const _roots = ['lib', 'test', 'tool', 'example', 'benchmark'];

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
    for (final root in _roots) {
      final dir = Directory(root);
      if (!dir.existsSync()) continue;
      for (final f in dir.listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart')) continue;
        final head = f.readAsLinesSync().take(5).join('\n');
        final m = RegExp(r'SPDX-License-Identifier:\s*(\S+)').firstMatch(head);
        if (m == null) {
          missing.add(f.path);
        } else if (m.group(1) != expected) {
          offenders.add('${f.path}: ${m.group(1)}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: 'headers naming a different license than LICENSE');
    expect(missing, isEmpty,
        reason: 'Dart files without an SPDX identifier in their first 5 '
            'lines');
  });
}
