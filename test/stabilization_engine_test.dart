// ignore_for_file: unused_element_parameter

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// TEST BLOCK STUB
// =============================================================================

class _TestBlock implements ObservableBlock<Never> {
  @override
  final AbsoluteRect absoluteRect;
  @override
  final ContainerId? containerId;
  @override
  final bool isViewportRelative;
  @override
  final bool isInnerScrollerChild;
  @override
  final bool isHorizontalScrollChild;
  @override
  final double innerScrollerTop;
  @override
  final String originalText;
  @override
  final bool isFromStickyElement;
  @override
  final double positionConfidence;
  @override
  final double textConfidence;
  @override
  final int sourceQuality;
  @override
  final int observationCount;
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
  @override
  final int groupSignature;
  @override
  final bool needsReclassification;
  @override
  final int exclusionHitCount;

  @override
  Never get payload => throw UnsupportedError('_TestBlock has no payload');

  final double captureScrollY;
  final double captureScrollX;
  final int hzScrollerIndex;
  final double stickyFallbackScrollY;
  final double stickyFallbackScrollX;
  final bool stickyFallbackIsIc;
  final int stickyFallbackHzIndex;

  _TestBlock({
    required this.absoluteRect,
    this.containerId,
    this.isViewportRelative = false,
    this.isInnerScrollerChild = false,
    this.isHorizontalScrollChild = false,
    this.innerScrollerTop = 0,
    this.originalText = '',
    this.isFromStickyElement = false,
    this.positionConfidence = 0.5,
    this.textConfidence = 0.5,
    this.sourceQuality = 0,
    this.observationCount = 1,
    this.classificationVotes = const {},
    this.carouselIdVotes = const {-1: 1},
    this.textVotes = const {},
    this.isProvisional = false,
    this.provisionalCapturesRemaining = 0,
    this.groupSignature = 0,
    this.needsReclassification = false,
    this.exclusionHitCount = 0,
    this.captureScrollY = 0,
    this.captureScrollX = 0,
    this.hzScrollerIndex = -1,
    this.stickyFallbackScrollY = 0,
    this.stickyFallbackScrollX = 0,
    this.stickyFallbackIsIc = false,
    this.stickyFallbackHzIndex = -1,
  });

  @override
  ScrollContext get scrollContext => ScrollContext(
    scrollY: captureScrollY,
    scrollX: captureScrollX,
    hzScrollerIndex: hzScrollerIndex,
  );

  @override
  StickyFallback get stickyFallback => StickyFallback(
    scrollY: stickyFallbackScrollY,
    scrollX: stickyFallbackScrollX,
    isIc: stickyFallbackIsIc,
    hzScrollerIndex: stickyFallbackHzIndex,
  );

  _TestBlock copyWith({
    AbsoluteRect? absoluteRect,
    String? originalText,
    double? positionConfidence,
    double? textConfidence,
    int? sourceQuality,
    int? observationCount,
    Map<int, int>? classificationVotes,
    Map<int, int>? carouselIdVotes,
    Map<String, TextVote>? textVotes,
    bool? isProvisional,
    int? provisionalCapturesRemaining,
    int? groupSignature,
    bool? needsReclassification,
    int? exclusionHitCount,
    bool? isViewportRelative,
    bool? isInnerScrollerChild,
    bool? isHorizontalScrollChild,
    double? innerScrollerTop,
    int? hzScrollerIndex,
  }) {
    return _TestBlock(
      absoluteRect: absoluteRect ?? this.absoluteRect,
      originalText: originalText ?? this.originalText,
      positionConfidence: positionConfidence ?? this.positionConfidence,
      textConfidence: textConfidence ?? this.textConfidence,
      sourceQuality: sourceQuality ?? this.sourceQuality,
      observationCount: observationCount ?? this.observationCount,
      classificationVotes: classificationVotes ?? this.classificationVotes,
      carouselIdVotes: carouselIdVotes ?? this.carouselIdVotes,
      textVotes: textVotes ?? this.textVotes,
      isProvisional: isProvisional ?? this.isProvisional,
      provisionalCapturesRemaining:
          provisionalCapturesRemaining ?? this.provisionalCapturesRemaining,
      groupSignature: groupSignature ?? this.groupSignature,
      needsReclassification:
          needsReclassification ?? this.needsReclassification,
      exclusionHitCount: exclusionHitCount ?? this.exclusionHitCount,
      isViewportRelative: isViewportRelative ?? this.isViewportRelative,
      isInnerScrollerChild: isInnerScrollerChild ?? this.isInnerScrollerChild,
      isHorizontalScrollChild:
          isHorizontalScrollChild ?? this.isHorizontalScrollChild,
      innerScrollerTop: innerScrollerTop ?? this.innerScrollerTop,
      containerId: containerId,
      isFromStickyElement: isFromStickyElement,
      captureScrollY: captureScrollY,
      captureScrollX: captureScrollX,
      hzScrollerIndex: hzScrollerIndex ?? this.hzScrollerIndex,
    );
  }
}

