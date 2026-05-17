import 'dart:math' show max, min;
import 'dart:ui' show Offset, Rect;

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;

import 'block_key.dart';
import 'drift_tracker.dart';
import 'hierarchy_weight.dart';
import 'merge_result.dart';
import 'observable_block.dart';
import 'overlap_resolver.dart';
import 'spatial_block_index.dart';
import 'stabilization_result.dart';
import 'submap_membership.dart';
import 'text_dedup_utils.dart';
import 'text_vote.dart';
import 'types/absolute_rect.dart';
import 'types/space_key.dart';

/// Well-observed threshold: blocks with this many observations signal
/// translation stability to the consumer.
const int _kWellObservedThreshold = 3;

/// Maximum text vote entries per block to prevent OOM on noisy edges.
const int _kMaxTextVotes = 5;

/// Core stabilization engine: answers "is this block the same as that block,
/// and what are its corrected coordinates?"
///
/// The engine owns SAR merge, dedup, drift propagation, and contradiction
/// detection. The app owns cache management (LRU, TTL, staging, UI).
///
/// Generic parameters:
/// - [T] — concrete block type (must implement [ObservableBlock<P>])
/// - [P] — opaque payload type carried by the block
class StabilizationEngine<T extends ObservableBlock<P>, P> {
  final BlockMerger<T, P> _merger;

  /// Drift tracker shared with the app (the app may also feed observations).
  final DriftTracker driftTracker;

  /// Spatial index shared with the app (the app may query for rendering).
  final SpatialBlockIndex<T> spatialIndex;

  /// Optional context-change detector. When non-null, the engine calls this
  /// to determine if a fresh block's context has changed relative to the
  /// existing cached block (e.g. group signature changed). A `true` return
  /// triggers translation invalidation.
  final bool Function(T fresh, T existing)? _contextualCheck;

  /// Creates a stabilization engine. The [merger] callback constructs an
  /// updated block from engine-computed merge data.
  StabilizationEngine({
    required BlockMerger<T, P> merger,
    DriftTracker? driftTracker,
    SpatialBlockIndex<T>? spatialIndex,
    SubmapMembership? submapMembership,
    bool Function(T fresh, T existing)? contextualCheck,
  }) : _merger = merger,
       driftTracker =
           driftTracker ?? DriftTracker(submapMembership: submapMembership),
       spatialIndex = spatialIndex ?? SpatialBlockIndex<T>(),
       _contextualCheck = contextualCheck;

  /// Current bucket width for dedup key generation.
  double bucketWidth = BlockKeyGenerator.kDefaultBucketSize;

  /// Current bucket height for dedup key generation.
  double bucketHeight = BlockKeyGenerator.kDefaultBucketSize;

  /// Current visual viewport scale for dedup key generation.
  double scale = 1.0;

  /// Overlap resolver for spatial NMS.
  final OverlapResolver _resolver = const OverlapResolver();

  /// Size of [stableBlocks] returned by the previous [stabilize] call.
  /// Used by the debug-mode staleness guard (see [stabilize] WARNING).
  int _lastStabilizeOutputCount = 0;

