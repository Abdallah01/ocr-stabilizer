import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  group('PositionConfidence', () {
    test('.from accepts values in [0, 1]', () {
      expect(PositionConfidence.from(0.0).raw, 0.0);
      expect(PositionConfidence.from(0.5).raw, 0.5);
      expect(PositionConfidence.from(1.0).raw, 1.0);
    });

    test('.from throws ArgumentError on out-of-range values', () {
      expect(() => PositionConfidence.from(-0.1), throwsArgumentError);
      expect(() => PositionConfidence.from(1.1), throwsArgumentError);
    });

    test('.from throws ArgumentError on NaN', () {
      expect(() => PositionConfidence.from(double.nan), throwsArgumentError);
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

    test('.from throws ArgumentError on out-of-range values', () {
      expect(() => TextConfidence.from(-0.1), throwsArgumentError);
      expect(() => TextConfidence.from(1.1), throwsArgumentError);
    });

    test('.from throws ArgumentError on NaN', () {
      expect(() => TextConfidence.from(double.nan), throwsArgumentError);
    });

    test('.groundTruth is 1.0', () {
      expect(TextConfidence.groundTruth.raw, 1.0);
    });
  });
}
