// ignore_for_file: avoid_print

import 'dart:ui';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

/// Minimal example: stabilize two batches of OCR observations using
/// [DefaultTrackedBlock] as the block implementation.
void main() {
  final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
    merger: (existing, fresh, merge) => existing.applyMerge(merge),
  );

  // First capture: two text blocks observed.
  final batch1 = [
    _block(text: 'Hello world', left: 10, top: 100, width: 200, height: 30),
    _block(text: 'Goodbye', left: 10, top: 150, width: 150, height: 30),
  ];
  final result1 = engine.stabilize(batch1);
  print('Capture 1: ${result1.stableBlocks.length} stable blocks');

  // Caller contract: rebuild the spatial index after each stabilize call
  // (see StabilizationEngine.stabilize docstring).
  for (final b in result1.stableBlocks) {
    engine.spatialIndex.add(b);
  }

  // Second capture: same text at slightly different positions (OCR jitter).
  final batch2 = [
    _block(text: 'Hello world', left: 12, top: 102, width: 200, height: 30),
    _block(text: 'Goodbye', left: 11, top: 149, width: 150, height: 30),
  ];
  final result2 = engine.stabilize(batch2);
  print('Capture 2: ${result2.stableBlocks.length} stable blocks');

  for (final block in result2.stableBlocks) {
    print(
      '  "${block.originalText}" at '
      '(${block.absoluteRect.left.toStringAsFixed(1)}, '
      '${block.absoluteRect.top.toStringAsFixed(1)}) '
      'observations=${block.observationCount}',
    );
  }
}

DefaultTrackedBlock<void> _block({
  required String text,
  required double left,
  required double top,
  required double width,
  required double height,
}) {
  return DefaultTrackedBlock<void>(
    absoluteRect: AbsoluteRect(Rect.fromLTWH(left, top, width, height)),
    payload: null,
    originalText: text,
  );
}