  /// Core entry point: stabilize a batch of fresh blocks against the model.
  ///
  /// [freshBlocks] — raw OCR observations for this frame (may contain
  /// duplicates, noise, or re-observations of known blocks; the dedup
  /// pipeline handles filtering).
  ///
  /// Returns a [StabilizationResult] containing:
  /// - [StabilizationResult.stableBlocks] — merged/new blocks
  /// - [StabilizationResult.contradictions] — detected contradictions
  /// - [StabilizationResult.invalidatedTexts] — texts needing re-translation
  /// - [StabilizationResult.wellObservedTexts] — texts reaching stability
  ///
  /// ## ⚠️ Caller contract: rebuild the spatial index
  ///
  /// **This method does NOT update [spatialIndex] internally.** The consumer
  /// MUST call `spatialIndex.rebuild(result.stableBlocks)` (or the equivalent
  /// `add`/`remove` calls) after each [stabilize] invocation. If you skip
  /// this step, the spatial index becomes stale and contradiction detection
  /// plus inter-batch matching (`_findMatch` in the merge pass) silently
  /// degrade — no exception, no error, just wrong results.
  ///
  /// In debug mode, [stabilize] prints a `[StabilizationEngine] WARNING`
  /// line when it detects an obviously-stale index (last call returned
  /// blocks, but the index is now empty). This is a heuristic — it catches
  /// the common "forgot to wire rebuild at all" mistake but not partial
  /// rebuilds. See #2 for the long-term enforce-internally design.
  StabilizationResult<T> stabilize(List<T> freshBlocks) {
    // Debug-mode staleness guard (#2). The most common integration error
    // is wiring [stabilize] without ever rebuilding [spatialIndex] — that
    // looks like "last call returned N blocks but index is now empty."
    if (kDebugMode &&
        _lastStabilizeOutputCount > 0 &&
        spatialIndex.isEmpty) {
      debugPrint(
        '[StabilizationEngine] WARNING: spatialIndex appears stale — '
        'last stabilize returned $_lastStabilizeOutputCount blocks but '
        'spatialIndex is empty. Did you forget to call '
        'spatialIndex.rebuild(result.stableBlocks) after the previous '
        'stabilize call? See StabilizationEngine.stabilize docstring.',
      );
    }

    // 1. Dedup pipeline
    final deduped = _dedup(freshBlocks);

    // 2. Contradiction detection (before merge so contradicted blocks
    //    can be signaled for eviction before fresh blocks enter)
    final contradictions = <ContradictionEvent<T>>[
      ...detectGroupingContradictions(deduped),
      ...detectSplittingContradictions(deduped),
    ];

    // 3. Merge or insert
    final invalidatedTexts = <String>[];
    final wellObservedTexts = <String>[];
    final stableBlocks = <T>[];

    for (final fresh in deduped) {
      final existing = _findMatch(fresh);
      if (existing != null) {
        final merged = _merge(
          fresh,
          existing,
          invalidatedTexts,
          wellObservedTexts,
        );
        stableBlocks.add(merged);
      } else {
        stableBlocks.add(fresh);
      }
    }

    _lastStabilizeOutputCount = stableBlocks.length;

    return StabilizationResult<T>(
      stableBlocks: stableBlocks,
      contradictions: contradictions,
      invalidatedTexts: invalidatedTexts,
      wellObservedTexts: wellObservedTexts,
    );
  }

  // ── Drift propagation ────────────────────────────────────────────────

  /// Last known median drift per space key, for detecting shifts.
  final Map<SpaceKey, Offset> _lastRegionalDrift = {};

  /// Check if regional drift shifted enough to warrant propagating
  /// corrections to uncorrected neighbors.
  ///
  /// Returns a list of `(spaceKey, driftDelta)` pairs where the median
  /// drift shifted beyond the threshold. The app should:
  /// 1. For each affected space key, find blocks with observationCount < 3
  /// 2. Shift their absoluteRect by `-driftDelta`
  /// 3. Rebuild the spatial index for affected regions
  ///
  /// Call this after processing [stabilize] results.
  List<({SpaceKey key, Offset delta})> checkDriftPropagation() {
    final results = <({SpaceKey key, Offset delta})>[];

    for (final spaceKey in driftTracker.observedKeys) {
      final newMedian = driftTracker.medianDriftForKey(spaceKey);
      final oldMedian = _lastRegionalDrift[spaceKey] ?? Offset.zero;
      final medianHeight = driftTracker.medianBlockHeightForKey(spaceKey);
      final propagationThreshold = max(2.0, medianHeight * 0.1);
      final deltaOffset = newMedian - oldMedian;

      if (deltaOffset.distance > propagationThreshold) {
        _lastRegionalDrift[spaceKey] = newMedian;
        driftTracker.recordPropagation(spaceKey);
        results.add((key: spaceKey, delta: deltaOffset));
      }
    }
    return results;
  }

  /// Identify blocks in [spaceKey] that are uncorrected (observationCount < 3)
  /// and should receive drift correction.
  ///
  /// Returns blocks from the spatial index matching the criteria. The app
  /// should shift each block's absoluteRect by `-delta` and rebuild.
  List<T> uncorrectedBlocksForKey(SpaceKey spaceKey) {
    return spatialIndex.allBlocks
        .where(
          (b) =>
              driftTracker.spaceKeyFor(b) == spaceKey && b.observationCount < 3,
        )
        .toList();
  }

  // ── Dedup pipeline ──────────────────────────────────────────────────

