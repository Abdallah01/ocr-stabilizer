// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/overlap_resolver.dart';
import 'package:ocr_stabilizer/src/tracked_block.dart';
import 'package:ocr_stabilizer/src/types/confidence_types.dart';

/// Minimal `TrackedBlock` implementor that bypasses `DefaultTrackedBlock`'s
/// ctor throw. Lets us hand a NaN-confidence block directly to
/// `qualityScore` to exercise the debug assert.
///
/// `qualityScore` reads exactly two fields — `positionConfidence` and
/// `textConfidence` — so we use `noSuchMethod` to stub the rest of the
/// `TrackedBlock` surface without writing 20+ getter overrides.
class _NaNConfBlock implements TrackedBlock {
  _NaNConfBlock(
      {this.posIsNan = false,
      this.txtIsNan = false,
      this.posOutOfRange = false});
  final bool posIsNan;
  final bool txtIsNan;
  final bool posOutOfRange;

  @override
  PositionConfidence get positionConfidence {
    if (posIsNan) return const PositionConfidence(double.nan);
    if (posOutOfRange) return const PositionConfidence(1.5);
    return const PositionConfidence(0.5);
  }

  @override
  TextConfidence get textConfidence =>
      txtIsNan ? const TextConfidence(double.nan) : const TextConfidence(0.5);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError(
      '_NaNConfBlock fixture only stubs positionConfidence + textConfidence; '
      'qualityScore tried to read ${invocation.memberName}. '
      'If qualityScore now reads more fields, extend the fixture.');
}

void main() {
  group('OverlapResolver.qualityScore: NaN debug assert (#27)', () {
    // Note: Dart `assert` only fires in debug builds. Tests run in debug by
    // default; in release the assert is stripped and qualityScore returns
    // a poisoned NaN value. The production guard against that case is
    // engine-entry validation in StabilizationEngine.stabilize() (#27).
    // This assert is the developer-facing safety net.

    test('fires AssertionError on NaN positionConfidence via bare impl', () {
      final bad = _NaNConfBlock(posIsNan: true);
      expect(
        () => OverlapResolver.qualityScore(bad),
        throwsA(isA<AssertionError>()),
      );
    });

    test('fires AssertionError on NaN textConfidence via bare impl', () {
      final bad = _NaNConfBlock(txtIsNan: true);
      expect(
        () => OverlapResolver.qualityScore(bad),
        throwsA(isA<AssertionError>()),
      );
    });

    test(
        'fires AssertionError on out-of-range positionConfidence (1.5) via bare impl',
        () {
      final bad = _NaNConfBlock(posOutOfRange: true);
      expect(
        () => OverlapResolver.qualityScore(bad),
        throwsA(isA<AssertionError>()),
      );
    });

    test('returns finite score on valid confidence', () {
      final good = _NaNConfBlock();
      // pos=0.5, txt=0.5 → 0.5 * 0.4 + 0.5 * 0.6 = 0.5
      expect(OverlapResolver.qualityScore(good), closeTo(0.5, 1e-9));
    });
  });
}
