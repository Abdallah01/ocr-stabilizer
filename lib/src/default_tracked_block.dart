// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'carousel_votes.dart';
import 'internal/confidence_validation.dart';
import 'merge_result.dart';
import 'track.dart';
import 'text_vote.dart';
import 'types/absolute_rect.dart';
import 'types/confidence_types.dart';
import 'types/coordinate_context.dart';

/// Concrete reference implementation of [Track] with documented
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
/// - [carouselVotes] defaults to [CarouselVotes.none] (no observation yet).
///   A consumer whose block's own construction should count as an
///   observation passes `CarouselVotes.seeded(hzScrollerIndex)` instead.
/// - [classificationVotes] defaults to `{}` because the first vote is
///   accumulated when the engine first merges this block.
/// - [textVotes] defaults to `{}` for the same reason.
/// - [observationCount] defaults to `1` because constructing a block
///   represents one observation.
/// - [positionConfidence] / [textConfidence] default to
///   [PositionConfidence.groundTruth] / [TextConfidence.groundTruth] —
///   appropriate for deterministic origins (DOM extraction). OCR producers
///   should override with [PositionConfidence.from] / [TextConfidence.from].
class DefaultTrackedBlock<T> implements Track<T> {
  @override
  final AbsoluteRect absoluteRect;

  @override
  final CoordinateContext coordinates;

  @override
  final T payload;

  @override
  final String originalText;

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
  final CarouselVotes carouselVotes;

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
  /// The coordinate frame is one [CoordinateContext] (3.0, #147); the
  /// combinations the 2.x flags had to reject at construction are now
  /// unrepresentable, so there is no invariant check here.
  DefaultTrackedBlock({
    required this.absoluteRect,
    required this.payload,
    this.coordinates = const CoordinateContext.page(),
    this.originalText = '',
    this.positionConfidence = PositionConfidence.groundTruth,
    this.textConfidence = TextConfidence.groundTruth,
    this.sourceQuality = 0,
    this.observationCount = 1,
    this.classificationVotes = const {},
    this.carouselVotes = const CarouselVotes.none(),
    this.textVotes = const {},
    this.isProvisional = false,
    this.provisionalCapturesRemaining = 0,
    this.groupSignature = 0,
    this.needsReclassification = false,
  }) {
    // Confidence-range guard: throws ArgumentError if either value is not
    // a finite double in [0.0, 1.0]. Uses `throw` (not `assert`) so it
    // holds in release builds — the unchecked primary `extension type`
    // constructors on PositionConfidence/TextConfidence don't validate,
    // so this is the storage-boundary check.
    assertConfidenceRange('positionConfidence', positionConfidence.raw);
    assertConfidenceRange('textConfidence', textConfidence.raw);
  }

  /// Per-field immutable update. Pass only the fields that change.
  ///
  /// To demote an inner-scroller block to page coordinates, pass a whole
  /// new frame: `copyWith(coordinates: const CoordinateContext.page())`.
  /// (Before 3.0 this took a `containerId: null` sentinel dance — #47.)
  DefaultTrackedBlock<T> copyWith({
    AbsoluteRect? absoluteRect,
    CoordinateContext? coordinates,
    T? payload,
    String? originalText,
    PositionConfidence? positionConfidence,
    TextConfidence? textConfidence,
    int? sourceQuality,
    int? observationCount,
    Map<int, int>? classificationVotes,
    CarouselVotes? carouselVotes,
    Map<String, TextVote>? textVotes,
    bool? isProvisional,
    int? provisionalCapturesRemaining,
    int? groupSignature,
    bool? needsReclassification,
  }) {
    return DefaultTrackedBlock<T>(
      absoluteRect: absoluteRect ?? this.absoluteRect,
      payload: payload ?? this.payload,
      coordinates: coordinates ?? this.coordinates,
      originalText: originalText ?? this.originalText,
      positionConfidence: positionConfidence ?? this.positionConfidence,
      textConfidence: textConfidence ?? this.textConfidence,
      sourceQuality: sourceQuality ?? this.sourceQuality,
      observationCount: observationCount ?? this.observationCount,
      classificationVotes: classificationVotes ?? this.classificationVotes,
      carouselVotes: carouselVotes ?? this.carouselVotes,
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
      carouselVotes: merge.updatedCarouselVotes,
      observationCount: merge.observationCount,
      isProvisional: merge.isProvisional,
      provisionalCapturesRemaining: merge.provisionalCapturesRemaining,
      sourceQuality: merge.sourceQuality,
    );
  }
}
