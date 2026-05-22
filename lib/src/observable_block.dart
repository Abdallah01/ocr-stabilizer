import 'text_vote.dart';
import 'tracked_block.dart';

/// Observation history accumulated across SAR (Scan-Accumulate-Replace) merges.
///
/// These fields grow as the engine re-observes the block. Implementations
/// provide updated values via immutable replacement (e.g. `copyWith`);
/// the interface itself is read-only.
///
/// Separated from [TrackedBlock] because not all consumers need observation
/// tracking (e.g. a one-shot OCR pipeline with no stabilization).
abstract interface class ObservableBlock<T> implements TrackedBlock<T> {
  /// Number of times this block has been observed across captures.
  int get observationCount;

  /// Histogram of observed hierarchy weights across SAR merges.
  Map<int, int> get classificationVotes;

  /// Histogram of observed carousel indices across SAR merges.
  Map<int, int> get carouselIdVotes;

  /// Histogram of text variants keyed by normalized significant characters.
  /// Each entry tracks accumulated confidence evidence for one text variant.
  Map<String, TextVote> get textVotes;

  /// Whether this block is in the ambiguous band awaiting cluster resolution.
  bool get isProvisional;

  /// Countdown of captures remaining before provisional resolution.
  int get provisionalCapturesRemaining;

  /// NLP neighborhood hash for translation invalidation (0 = single-block).
  int get groupSignature;

  /// Whether classification votes flipped to a different weight tier.
  bool get needsReclassification;
}