  /// Filter noise and remove intra-batch duplicates.
  ///
  /// Pipeline:
  /// 1. Noise filter — skip empty/whitespace-only text
  /// 2. Key-based intra-batch dedup — same OCR frame producing identical
  ///    position+text twice
  /// 3. Spatial overlap NMS — when two batch blocks overlap, higher quality
  ///    or higher hierarchy weight wins
  List<T> _dedup(List<T> blocks) {
    final out = <T>[];
    final seenKeys = <String>{};

    for (final b in blocks) {
      // 1. Noise filter: skip blocks with empty/whitespace-only text
      if (b.originalText.trim().isEmpty) continue;

      // 2. Key-based intra-batch dedup
      final key = BlockKeyGenerator.keyFor(
        b,
        bucketWidth: bucketWidth,
        bucketHeight: bucketHeight,
        scale: scale,
      );
      if (seenKeys.contains(key)) continue;

      // Also check ±1 neighbor buckets for boundary-straddling duplicates
      if (_isKeySeenFuzzy(key, seenKeys, b)) continue;

      seenKeys.add(key);

      // 3. Spatial overlap NMS within the batch
      final overlapping = _findBatchOverlap(b, out);
      if (overlapping != null) {
        final result = _resolver.resolveOverlap(
          incoming: b,
          existing: overlapping,
          driftMargin: driftTracker.driftMarginForKey(
            driftTracker.spaceKeyFor(b),
          ),
          confidenceMad: 0.1,
        );
        switch (result) {
          case OverlapResult.evict:
            out[out.indexOf(overlapping)] = b;
          case OverlapResult.keep:
            out.add(b);
          case OverlapResult.drop:
            // Discard incoming
            break;
        }
      } else {
        out.add(b);
      }
    }
    return out;
  }

  /// Check if [block] has a fuzzy key match (±1 bucket) in [seenKeys].
  bool _isKeySeenFuzzy(String key, Set<String> seenKeys, T block) {
    final neighbors = BlockKeyGenerator.neighborKeys(
      block,
      bucketWidth: bucketWidth,
      bucketHeight: bucketHeight,
      scale: scale,
    );
    return neighbors.any(seenKeys.contains);
  }

  /// Find an overlapping block within the current batch [out].
  T? _findBatchOverlap(T block, List<T> out) {
    final threshold = _resolver.overlapThresholdFor(block);
    final dm = driftTracker.driftMarginForKey(driftTracker.spaceKeyFor(block));
    for (final existing in out) {
      final match = _resolver.checkOverlap(
        block,
        block.absoluteRect,
        existing,
        threshold,
        dm,
      );
      if (match != null) return match;
    }
    return null;
  }

  /// Find a matching existing block for [fresh] in the spatial index.
  ///
  /// Only candidates with normalized Levenshtein similarity ≥ 0.70 are
  /// considered. Returns the best match, or null if no match found.
  T? _findMatch(T fresh) {
    final candidates = spatialIndex.candidates(fresh);
    T? bestMatch;
    double bestSimilarity = 0.0;

    for (final candidate in candidates) {
      // Must be same coordinate space.
      if (candidate.isViewportRelative != fresh.isViewportRelative) continue;

      final similarity = TextDedupUtils.normalizedLevenshtein(
        fresh.originalText,
        candidate.originalText,
      );
      if (similarity >= 0.70 && similarity > bestSimilarity) {
        bestSimilarity = similarity;
        bestMatch = candidate;
      }
    }
    return bestMatch;
  }

  /// Perform SAR (Scan-Accumulate-Replace) merge of [fresh] into [existing].
  ///
  /// Public entry point for consumers that do their own block matching but
  /// want to delegate the merge math to the engine. Returns a [MergeOutput]
  /// containing the merged block and signals.
  ///
  /// When [trackDrift] is true (default), records drift observations.
  /// Existing drift correction is always applied regardless of this flag.
  /// Set to false for intra-batch merges where both blocks come from the
  /// same OCR frame (drift should only be learned from inter-capture
  /// observations).
  MergeOutput<T> merge(T fresh, T existing, {bool trackDrift = true}) {
    return _mergeImpl(fresh, existing, trackDrift: trackDrift);
  }

