import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  group('PositionConfidence', () {
    test('.from accepts values in [0, 1]', () {
      expect(PositionConfidence.from(0.0).raw, 0.0);
      expect(PositionConfidence.from(0.5).raw, 0.5);
      expect(PositionConfidence.from(1.0).raw, 1.0);
    });

    test('.from rejects out-of-range values', () {
      expect(
        () => PositionConfidence.from(-0.1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => PositionConfidence.from(1.1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('.groundTruth is 1.0', () {
      expect(PositionConfidence.groundTruth.raw, 1.0);
    });
  });

  group('TextConfidence', () {
    test('.from accepts values in [0, 1]', () {
      expect(TextConfidence.from(0.0).raw, 0.0);
      expect(TextConfidence.from(0.5).raw, 0.5);
      expect(TextConfidence.from(1.0).raw, 1.0);
    });

    test('.from rejects out-of-range values', () {
      expect(
        () => TextConfidence.from(-0.1),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => TextConfidence.from(1.1),
        throwsA(isA<AssertionError>()),
      );
    });

    test('.groundTruth is 1.0', () {
      expect(TextConfidence.groundTruth.raw, 1.0);
    });
  });
}
