import 'merge_result.dart';
import 'observable_block.dart';

/// How a consumer constructs an updated block from engine-computed merge data.
///
/// The engine calls this with the existing block, the fresh observation, and
/// the computed [MergeResult]. The consumer returns a new immutable instance
/// (e.g. via `copyWith`). The [fresh] block is provided so the consumer can
/// access app-specific pass-through fields (scroll context, classification
/// flags, translated text) that the engine does not compute.
///
/// **Required field mappings from [MergeResult]:**
/// - `mergedRect` → `absoluteRect`
/// - `positionConfidence` → `positionConfidence`
/// - `winningOriginalText` → `originalText`
/// - `textConfidence` → `textConfidence`
/// - `updatedTextVotes` → `textVotes`
/// - `updatedClassificationVotes` → `classificationVotes`
/// - `needsReclassification` → `needsReclassification`
/// - `updatedCarouselIdVotes` → `carouselIdVotes`
/// - `observationCount` → `observationCount`
/// - `isProvisional` → `isProvisional`
/// - `provisionalCapturesRemaining` → `provisionalCapturesRemaining`
/// - `sourceQuality` → consumer-specific (e.g. map to enum)
///
/// Omitting fields causes state drift between engine and consumer.
typedef BlockMerger<T extends ObservableBlock<P>, P> =
    T Function(T existing, T fresh, MergeResult merge);

/// Type of contradiction detected between fresh and cached blocks.
enum ContradictionType {
  /// Fresh blocks subdivide a cached block (grouping changed).
  grouping,

  /// A fresh block subsumes multiple cached blocks (splitting changed).
  splitting,
}

/// A detected contradiction between fresh and cached blocks.
///
/// **Direction depends on [type]:**
/// - [ContradictionType.grouping]: [target] is a cached block,
///   [evidence] is 2+ fresh blocks that subdivide it.
/// - [ContradictionType.splitting]: [target] is a fresh block,
///   [evidence] is 2+ cached blocks it subsumes.
///
/// Detection-only: the package detects contradictions and returns events.
/// The app decides the reaction (evict, re-translate, flag for review).
class ContradictionEvent<T> {
  /// The kind of contradiction detected.
  final ContradictionType type;

  /// Target block — cached for grouping, fresh for splitting (see [type]).
  final T target;

  /// 2+ blocks that prove the contradiction (subdividers or subsumed blocks).
  final List<T> evidence;

  /// Creates a contradiction event. [evidence] must have >= 2 entries.
  const ContradictionEvent({
    required this.type,
    required this.target,
    required this.evidence,
  }) : assert(
         evidence.length >= 2,
         'contradiction requires >= 2 evidence blocks',
       );
}

/// Output of a single [StabilizationEngine.merge] call.
///
/// Contains the merged block and any signals that the merge produced.
/// Consumers that call [StabilizationEngine.merge] directly (instead of
/// [StabilizationEngine.stabilize]) must handle these signals themselves.
class MergeOutput<T> {
  /// The merged block (constructed by the [BlockMerger] callback).
  final T merged;

  /// Whether the winning text changed (old text should be invalidated).
  final bool textWasPromoted;

  /// The old original text if [textWasPromoted] is true, else null.
  final String? promotedFromText;

  /// Whether a contextual check triggered invalidation.
  final bool contextInvalidated;

  /// Whether this block reached the well-observed threshold.
  final bool isWellObserved;

  /// Creates a merge output.
  const MergeOutput({
    required this.merged,
    this.textWasPromoted = false,
    this.promotedFromText,
    this.contextInvalidated = false,
    this.isWellObserved = false,
  });
}

/// Output of [StabilizationEngine.stabilize].
///
/// Contains the merged blocks that survived dedup, any contradiction
/// detections, and signals for the app's translation layer.
class StabilizationResult<T> {
  /// Blocks that survived dedup and were merged into the model.
  final List<T> stableBlocks;

  /// Contradiction detections (app decides how to handle).
  final List<ContradictionEvent<T>> contradictions;

  /// Source texts whose translation should be invalidated
  /// (text was promoted to a different variant via voting).
  final List<String> invalidatedTexts;

  /// Source texts that reached the well-observed threshold
  /// (observationCount >= 3, translation can be cached long-term).
  final List<String> wellObservedTexts;

  /// Creates a stabilization result.
  const StabilizationResult({
    required this.stableBlocks,
    this.contradictions = const [],
    this.invalidatedTexts = const [],
    this.wellObservedTexts = const [],
  });
}