  /// Internal merge used by [stabilize] — accumulates signals into lists.
  T _merge(
    T fresh,
    T existing,
    List<String> invalidatedTexts,
    List<String> wellObservedTexts,
  ) {
    final output = _mergeImpl(fresh, existing);
    if (output.textWasPromoted && output.promotedFromText != null) {
      invalidatedTexts.add(output.promotedFromText!);
    }
    if (output.contextInvalidated) {
      invalidatedTexts.add(existing.originalText);
    }
    if (output.isWellObserved) {
      wellObservedTexts.add(output.merged.originalText);
    }
    return output.merged;
  }

  /// Core merge implementation shared by [merge] and [_merge].
  MergeOutput<T> _mergeImpl(T fresh, T existing, {bool trackDrift = true}) {
    // ┌─── Provisional freeze ─────────────────────────────────────────
    if (existing.isProvisional) {
      final remaining = existing.provisionalCapturesRemaining - 1;
      final result = MergeResult(
        mergedRect: existing.absoluteRect,
        positionConfidence: existing.positionConfidence,
        driftCorrection: Offset.zero,
        winningOriginalText: existing.originalText,
        textConfidence: existing.textConfidence,
        updatedTextVotes: existing.textVotes,
        textWasPromoted: false,
        updatedClassificationVotes: existing.classificationVotes,
        needsReclassification: existing.needsReclassification,
        updatedCarouselIdVotes: existing.carouselIdVotes,
        observationCount: existing.observationCount,
        isProvisional: remaining > 0,
        provisionalCapturesRemaining: remaining,
        sourceQuality: existing.sourceQuality,
      );
      return MergeOutput<T>(merged: _merger(existing, fresh, result));
    }
    // └──────────────────────────────────────────────────────────────

    // 1. Track drift from RAW observation (before correction).
    //    Only for inter-capture merges (trackDrift=true); intra-batch
    //    duplicates from the same OCR frame should not feed drift.
    if (trackDrift) {
      final rawDrift = Offset(
        fresh.absoluteRect.left - existing.absoluteRect.left,
        fresh.absoluteRect.top - existing.absoluteRect.top,
      );
      driftTracker.addObservation(
        fresh,
        rawDrift,
        blockHeight: fresh.absoluteRect.height,
      );
    }

    // 2. Correct fresh observation for known regional drift.
    final spaceKey = driftTracker.spaceKeyFor(fresh);
    final regionDrift = driftTracker.medianDriftForKey(spaceKey);
    final correctedRect = DriftTracker.applyCorrectedPosition(
      fresh.absoluteRect.raw,
      regionDrift,
    );

    // 3. Weighted average against corrected position.
    final totalConf = existing.positionConfidence + fresh.positionConfidence;
    final w = totalConf > 0 ? fresh.positionConfidence / totalConf : 0.5;
    final mergedRaw = Rect.lerp(existing.absoluteRect.raw, correctedRect, w)!;

    // 4a. Classification vote accumulation
    final classVotes = Map<int, int>.from(existing.classificationVotes);
    classVotes[fresh.hierarchyWeight] =
        (classVotes[fresh.hierarchyWeight] ?? 0) + 1;
    final bestWeight = classVotes.entries
        .reduce((a, b) => a.value >= b.value ? a : b)
        .key;
    final needsReclass = bestWeight != existing.hierarchyWeight;

    // 4b. Carousel ID vote accumulation
    final carouselVotes = Map<int, int>.from(existing.carouselIdVotes);
    final freshHzIdx = fresh.scrollContext.hzScrollerIndex;
    // Clear phantom non-carousel vote on first real carousel observation
    if (freshHzIdx != -1 &&
        carouselVotes.length == 1 &&
        carouselVotes[-1] == 1) {
      carouselVotes.remove(-1);
    }
    carouselVotes[freshHzIdx] = (carouselVotes[freshHzIdx] ?? 0) + 1;

    // 4c. Text vote accumulation
    final updatedTextVotes = Map<String, TextVote>.from(existing.textVotes);

    // Seed existing block's text on first merge (textVotes starts empty).
    if (updatedTextVotes.isEmpty) {
      final existingNormKey = String.fromCharCodes(
        TextDedupUtils.significantCharList(existing.originalText),
      );
      if (existingNormKey.isNotEmpty) {
        updatedTextVotes[existingNormKey] = TextVote(
          rawText: existing.originalText,
          score: existing.textConfidence,
          bestConfidence: existing.textConfidence,
        );
      }
    }

    final freshText = fresh.originalText;
    final normalizedKey = String.fromCharCodes(
      TextDedupUtils.significantCharList(freshText),
    );
    final existingVote = updatedTextVotes[normalizedKey];
    final bestRaw =
        (existingVote == null ||
            fresh.textConfidence > existingVote.bestConfidence)
        ? freshText
        : existingVote.rawText;
    updatedTextVotes[normalizedKey] = TextVote(
      rawText: bestRaw,
      bestConfidence: max(
        fresh.textConfidence,
        existingVote?.bestConfidence ?? 0.0,
      ),
      score: (existingVote?.score ?? 0.0) + fresh.textConfidence,
    );
    // Bounded growth: cap at top entries
    if (updatedTextVotes.length > _kMaxTextVotes) {
      final entries = updatedTextVotes.entries.toList()
        ..sort((a, b) => b.value.score.compareTo(a.value.score));
      updatedTextVotes.removeWhere((key, _) => key == entries.last.key);
    }
    // Find the winner: highest accumulated score
    final winningVote = updatedTextVotes.values.reduce(
      (a, b) => a.score >= b.score ? a : b,
    );
    final winningText = winningVote.rawText;
    final winnerBestConf = winningVote.bestConfidence;
    final textWasPromoted = winningText != existing.originalText;

    // Text confidence: snap on promotion, blend when same text.
    double mergedTextConf;
    if (textWasPromoted) {
      mergedTextConf = winnerBestConf;
    } else if (existing.originalText == fresh.originalText) {
      final totalTextConf = existing.textConfidence + fresh.textConfidence;
      final tw = totalTextConf > 0 ? fresh.textConfidence / totalTextConf : 0.5;
      mergedTextConf =
          (existing.textConfidence * (1 - tw) + fresh.textConfidence * tw)
              .clamp(0.0, 1.0);
    } else {
      mergedTextConf = existing.textConfidence;
    }

    // 4d. Source quality: prefer higher tier
    final mergedSourceQuality = max(
      existing.sourceQuality,
      fresh.sourceQuality,
    );

    final newObservationCount = existing.observationCount + 1;

    // Build MergeResult
    final result = MergeResult(
      mergedRect: AbsoluteRect(mergedRaw),
      positionConfidence: min(totalConf, 1.0),
      driftCorrection: regionDrift,
      winningOriginalText: winningText,
      textConfidence: mergedTextConf,
      updatedTextVotes: Map.unmodifiable(updatedTextVotes),
      textWasPromoted: textWasPromoted,
      updatedClassificationVotes: Map.unmodifiable(classVotes),
      needsReclassification: needsReclass,
      updatedCarouselIdVotes: Map.unmodifiable(carouselVotes),
      observationCount: newObservationCount,
      isProvisional: false,
      provisionalCapturesRemaining: 0,
      sourceQuality: mergedSourceQuality,
    );

    // Call consumer merger to construct the updated block
    final merged = _merger(existing, fresh, result);

    // Compute signals
    final contextInvalidated =
        !textWasPromoted &&
        _contextualCheck != null &&
        _contextualCheck(fresh, existing);

    return MergeOutput<T>(
      merged: merged,
      textWasPromoted: textWasPromoted,
      promotedFromText: textWasPromoted ? existing.originalText : null,
      contextInvalidated: contextInvalidated,
      isWellObserved: newObservationCount >= _kWellObservedThreshold,
    );
  }

