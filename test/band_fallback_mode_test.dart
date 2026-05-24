// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';

void main() {
  group('BandFallbackMode (#20)', () {
    test('values are off, observeOnly, admit in that order', () {
      expect(BandFallbackMode.values, [
        BandFallbackMode.off,
        BandFallbackMode.observeOnly,
        BandFallbackMode.admit
      ]);
    });
  });
}
