// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  group('SpaceKey.regionIndex', () {
    test('parses normal:<n> format', () {
      expect(SpaceKey.normal(7).regionIndex, equals(7));
    });

    test('parses unknown sentinel', () {
      expect(SpaceKey.unknown().regionIndex, equals(0));
    });

    test('parses ic:<container>:<n> format', () {
      expect(const SpaceKey('ic:sidebar:3').regionIndex, equals(3));
    });

    test('returns 0 on malformed key instead of throwing FormatException', () {
      // #1: A raw string whose last segment is not parseable as int must not
      // throw — return 0 as a safe fallback so callers don't crash on
      // forward-compatible format extensions or externally-constructed keys.
      expect(() => const SpaceKey('garbage').regionIndex, returnsNormally);
      expect(const SpaceKey('garbage').regionIndex, equals(0));
      expect(const SpaceKey('future:format:withletters:abc').regionIndex,
          equals(0));
    });
  });
}