// =============================================================================
// MERGER
// =============================================================================

/// Test merger: applies MergeResult to _TestBlock via copyWith.
_TestBlock _testMerger(
  _TestBlock existing,
  _TestBlock fresh,
  MergeResult merge,
) {
  return existing.copyWith(
    absoluteRect: merge.mergedRect,
    positionConfidence: merge.positionConfidence,
    originalText: merge.winningOriginalText,
    textConfidence: merge.textConfidence,
    textVotes: merge.updatedTextVotes,
    classificationVotes: merge.updatedClassificationVotes,
    needsReclassification: merge.needsReclassification,
    carouselIdVotes: merge.updatedCarouselIdVotes,
    observationCount: merge.observationCount,
    isProvisional: merge.isProvisional,
    provisionalCapturesRemaining: merge.provisionalCapturesRemaining,
    sourceQuality: merge.sourceQuality,
  );
}

// =============================================================================
// HELPERS
// =============================================================================

_TestBlock _block({
  double top = 100,
  double left = 50,
  double width = 200,
  double height = 30,
  String text = '测试文本内容',
  double posConf = 0.5,
  double textConf = 0.5,
  int sourceQuality = 0,
  int observationCount = 1,
  bool isVR = false,
  bool isIC = false,
  bool isHz = false,
  int hzScrollerIndex = -1,
  Map<int, int>? classVotes,
  Map<int, int>? carouselVotes,
  Map<String, TextVote>? textVotes,
  bool isProvisional = false,
  int provisionalRemaining = 0,
  int groupSig = 0,
}) {
  return _TestBlock(
    absoluteRect: AbsoluteRect(Rect.fromLTWH(left, top, width, height)),
    originalText: text,
    positionConfidence: posConf,
    textConfidence: textConf,
    sourceQuality: sourceQuality,
    observationCount: observationCount,
    isViewportRelative: isVR,
    isInnerScrollerChild: isIC,
    isHorizontalScrollChild: isHz,
    hzScrollerIndex: hzScrollerIndex,
    classificationVotes: classVotes ?? {10: 1},
    carouselIdVotes: carouselVotes ?? {-1: 1},
    textVotes: textVotes ?? {},
    isProvisional: isProvisional,
    provisionalCapturesRemaining: provisionalRemaining,
    groupSignature: groupSig,
  );
}

StabilizationEngine<_TestBlock, Never> _createEngine({
  DriftTracker? driftTracker,
  SpatialBlockIndex<_TestBlock>? spatialIndex,
  bool Function(_TestBlock, _TestBlock)? contextualCheck,
}) {
  return StabilizationEngine<_TestBlock, Never>(
    merger: _testMerger,
    driftTracker: driftTracker,
    spatialIndex: spatialIndex,
    contextualCheck: contextualCheck,
  );
}

// =============================================================================
// TESTS
// =============================================================================

