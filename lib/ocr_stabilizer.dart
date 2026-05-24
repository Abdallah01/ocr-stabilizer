/// Real-time OCR overlay stabilization engine — drift correction, spatial
/// indexing, and block tracking for translation-overlay pipelines.
///
/// **Headline types**
/// - [StabilizationEngine] — the orchestration entry point. Holds the
///   spatial index, drift tracker, optional contextual-invalidation hook,
///   and band-fallback configuration. `stabilize(freshBlocks)` produces
///   the merged stable block set for one capture.
/// - [BandFallbackConfig] / [BandFallbackMode] — opt-in band-relaxed
///   matching for blocks that miss the primary text-similarity floor but
///   are spatially unambiguous. Default is [BandFallbackMode.off].
/// - [BandFallbackStats] — read-only per-capture telemetry exposed via
///   `engine.bandStats`. The engine writes; consumers read and (optionally)
///   reset between captures.
/// - [BandPredicateException] — typed wrapper for throws raised by a
///   consumer-supplied [BandSpatialPredicate]. Catch this to distinguish
///   predicate failures from engine-internal errors.
/// - [TrackedBlock] / [ObservableBlock] / [DefaultTrackedBlock] — the
///   typed block hierarchy. Consumers either supply a custom
///   `ObservableBlock<P>` or use the default implementation.
/// - [PositionConfidence] / [TextConfidence] — `extension type`-wrapped
///   confidences with construction-time invariant guards.
///
/// **Recommended adoption flow**: ship with band fallback `off`, flip to
/// [BandFallbackMode.observeOnly] to read counters in production, then
/// commit to [BandFallbackMode.admit] once the ratios in
/// [BandFallbackStats] justify it.
library;

export 'src/band_fallback_config.dart'
    show
        BandFallbackMode,
        BandFallbackConfig,
        BandSpatialPredicate,
        BandPredicateException;
export 'src/band_fallback_stats.dart' show BandFallbackStats;
export 'src/block_classifier.dart';
export 'src/block_key.dart';
export 'src/classification_result.dart';
export 'src/block_meta.dart';
export 'src/confidence.dart';
export 'src/default_tracked_block.dart';
export 'src/ocr_block.dart';
export 'src/classification_input.dart';
export 'src/contextual_invalidation.dart';
export 'src/css_submap_membership.dart';
export 'src/drift_tracker.dart';
export 'src/iqr_outlier.dart';
export 'src/hierarchy_tiers.dart';
export 'src/hierarchy_weight.dart';
export 'src/observable_block.dart';
export 'src/overlap_resolver.dart';
export 'src/merge_result.dart';
export 'src/robust_stats.dart';
export 'src/stabilization_result.dart';
export 'src/spatial_block_index.dart';
export 'src/stabilization_engine.dart';
export 'src/submap_membership.dart';
export 'src/text_dedup_utils.dart';
export 'src/text_vote.dart';
export 'src/tracked_block.dart';
export 'src/types/absolute_rect.dart';
export 'src/types/confidence_types.dart';
export 'src/types/container_id.dart';
export 'src/types/scroll_context.dart';
export 'src/types/space_key.dart';
export 'src/types/sticky_fallback.dart';