  // ── Contradiction detection ───────────────────────────────────────

  /// Minimum observation count for a cached block to be considered
  /// well-observed (eligible for contradiction detection).
  static const int _kMinObsForContradiction = 3;

  /// Detect grouping contradictions: ≥2 fresh blocks spatially subdivide
  /// a well-observed cached block.
  ///
  /// Returns [ContradictionEvent]s — the app decides whether to evict.
  /// Detect grouping contradictions in [freshBlocks] against the spatial index.
  ///
  /// Thresholds: height ratio < 0.70, overlap ratio ≥ 0.30, text similarity
  /// ≥ 0.60 (Levenshtein on space-joined subdivider texts).
  ///
  /// Public for consumers that run their own dedup pipeline but want to
  /// delegate contradiction detection to the engine.
  List<ContradictionEvent<T>> detectGroupingContradictions(
    List<T> freshBlocks,
  ) {
    if (freshBlocks.length < 2) return const [];

    // Build a temporary spatial index of fresh blocks for O(cells) lookup
    final freshIndex = SpatialBlockIndex<T>();
    freshIndex.rebuild(freshBlocks);

    final events = <ContradictionEvent<T>>[];

    // Scan all cached blocks via the engine's spatial index
    for (final cached in spatialIndex.allBlocks) {
      if (cached.observationCount < _kMinObsForContradiction) continue;

      final cRect = cached.absoluteRect.raw;
      if (cRect.width <= 0 || cRect.height <= 0) continue;

      // O(cells) spatial query against fresh index
      final nearby = freshIndex.blocksInRegion(cRect);

      // Height pre-filter: only blocks shorter than 70% of cached (subdivisions)
      // and overlap ≥30%.
      final cArea = cRect.width * cRect.height;
      final subdividers = <T>[];
      for (final fresh in nearby) {
        final fRect = fresh.absoluteRect.raw;
        if (fRect.height >= cRect.height * 0.7) continue;
        final intersection = cRect.intersect(fRect);
        if (intersection.isEmpty) continue;
        if ((intersection.width * intersection.height) / cArea < 0.3) continue;
        subdividers.add(fresh);
      }
      if (subdividers.length < 2) continue;

      // Sort by reading order before text comparison
      subdividers.sort(
        (a, b) => a.absoluteRect.raw.top.compareTo(b.absoluteRect.raw.top),
      );
      final sortedText = subdividers.map((b) => b.originalText).join(' ');

      final textSim = TextDedupUtils.normalizedLevenshtein(
        cached.originalText,
        sortedText,
      );
      if (textSim < 0.60) continue;

      events.add(
        ContradictionEvent<T>(
          type: ContradictionType.grouping,
          target: cached,
          evidence: subdividers,
        ),
      );
    }
    return events;
  }