void main() {
  group('StabilizationEngine SAR merge', () {
    test('fresh block with no existing match returns as-is', () {
      final engine = _createEngine();
      final fresh = _block(text: '新内容');
      final result = engine.stabilize([fresh]);

      expect(result.stableBlocks, hasLength(1));
      expect(result.stableBlocks[0].originalText, '新内容');
      expect(result.stableBlocks[0].observationCount, 1);
    });

    test('fresh block matching existing merges position', () {
      final existing = _block(text: '测试文本内容', posConf: 0.5);
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);

      // Fresh block at slightly different position with same text
      final fresh = _block(text: '测试文本内容', top: 103, left: 52, posConf: 0.5);
      final result = engine.stabilize([fresh]);

      expect(result.stableBlocks, hasLength(1));
      final merged = result.stableBlocks[0];
      // Observation count incremented
      expect(merged.observationCount, 2);
      // Position is weighted average (both 0.5 confidence → 50/50)
      expect(merged.positionConfidence, 1.0); // min(0.5 + 0.5, 1.0)
    });

    test('text voting: winner is highest accumulated score', () {
      final existing = _block(
        text: '原始文本内容',
        textConf: 0.6,
        observationCount: 3,
        textVotes: {
          '原始文本内容': const TextVote(
            rawText: '原始文本内容',
            score: 1.8,
            bestConfidence: 0.6,
          ),
        },
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);

      // Fresh block with different text variant
      final fresh = _block(text: '原始文本内容改', textConf: 0.9);
      final result = engine.stabilize([fresh]);

      final merged = result.stableBlocks[0];
      // Original text stays because accumulated score (1.8) > fresh single obs (0.9)
      expect(merged.originalText, '原始文本内容');
    });

    test('text promotion triggers invalidation', () {
      // Existing with low-score text — identical spatial position
      // but slightly different OCR reading (common OCR variation)
      final existing = _block(
        text: '测试文本内容好',
        textConf: 0.3,
        observationCount: 1,
        textVotes: {},
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);

      // Fresh block at same position, similar text but higher confidence
      // on a different variant. Must be ≥70% Levenshtein similar to match.
      final fresh = _block(text: '测试文本内容好的', textConf: 0.95);
      final result = engine.stabilize([fresh]);

      // The fresh text should win (0.95 > 0.3 seeded)
      expect(result.stableBlocks[0].originalText, '测试文本内容好的');
      expect(result.invalidatedTexts, contains('测试文本内容好'));
    });

    test('source quality: higher tier wins', () {
      final existing = _block(text: '测试文本内容', sourceQuality: 1);
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);
      final fresh = _block(text: '测试文本内容', sourceQuality: 0);

      final result = engine.stabilize([fresh]);
      expect(result.stableBlocks[0].sourceQuality, 1); // LLM preserved
    });

    test('well-observed threshold triggers wellObservedTexts', () {
      final existing = _block(text: '测试文本内容', observationCount: 2);
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);
      final fresh = _block(text: '测试文本内容');

      final result = engine.stabilize([fresh]);
      expect(result.stableBlocks[0].observationCount, 3);
      expect(result.wellObservedTexts, isNotEmpty);
    });

    test('provisional block skips accumulation and decrements countdown', () {
      final existing = _block(
        text: '测试文本内容',
        isProvisional: true,
        provisionalRemaining: 3,
        observationCount: 1,
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);
      final fresh = _block(text: '测试文本内容', posConf: 0.9);

      final result = engine.stabilize([fresh]);
      final merged = result.stableBlocks[0];
      // Countdown decremented, but observation count NOT incremented
      expect(merged.provisionalCapturesRemaining, 2);
      expect(merged.observationCount, 1);
      expect(merged.isProvisional, true);
    });

    test('provisional block clears isProvisional when countdown reaches 0', () {
      final existing = _block(
        text: '测试文本内容',
        isProvisional: true,
        provisionalRemaining: 1,
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);
      final fresh = _block(text: '测试文本内容');

      final result = engine.stabilize([fresh]);
      final merged = result.stableBlocks[0];
      expect(merged.isProvisional, false);
      expect(merged.provisionalCapturesRemaining, 0);
    });

    test('classification vote accumulation tracks histogram', () {
      final existing = _block(
        text: '测试文本内容',
        classVotes: {10: 2}, // normal weight
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);
      // Fresh block classified as IC (weight 20)
      final fresh = _block(text: '测试文本内容', isIC: true);

      final result = engine.stabilize([fresh]);
      final merged = result.stableBlocks[0];
      // Votes: {10: 2, 20: 1} — normal still majority
      expect(merged.classificationVotes[10], 2);
      expect(merged.classificationVotes[20], 1);
      expect(merged.needsReclassification, false);
    });

    test('classification vote flip triggers needsReclassification', () {
      final existing = _block(
        text: '测试文本内容',
        classVotes: {10: 1, 20: 2}, // IC majority
        isIC: true,
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);
      final fresh = _block(text: '测试文本内容', isIC: true);

      final result = engine.stabilize([fresh]);
      final merged = result.stableBlocks[0];
      // Votes: {10: 1, 20: 3} — IC majority confirmed
      expect(merged.classificationVotes[20], 3);
      // existing hierarchyWeight was computed from IC flags (20), majority is also 20
      // so needsReclass should be false (majority matches existing)
      expect(merged.needsReclassification, false);
    });

    test('contextual check triggers invalidation on context change', () {
      final existing = _block(text: '测试文本内容', groupSig: 100);
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(
        spatialIndex: spatialIndex,
        contextualCheck: (fresh, existing) =>
            fresh.groupSignature != existing.groupSignature,
      );

      final fresh = _block(text: '测试文本内容', groupSig: 200);
      final result = engine.stabilize([fresh]);

      expect(result.invalidatedTexts, contains('测试文本内容'));
    });

    test('carousel vote clears phantom -1 on first real observation', () {
      final existing = _block(
        text: '测试文本内容',
        carouselVotes: {-1: 1},
        isHz: true,
        hzScrollerIndex: 2,
      );
      // Re-create with proper hzScrollerIndex
      final existingWithHz = _TestBlock(
        absoluteRect: existing.absoluteRect,
        originalText: existing.originalText,
        isHorizontalScrollChild: true,
        hzScrollerIndex: -1, // was non-carousel initially
        carouselIdVotes: {-1: 1},
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existingWithHz);

      final engine = _createEngine(spatialIndex: spatialIndex);
      final fresh = _TestBlock(
        absoluteRect: existingWithHz.absoluteRect,
        originalText: existingWithHz.originalText,
        isHorizontalScrollChild: true,
        hzScrollerIndex: 2,
      );

      final result = engine.stabilize([fresh]);
      final merged = result.stableBlocks[0];
      // Phantom -1 cleared, replaced with carousel 2
      expect(merged.carouselIdVotes.containsKey(-1), false);
      expect(merged.carouselIdVotes[2], 1);
    });

    test('text votes bounded to 5 entries', () {
      // Create existing with 5 different text variants in votes
      final votes = <String, TextVote>{};
      for (var i = 0; i < 5; i++) {
        final key = '变体$i';
        votes[key] = TextVote(rawText: key, score: 1.0, bestConfidence: 0.5);
      }
      final existing = _block(
        text: '变体0',
        textVotes: votes,
        observationCount: 5,
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);
      // Fresh with a 6th variant
      final fresh = _block(text: '变体5新', textConf: 0.3);

      final result = engine.stabilize([fresh]);
      final merged = result.stableBlocks[0];
      // Should still have at most 5 entries (lowest score evicted)
      expect(merged.textVotes.length, lessThanOrEqualTo(5));
    });

    test(
      'drift correction shifts merged position toward corrected coordinate',
      () {
        final driftTracker = DriftTracker();
        final spatialIndex = SpatialBlockIndex<_TestBlock>();

        // Existing block at (100, 50)
        final existing = _block(text: '测试文本内容', top: 100, left: 50);
        spatialIndex.add(existing);

        // Seed consistent drift so median is non-zero (need ≥3 observations)
        for (var i = 0; i < 5; i++) {
          driftTracker.addObservation(
            _block(text: '其他', top: 100),
            const Offset(10.0, 5.0),
            blockHeight: 30.0,
          );
        }

        final engine = _createEngine(
          driftTracker: driftTracker,
          spatialIndex: spatialIndex,
        );

        // Fresh at (105, 55) — drift should correct this before averaging
        final fresh = _block(text: '测试文本内容', top: 105, left: 55, posConf: 0.5);
        final result = engine.stabilize([fresh]);

        final merged = result.stableBlocks[0];
        // The merged rect should NOT be a simple average of (100,50) and (105,55).
        // Drift correction shifts fresh before averaging, so the result should
        // differ from the naive midpoint (102.5, 52.5).
        final naiveMidTop = (100.0 + 105.0) / 2;
        expect(
          merged.absoluteRect.top != naiveMidTop ||
              merged.absoluteRect.left != (50.0 + 55.0) / 2,
          isTrue,
          reason: 'Drift correction should shift the merged position',
        );
      },
    );

    test('text confidence blends when same text matches', () {
      final existing = _block(
        text: '测试文本内容',
        textConf: 0.3,
        observationCount: 1,
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);

      // Fresh with same text but higher confidence
      final fresh = _block(text: '测试文本内容', textConf: 0.9);
      final result = engine.stabilize([fresh]);

      final merged = result.stableBlocks[0];
      // Blended: weighted average of 0.3 and 0.9 (both weight 0.5 since
      // equal positionConfidence → equal text conf weights)
      // Formula: existing*(1-tw) + fresh*tw where tw = fresh/(existing+fresh)
      // tw = 0.9/1.2 = 0.75, result = 0.3*0.25 + 0.9*0.75 = 0.75
      expect(merged.textConfidence, closeTo(0.75, 0.01));
    });

    test('zero position confidence falls back to 0.5 weight', () {
      final existing = _block(text: '测试文本内容', top: 100, posConf: 0.0);
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);
      final fresh = _block(text: '测试文本内容', top: 110, posConf: 0.0);

      final result = engine.stabilize([fresh]);
      final merged = result.stableBlocks[0];
      // Both 0.0 → w=0.5 → simple midpoint
      expect(merged.absoluteRect.top, closeTo(105.0, 1.0));
    });

    test('carousel vote does NOT clear phantom when multiple votes exist', () {
      // Existing already has votes for -1 and carousel 2
      final existing = _block(text: '测试文本内容', carouselVotes: {-1: 1, 2: 1});
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);
      final fresh = _block(text: '测试文本内容', hzScrollerIndex: 3);

      final result = engine.stabilize([fresh]);
      final merged = result.stableBlocks[0];
      // -1 should NOT be cleared (length > 1 guard)
      expect(merged.carouselIdVotes.containsKey(-1), true);
      expect(merged.carouselIdVotes[3], 1);
    });

    test('text vote eviction removes lowest-score entry', () {
      // Use a common base text so fresh matches existing via _findMatch
      const baseText = '测试文本内容示例样本';
      final votes = <String, TextVote>{};
      // 5 variants that are minor OCR variations of the base text
      final variants = [
        '测试文本内容示例样本', // exact match
        '测试文本内容示例样木', // last char differs
        '测试文本内容示例祥本', // one char differs
        '测试文本内容京例样本', // one char differs
        '测试文本内容不例样本', // one char differs
      ];
      for (var i = 0; i < 5; i++) {
        final key = String.fromCharCodes(
          TextDedupUtils.significantCharList(variants[i]),
        );
        votes[key] = TextVote(
          rawText: variants[i],
          score: (i + 1) * 1.0, // scores: 1,2,3,4,5
          bestConfidence: 0.5,
        );
      }
      final existing = _block(
        text: baseText,
        textVotes: votes,
        observationCount: 5,
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(existing);

      final engine = _createEngine(spatialIndex: spatialIndex);
      // Fresh with yet another variant — similar enough to match (>70%)
      // but adds a 6th vote entry at low score
      final fresh = _block(text: '测试文本内容示例样品', textConf: 0.3);

      final result = engine.stabilize([fresh]);
      final merged = result.stableBlocks[0];
      expect(merged.textVotes.length, 5);
      // The lowest-score entry (score 0.3 for fresh variant, or score 1.0
      // for variant[0]) should be evicted. The top-5 by score survive.
      // Variant[0] has score 1.0, fresh has score 0.3 → fresh is evicted.
      final highScoreKey = String.fromCharCodes(
        TextDedupUtils.significantCharList(variants[4]),
      );
      expect(
        merged.textVotes.containsKey(highScoreKey),
        true,
        reason: 'highest-score variant should survive eviction',
      );
      // Verify the fresh low-score variant was evicted (not a random one)
      final freshKey = String.fromCharCodes(
        TextDedupUtils.significantCharList('测试文本内容示例样品'),
      );
      expect(
        merged.textVotes.containsKey(freshKey),
        false,
        reason: 'lowest-score fresh variant should be evicted',
      );
    });
  });

  group('StabilizationEngine dedup pipeline', () {
    test('noise filter: empty text blocks are dropped', () {
      final engine = _createEngine();
      final empty = _block(text: '');
      final whitespace = _block(text: '   \t  ', top: 200);
      final valid = _block(text: '有效内容', top: 300);

      final result = engine.stabilize([empty, whitespace, valid]);
      expect(result.stableBlocks, hasLength(1));
      expect(result.stableBlocks[0].originalText, '有效内容');
    });

    test(
      'key-based dedup: identical position+text in same batch collapsed',
      () {
        final engine = _createEngine();
        final a = _block(text: '重复文本内容', top: 100);
        final b = _block(text: '重复文本内容', top: 100);

        final result = engine.stabilize([a, b]);
        expect(result.stableBlocks, hasLength(1));
      },
    );

    test('distant blocks both survive', () {
      final engine = _createEngine();
      final a = _block(text: '第一段文本', top: 100, left: 50);
      final b = _block(text: '第二段文本', top: 2000, left: 50);

      final result = engine.stabilize([a, b]);
      expect(result.stableBlocks, hasLength(2));
    });

    test('VR block overlapping normal: VR wins (higher hierarchy)', () {
      final engine = _createEngine();
      // Same position — VR and normal can't overlap-match in resolver
      // (different coordinate spaces), so both survive in batch dedup.
      // This tests the hierarchy weight resolution path.
      final normal = _block(text: '普通文本内容', top: 100, isVR: false);
      final vr = _block(text: '普通文本内容', top: 100, isVR: true);

      final result = engine.stabilize([normal, vr]);
      // Both should survive because VR and non-VR have different coordinate contracts
      // (OverlapResolver rejects cross-VR/normal matches)
      expect(result.stableBlocks, hasLength(2));
    });

    test('spatial overlap within batch: higher quality wins', () {
      final engine = _createEngine();
      // Two blocks at same position with different text — overlap triggers NMS
      final low = _block(text: '低质量文本', top: 100, posConf: 0.3, textConf: 0.3);
      final high = _block(
        text: '高质量文本',
        top: 101,
        left: 51,
        posConf: 0.9,
        textConf: 0.9,
      );

      final result = engine.stabilize([low, high]);
      // Higher quality should survive
      expect(result.stableBlocks, hasLength(1));
      expect(result.stableBlocks[0].originalText, '高质量文本');
    });

    test('fuzzy key dedup: neighbor bucket match detected', () {
      final engine = _createEngine();
      // Two blocks that are very close but round to adjacent buckets
      // (bucket size 200, so left=199 rounds to 1, left=201 rounds to 1 too,
      // but left=99 rounds to 0 and left=301 rounds to 2)
      final a = _block(text: '相同文本内容', top: 100, left: 199);
      final b = _block(text: '相同文本内容', top: 100, left: 201);

      final result = engine.stabilize([a, b]);
      // Should be collapsed (same or adjacent bucket)
      expect(result.stableBlocks, hasLength(1));
    });
  });

  group('StabilizationEngine contradiction detection', () {
    test('grouping contradiction: 2 fresh blocks subdivide cached block', () {
      // Cached block: tall, well-observed, with combined text of two sub-blocks
      final cached = _block(
        text: '第一段内容第二段内容',
        top: 100,
        left: 50,
        width: 200,
        height: 60,
        observationCount: 5,
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(cached);

      final engine = _createEngine(spatialIndex: spatialIndex);

      // Two fresh blocks that subdivide the cached block
      final sub1 = _block(
        text: '第一段内容',
        top: 100,
        left: 50,
        width: 200,
        height: 25,
      );
      final sub2 = _block(
        text: '第二段内容',
        top: 130,
        left: 50,
        width: 200,
        height: 25,
      );

      final result = engine.stabilize([sub1, sub2]);
      // Should detect grouping contradiction
      expect(result.contradictions, isNotEmpty);
      expect(result.contradictions.first.type, ContradictionType.grouping);
      expect(result.contradictions.first.target, cached);
      expect(result.contradictions.first.evidence, hasLength(2));
    });

    test('splitting contradiction: fresh block subsumes 2 cached blocks', () {
      // Two small cached blocks side by side
      final cached1 = _block(
        text: '第一段',
        top: 100,
        left: 50,
        width: 200,
        height: 20,
        observationCount: 5,
      );
      final cached2 = _block(
        text: '第二段',
        top: 125,
        left: 50,
        width: 200,
        height: 20,
        observationCount: 5,
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(cached1);
      spatialIndex.add(cached2);

      final engine = _createEngine(spatialIndex: spatialIndex);

      // One large fresh block that subsumes both
      final fresh = _block(
        text: '第一段 第二段',
        top: 95,
        left: 45,
        width: 210,
        height: 55,
      );

      final result = engine.stabilize([fresh]);
      expect(result.contradictions, isNotEmpty);
      expect(result.contradictions.first.type, ContradictionType.splitting);
      expect(result.contradictions.first.evidence, hasLength(2));
    });

    test('no contradiction when cached blocks have few observations', () {
      final cached = _block(
        text: '第一段内容第二段内容',
        top: 100,
        left: 50,
        width: 200,
        height: 60,
        observationCount: 1, // Too few for contradiction
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(cached);

      final engine = _createEngine(spatialIndex: spatialIndex);

      final sub1 = _block(
        text: '第一段内容',
        top: 100,
        left: 50,
        width: 200,
        height: 25,
      );
      final sub2 = _block(
        text: '第二段内容',
        top: 130,
        left: 50,
        width: 200,
        height: 25,
      );

      final result = engine.stabilize([sub1, sub2]);
      expect(result.contradictions, isEmpty);
    });

    test('no contradiction when text similarity too low', () {
      final cached = _block(
        text: '完全不同的文本',
        top: 100,
        left: 50,
        width: 200,
        height: 60,
        observationCount: 5,
      );
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      spatialIndex.add(cached);

      final engine = _createEngine(spatialIndex: spatialIndex);

      final sub1 = _block(
        text: 'ABC',
        top: 100,
        left: 50,
        width: 200,
        height: 25,
      );
      final sub2 = _block(
        text: 'XYZ',
        top: 130,
        left: 50,
        width: 200,
        height: 25,
      );

      final result = engine.stabilize([sub1, sub2]);
      expect(result.contradictions, isEmpty);
    });
  });

  group('StabilizationEngine drift propagation', () {
    test('checkDriftPropagation returns empty when no drift shift', () {
      final engine = _createEngine();
      expect(engine.checkDriftPropagation(), isEmpty);
    });

    test(
      'checkDriftPropagation detects shift after consistent observations',
      () {
        final driftTracker = DriftTracker();
        final spatialIndex = SpatialBlockIndex<_TestBlock>();
        final engine = _createEngine(
          driftTracker: driftTracker,
          spatialIndex: spatialIndex,
        );

        // Seed the spatial index with an existing block
        final existing = _block(text: '测试文本内容', top: 100);
        spatialIndex.add(existing);

        // Add enough drift observations to produce a median
        for (var i = 0; i < 5; i++) {
          final obs = _block(text: '测试文本内容', top: 100 + 10.0);
          driftTracker.addObservation(
            obs,
            const Offset(5.0, 10.0),
            blockHeight: 30.0,
          );
        }

        final propagations = engine.checkDriftPropagation();
        // Should detect drift shift (median > threshold)
        expect(propagations, isNotEmpty);
        expect(propagations.first.delta.distance, greaterThan(0));
      },
    );

    test('uncorrectedBlocksForKey returns low-observation blocks', () {
      final driftTracker = DriftTracker();
      final spatialIndex = SpatialBlockIndex<_TestBlock>();
      final engine = _createEngine(
        driftTracker: driftTracker,
        spatialIndex: spatialIndex,
      );

      // Add blocks with different observation counts
      final lowObs = _block(text: '低观测', top: 100, observationCount: 1);
      final highObs = _block(text: '高观测', top: 200, observationCount: 5);
      spatialIndex.add(lowObs);
      spatialIndex.add(highObs);

      final spaceKey = driftTracker.spaceKeyFor(lowObs);
      final uncorrected = engine.uncorrectedBlocksForKey(spaceKey);

      expect(uncorrected, contains(lowObs));
      // highObs is in a different region (top=200 vs top=100, regionSize=500 → same region)
      // Both are in same normal space, but highObs has observationCount >= 3
      expect(uncorrected, isNot(contains(highObs)));
    });
  });
}
