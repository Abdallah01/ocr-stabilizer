import 'merge_result.dart';
import 'observable_block.dart';
import 'text_vote.dart';
import 'types/absolute_rect.dart';
import 'types/confidence_types.dart';
import 'types/container_id.dart';
import 'types/scroll_context.dart';
import 'types/sticky_fallback.dart';

/// Concrete reference implementation of [ObservableBlock] with documented
/// defaults for every required field.
///
/// New integrators can use this directly for the simplest case (text-only,
/// page-scrolled content) or subclass it for domain-specific payloads.
/// The minimal viable construction is:
///
/// ```dart
/// final block = DefaultTrackedBlock<MyPayload>(
///   absoluteRect: AbsoluteRect.fromLTWH(0, 0, 200, 30),
///   originalText: 'hello',
///   payload: myPayload,
/// );
/// ```
///
/// Defaults that warrant attention because the engine treats them as
/// load-bearing:
///
/// - [carouselIdVotes] defaults to `{-1: 1}` — **not** `{}`. The engine's
///   carousel-vote clearing logic checks for the phantom `-1: 1` entry as
///   the sentinel "this block has never been observed inside a carousel."
///   An empty map will misclassify the first real carousel observation.
/// - [classificationVotes] defaults to `{}` because the first vote is
///   accumulated when the engine first merges this block.
/// - [textVotes] defaults to `{}` for the same reason.
/// - [observationCount] defaults to `1` because constructing a block
///   represents one observation.
/// - [positionConfidence] / [textConfidence] default to
///   [PositionConfidence.groundTruth] / [TextConfidence.groundTruth] —
///   appropriate for deterministic origins (DOM extraction). OCR producers
///   should override with [PositionConfidence.from] / [TextConfidence.from].
class DefaultTrackedBlock<T> implements ObservableBlock<T> {
  @override
  final AbsoluteRect absoluteRect;

  @override
  final ContainerId? containerId;

  @override
  final bool isViewportRelative;

  @override
  final bool isInnerScrollerChild;

  @override
  final double innerScrollerTop;

  @override
  final bool isHorizontalScrollChild;

  @override
  final T payload;

  @override
  final String originalText;

  @override
  final ScrollContext scrollContext;

  @override
  final bool isFromStickyElement;

  @override
  final StickyFallback stickyFallback;

  @override
  final PositionConfidence positionConfidence;

  @override
  final TextConfidence textConfidence;

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

  /// Construct a tracked block. All fields are optional except [absoluteRect]
  /// and [payload] — defaults are documented in the class docstring.
  ///
  /// Throws [ArgumentError] if the [TrackedBlock] invariant is violated:
  /// when [containerId] is non-null, [isInnerScrollerChild] must be true.
  /// Mismatched flags would misclassify the block into the wrong drift
  /// coordinate space (see TrackedBlock). Uses `throw` rather than `assert`
  /// per project policy (feedback_assert_vs_throw_in_storage) — this is the
  /// public reference implementation of a state-owning type, so the check
  /// must hold in release builds as well as debug.
  DefaultTrackedBlock({
    required this.absoluteRect,
    required this.payload,
    this.containerId,
    this.isViewportRelative = false,
    this.isInnerScrollerChild = false,
    this.innerScrollerTop = 0,
    this.isHorizontalScrollChild = false,
    this.originalText = '',
    this.scrollContext = ScrollContext.none,
    this.isFromStickyElement = false,
    this.stickyFallback = StickyFallback.none,
    this.positionConfidence = PositionConfidence.groundTruth,
    this.textConfidence = TextConfidence.groundTruth,
    this.sourceQuality = 0,
    this.observationCount = 1,
    this.classificationVotes = const {},
    this.carouselIdVotes = const {-1: 1},
    this.textVotes = const {},
    this.isProvisional = false,
    this.provisionalCapturesRemaining = 0,
    this.groupSignature = 0,
    this.needsReclassification = false,
  }) {
    if (containerId != null && !isInnerScrollerChild) {
      throw ArgumentError(
        'TrackedBlock invariant: containerId requires isInnerScrollerChild '
        '(got containerId=$containerId, isInnerScrollerChild=false). '
        'Setting containerId without isInnerScrollerChild misclassifies the '
        'block into the wrong drift coordinate space and silently corrupts '
        'drift corrections.',
      );
    }
    _validateConfidence('positionConfidence', positionConfidence.raw);
    _validateConfidence('textConfidence', textConfidence.raw);
  }

  // Private helper — DRY across the two confidence fields. Uses `throw` rather
  // than `assert` per project policy (feedback_assert_vs_throw_in_storage):
  // asserts strip in release; production-critical invariants on a state-owning
  // type must hold in release builds too.
  static void _validateConfidence(String name, double raw) {
    if (raw.isNaN || raw < 0.0 || raw > 1.0) {
      throw ArgumentError.value(
        raw,
        name,
        'must be a finite double in [0.0, 1.0]',
      );
    }
  }

  /// Per-field immutable update. Pass only the fields that change.
  DefaultTrackedBlock<T> copyWith({
    AbsoluteRect? absoluteRect,
    ContainerId? containerId,
    bool? isViewportRelative,
    bool? isInnerScrollerChild,
    double? innerScrollerTop,
    bool? isHorizontalScrollChild,
    T? payload,
    String? originalText,
    ScrollContext? scrollContext,
    bool? isFromStickyElement,
    StickyFallback? stickyFallback,
    PositionConfidence? positionConfidence,
    TextConfidence? textConfidence,
    int? sourceQuality,
    int? observationCount,
    Map<int, int>? classificationVotes,
    Map<int, int>? carouselIdVotes,
    Map<String, TextVote>? textVotes,
    bool? isProvisional,
    int? provisionalCapturesRemaining,
    int? groupSignature,
    bool? needsReclassification,
  }) {
    return DefaultTrackedBlock<T>(
      absoluteRect: absoluteRect ?? this.absoluteRect,
      payload: payload ?? this.payload,
      containerId: containerId ?? this.containerId,
      isViewportRelative: isViewportRelative ?? this.isViewportRelative,
      isInnerScrollerChild: isInnerScrollerChild ?? this.isInnerScrollerChild,
      innerScrollerTop: innerScrollerTop ?? this.innerScrollerTop,
      isHorizontalScrollChild:
          isHorizontalScrollChild ?? this.isHorizontalScrollChild,
      originalText: originalText ?? this.originalText,
      scrollContext: scrollContext ?? this.scrollContext,
      isFromStickyElement: isFromStickyElement ?? this.isFromStickyElement,
      stickyFallback: stickyFallback ?? this.stickyFallback,
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
    );
  }

  /// Apply a [MergeResult] from the stabilization engine.
  ///
  /// Designed as the canonical `BlockMerger` body — wire it into the engine
  /// like so:
  ///
  /// ```dart
  /// final engine = StabilizationEngine<DefaultTrackedBlock<P>, P>(
  ///   merger: (existing, fresh, merge) => existing.applyMerge(merge),
  /// );
  /// ```
  ///
  /// Fields engine-computed:
  /// position, text (winning + votes + confidence), classification votes,
  /// needs reclassification, carousel votes, observation count,
  /// provisional state, source quality.
  /// Fields preserved from `this`: payload, containerId, all coordinate-space
  /// flags, scrollContext, sticky state, groupSignature.
  DefaultTrackedBlock<T> applyMerge(MergeResult merge) {
    return copyWith(
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
}
