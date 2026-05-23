// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

import 'package:flutter_test/flutter_test.dart';

import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';
import 'package:ocr_stabilizer/src/types/confidence_types.dart';

void main() {
  group('DefaultTrackedBlock constructor: Confidence invariants (#27)', () {
    final rect = AbsoluteRect.fromLTWH(0, 0, 10, 10);

    test('throws when positionConfidence.raw is NaN', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          positionConfidence: PositionConfidence(double.nan),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when textConfidence.raw is NaN', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          textConfidence: TextConfidence(double.nan),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when positionConfidence.raw is below 0.0', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          positionConfidence: const PositionConfidence(-0.1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when positionConfidence.raw is above 1.0', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          positionConfidence: const PositionConfidence(1.1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when textConfidence.raw is below 0.0', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          textConfidence: const TextConfidence(-0.1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('throws when textConfidence.raw is above 1.0', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          textConfidence: const TextConfidence(1.1),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('accepts 0.0 and 1.0 boundary values on both confidences', () {
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          positionConfidence: const PositionConfidence(0.0),
          textConfidence: const TextConfidence(0.0),
        ),
        returnsNormally,
      );
      expect(
        () => DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          positionConfidence: const PositionConfidence(1.0),
          textConfidence: const TextConfidence(1.0),
        ),
        returnsNormally,
      );
    });

    test('throw message names the offending field', () {
      try {
        DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          positionConfidence: PositionConfidence(double.nan),
        );
        fail('expected ArgumentError');
      } on ArgumentError catch (e) {
        expect(e.toString(), contains('positionConfidence'));
      }
    });

    test('throw message names textConfidence as the offending field', () {
      try {
        DefaultTrackedBlock<Object>(
          absoluteRect: rect,
          payload: const Object(),
          textConfidence: TextConfidence(double.nan),
        );
        fail('expected ArgumentError');
      } on ArgumentError catch (e) {
        expect(e.toString(), contains('textConfidence'));
      }
    });
  });
}