  /// Detect splitting contradictions: a single fresh block subsumes
  /// ≥2 well-observed cached blocks.
  ///
  /// Returns [ContradictionEvent]s — the app decides whether to evict.
  /// Detect splitting contradictions in [freshBlocks] against the spatial index.
  ///
  /// Thresholds: height ratio < 0.70, containment ≥ 0.80, text similarity
  /// ≥ 0.60 (Levenshtein on space-joined subsumed texts).
  ///
  /// Public for consumers that run their own dedup pipeline but want to
  /// delegate contradiction detection to the engine.
  List<ContradictionEvent<T>> detectSplittingContradictions(
    List<T> freshBlocks,
  ) {
    if (freshBlocks.isEmpty) return const [];

    final events = <ContradictionEvent<T>>[];
    final alreadyTargeted = <T>{};

    for (final fresh in freshBlocks) {
      final fRect = fresh.absoluteRect.raw;
      if (fRect.width <= 0 || fRect.height <= 0) continue;

      // O(cells) query against existing cached spatial index
      final nearby = spatialIndex.blocksInRegion(fRect);

      final subsumed = <T>[];
      for (final cached in nearby) {
        if (cached.observationCount < _kMinObsForContradiction) continue;
        if (alreadyTargeted.contains(cached)) continue;

        final cRect = cached.absoluteRect.raw;
        if (cRect.height >= fRect.height * 0.7) continue;
        final cArea = cRect.width * cRect.height;
        if (cArea <= 0) continue;

        final intersection = fRect.intersect(cRect);
        if (intersection.isEmpty) continue;

        final containment = (intersection.width * intersection.height) / cArea;
        if (containment >= 0.80) {
          subsumed.add(cached);
        }
      }
      if (subsumed.length < 2) continue;

      // Sort by reading order before text comparison
      subsumed.sort(
        (a, b) => a.absoluteRect.raw.top.compareTo(b.absoluteRect.raw.top),
      );
      final sortedText = subsumed.map((b) => b.originalText).join(' ');

      final textSim = TextDedupUtils.normalizedLevenshtein(
        fresh.originalText,
        sortedText,
      );
      if (textSim < 0.60) continue;

      alreadyTargeted.addAll(subsumed);
      events.add(
        ContradictionEvent<T>(
          type: ContradictionType.splitting,
          target: fresh,
          evidence: subsumed,
        ),
      );
    }
    return events;
  }
}
