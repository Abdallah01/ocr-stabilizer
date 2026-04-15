import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

void main() {
  group('OcrElement', () {
    test('const constructor stores boundingBox and text', () {
      const element = OcrElement(
        boundingBox: Rect.fromLTRB(10, 20, 30, 40),
        text: 'hello',
      );
      expect(element.boundingBox, const Rect.fromLTRB(10, 20, 30, 40));
      expect(element.text, 'hello');
    });
  });

  group('OcrLine', () {
    test('const constructor stores fields and elements list', () {
      const line = OcrLine(
        boundingBox: Rect.fromLTRB(0, 0, 200, 30),
        text: 'hello world',
        elements: [
          OcrElement(boundingBox: Rect.fromLTRB(0, 0, 80, 30), text: 'hello'),
          OcrElement(boundingBox: Rect.fromLTRB(90, 0, 200, 30), text: 'world'),
        ],
      );
      expect(line.boundingBox, const Rect.fromLTRB(0, 0, 200, 30));
      expect(line.text, 'hello world');
      expect(line.elements, hasLength(2));
      expect(line.elements[0].text, 'hello');
      expect(line.elements[1].text, 'world');
    });

    test('empty elements list is valid', () {
      const line = OcrLine(
        boundingBox: Rect.fromLTRB(0, 0, 100, 20),
        text: 'abc',
        elements: [],
      );
      expect(line.elements, isEmpty);
    });
  });

  group('OcrBlock', () {
    test('const constructor with all fields', () {
      final block = OcrBlock(
        boundingBox: Rect.fromLTRB(0, 0, 300, 100),
        text: '测试文本',
        confidence: 0.95,
        lines: [
          OcrLine(
            boundingBox: Rect.fromLTRB(0, 0, 300, 50),
            text: '测试',
            elements: [],
          ),
          OcrLine(
            boundingBox: Rect.fromLTRB(0, 50, 300, 100),
            text: '文本',
            elements: [],
          ),
        ],
      );
      expect(block.boundingBox, const Rect.fromLTRB(0, 0, 300, 100));
      expect(block.text, '测试文本');
      expect(block.confidence, 0.95);
      expect(block.lines, hasLength(2));
    });

    test('confidence defaults to null', () {
      final block = OcrBlock(
        boundingBox: Rect.fromLTRB(0, 0, 100, 50),
        text: 'abc',
        lines: [],
      );
      expect(block.confidence, isNull);
    });

    test('out-of-range confidence is clamped to [0.0, 1.0]', () {
      final above = OcrBlock(
        boundingBox: const Rect.fromLTRB(0, 0, 100, 50),
        text: 'abc',
        lines: const [],
        confidence: 1.5,
      );
      expect(above.confidence, 1.0);

      final below = OcrBlock(
        boundingBox: const Rect.fromLTRB(0, 0, 100, 50),
        text: 'abc',
        lines: const [],
        confidence: -0.3,
      );
      expect(below.confidence, 0.0);
    });

    test('empty lines list is valid (flat OCR engines)', () {
      final block = OcrBlock(
        boundingBox: Rect.fromLTRB(0, 0, 100, 50),
        text: 'flat text',
        lines: [],
      );
      expect(block.lines, isEmpty);
    });
  });
}
