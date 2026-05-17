// ignore_for_file: avoid_print

import 'dart:ui';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

/// Minimal example: stabilize two batches of OCR observations.
void main() {
  final engine = StabilizationEngine<_DemoBlock, void>(merger: _mergeBlocks);

  // First capture: two text blocks observed.
  final batch1 = [
    _DemoBlock(text: 'Hello world', left: 10, top: 100, width: 200, height: 30),
    _DemoBlock(text: 'Goodbye', left: 10, top: 150, width: 150, height: 30),
  ];
  final result1 = engine.stabilize(batch1);
  print('Capture 1: ${result1.stableBlocks.length} stable blocks');

  // Second capture: same text at slightly different positions (OCR jitter).
  final batch2 = [
    _DemoBlock(text: 'Hello world', left: 12, top: 102, width: 200, height: 30),
    _DemoBlock(text: 'Goodbye', left: 11, top: 149, width: 150, height: 30),
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

class _DemoBlock implements ObservableBlock<void> {
  @override
  final AbsoluteRect absoluteRect;
  @override
  final String originalText;
  @override
  final int observationCount;
  @override
  final PositionConfidence positionConfidence;
  @override
  final TextConfidence textConfidence;
  @override
  final Map<int, int> classificationVotes;
  @override
  final Map<int, int> carouselIdVotes;
  @override
  final Map<String, TextVote> textVotes;
  @override
  final bool isProvisional;
  @override
  final int provisionalCapturesRemaining;

  _DemoBlock({
    required String text,
    required double left,
    required double top,
    required double width,
    required double height,
    this.observationCount = 1,
    this.positionConfidence = PositionConfidence.groundTruth,
    this.textConfidence = TextConfidence.groundTruth,
    this.classificationVotes = const {},
    this.carouselIdVotes = const {-1: 1},
    this.textVotes = const {},
    this.isProvisional = false,
    this.provisionalCapturesRemaining = 0,
  }) : originalText = text,
       absoluteRect = AbsoluteRect(Rect.fromLTWH(left, top, width, height));

  @override
  ContainerId? get containerId => null;
  @override
  bool get isViewportRelative => false;
  @override
  bool get isInnerScrollerChild => false;
  @override
  bool get isHorizontalScrollChild => false;
  @override
  double get innerScrollerTop => 0;
  @override
  ScrollContext get scrollContext => ScrollContext.none;
  @override
  bool get isFromStickyElement => false;
  @override
  StickyFallback get stickyFallback => StickyFallback.none;
  @override
  int get sourceQuality => 0;
  @override
  int get groupSignature => 0;
  @override
  bool get needsReclassification => false;
  @override
  int get exclusionHitCount => 0;
  @override
  void get payload {}
}

_DemoBlock _mergeBlocks(
  _DemoBlock existing,
  _DemoBlock fresh,
  MergeResult merge,
) {
  return _DemoBlock(
    text: merge.winningOriginalText,
    left: merge.mergedRect.left,
    top: merge.mergedRect.top,
    width: merge.mergedRect.width,
    height: merge.mergedRect.height,
    observationCount: merge.observationCount,
    positionConfidence: merge.positionConfidence,
    textConfidence: merge.textConfidence,
    classificationVotes: merge.updatedClassificationVotes,
    carouselIdVotes: merge.updatedCarouselIdVotes,
    textVotes: merge.updatedTextVotes,
    isProvisional: merge.isProvisional,
    provisionalCapturesRemaining: merge.provisionalCapturesRemaining,
  );
}
