import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// BATCH-NMS: IDENTITY EVICTION + KEY LIFECYCLE (#50 / v0.6.0)
// =============================================================================
// Regression for the v0.5.0 audit finding §1.9:
// 1. Eviction used ==-based indexOf; for consumer blocks with value
//    equality, a different value-equal element could be replaced.
// 2. seenKeys registered a block's dedup key BEFORE spatial NMS, so a
//    dropped block's key kept fuzzy-suppressing later same-neighborhood
//    blocks that overlapped nothing in the output.
// =============================================================================

/// Block with VALUE equality on [originalText] only — models Equatable-style
/// consumer blocks, which the spatial index explicitly supports.
class _EquatableBlock implements ObservableBlock<void> {
  @override
  final AbsoluteRect absoluteRect;
  @override
  final String originalText;
  @override
  final PositionConfidence positionConfidence;
  @override
  final TextConfidence textConfidence;

  @override
  final bool isHorizontalScrollChild;

  _EquatableBlock({
    required this.absoluteRect,
    required this.originalText,
    required double confidence,
    this.isHorizontalScrollChild = false,
  })  : positionConfidence = PositionConfidence.from(confidence),
        textConfidence = TextConfidence.from(confidence);

  @override
  bool operator ==(Object other) =>
      other is _EquatableBlock && other.originalText == originalText;

  @override
  int get hashCode => originalText.hashCode;

  // ── Inert interface plumbing ──
  @override
  ContainerId? get containerId => null;
  @override
  bool get isViewportRelative => false;
  @override
  bool get isInnerScrollerChild => false;
  @override
  double get innerScrollerTop => 0;
  @override
  bool get isFromStickyElement => false;
  @override
  int get sourceQuality => 0;
  @override
  void get payload {}
  @override
  ScrollContext get scrollContext =>
      const ScrollContext(scrollY: 0, scrollX: 0, hzScrollerIndex: -1);
  @override
  StickyFallback get stickyFallback => const StickyFallback(
      scrollY: 0, scrollX: 0, isIc: false, hzScrollerIndex: -1);
  @override
  int get observationCount => 1;
  @override
  Map<int, int> get classificationVotes => const {};
  @override
  Map<int, int> get carouselIdVotes => const {-1: 1};
  @override
  Map<String, TextVote> get textVotes => const {};
  @override
  bool get isProvisional => false;
  @override
  int get provisionalCapturesRemaining => 0;
  @override
  int get groupSignature => 0;
  @override
  bool get needsReclassification => false;
}

StabilizationEngine<_EquatableBlock, void> _engine() {
  return StabilizationEngine<_EquatableBlock, void>(
    // NMS regression tests only exercise the intra-batch dedup pipeline,
    // where no merge occurs (empty index → all blocks are new).
    merger: (existing, fresh, merge) => existing,
  );
}

void main() {
  group('batch-NMS eviction identity (#50)', () {
    test('evicting one of two value-equal blocks replaces the right one', () {
      final engine = _engine();
      // a1 and a2 are ==-equal (same text) but distinct blocks at distant
      // positions. b overlaps and evicts a2 (higher quality, full
      // overlap). Pre-fix, indexOf(a2) found a1 (first ==-equal element)
      // and replaced the wrong block.
      final a1 = _EquatableBlock(
        absoluteRect: AbsoluteRect.fromLTWH(0, 0, 100, 30),
        originalText: 'duplicate text',
        confidence: 0.9,
      );
      final a2 = _EquatableBlock(
        absoluteRect: AbsoluteRect.fromLTWH(1000, 0, 100, 30),
        originalText: 'duplicate text',
        confidence: 0.1,
      );
      final b = _EquatableBlock(
        absoluteRect: AbsoluteRect.fromLTWH(1000, 0, 100, 30),
        originalText: 'better reading',
        confidence: 1.0,
      );

      final result = engine.stabilize([a1, a2, b]);

      expect(result.stableBlocks, hasLength(2));
      expect(
        result.stableBlocks.any((x) => identical(x, a1)),
        isTrue,
        reason: 'a1 (far away, never in conflict) must survive',
      );
      expect(
        result.stableBlocks.any((x) => identical(x, b)),
        isTrue,
        reason: 'b won the overlap resolution against a2',
      );
      expect(
        result.stableBlocks.any((x) => identical(x, a2)),
        isFalse,
        reason: 'a2 lost the overlap resolution and must be evicted',
      );
    });
  });

  group('batch-NMS key lifecycle (#50)', () {
    test('a dropped block\'s key no longer fuzzy-suppresses later blocks', () {
      final engine = _engine();
      // a: carousel child (hierarchy weight 20). b: normal block (weight
      // 10) fully inside a — dropped by NMS strategy A (lower hierarchy
      // weight always drops; equal-weight overlaps resolve to keep or
      // evict, never drop). c: same text as b, one dedup bucket to the
      // right, overlapping NOTHING in the output. Pre-fix, b's key was
      // registered before NMS dropped it, and c's fuzzy neighbor check
      // matched that stale key — c vanished although no live block
      // conflicted with it.
      final a = _EquatableBlock(
        absoluteRect: AbsoluteRect.fromLTWH(0, 0, 150, 30),
        originalText: 'strong anchor',
        confidence: 1.0,
        isHorizontalScrollChild: true,
      );
      final b = _EquatableBlock(
        absoluteRect: AbsoluteRect.fromLTWH(40, 0, 100, 30),
        originalText: 'shared words',
        confidence: 0.1,
      );
      final c = _EquatableBlock(
        absoluteRect: AbsoluteRect.fromLTWH(240, 0, 100, 30),
        originalText: 'shared words',
        confidence: 0.8,
      );

      final result = engine.stabilize([a, b, c]);

      expect(
        result.stableBlocks.any((x) => identical(x, b)),
        isFalse,
        reason: 'b is fully inside the higher-quality a and must drop',
      );
      expect(
        result.stableBlocks.any((x) => identical(x, c)),
        isTrue,
        reason: 'c overlaps nothing in the output — the dropped b\'s key '
            'must not suppress it',
      );
      expect(result.stableBlocks, hasLength(2));
    });
  });
}
