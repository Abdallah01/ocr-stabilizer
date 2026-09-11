// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// =============================================================================
// STABILIZER CONFIG (#149, 3.0)
// =============================================================================
// The engine's levers, grouped by the stage they steer, instead of twelve
// optional constructor parameters that every new feature grew. Every value
// keeps the default it had as a constructor parameter, so
// `StabilizerConfig()` reproduces the 2.6.x default engine exactly.
//
// The long-form rationale for each lever stays on the engine's public
// getter of the same name (`StabilizationEngine.coherentShiftMinBlocks`
// etc.) — those getters now report the EFFECTIVE value read from this
// config and carry the measured history.
// =============================================================================

import 'band_fallback_config.dart';
import 'stabilization_engine.dart' show PositionMergeModel;
import 'step_response.dart';

/// Every lever of a [StabilizationEngine], grouped by stage.
///
/// ```dart
/// StabilizationEngine<MyBlock, MyPayload>(
///   merger: ...,
///   config: const StabilizerConfig(
///     retention: RetentionConfig(missedFrames: 2),
///     stepResponse: StepResponseConfig(mode: StepResponse.damp),
///   ),
/// );
/// ```
///
/// Defaults reproduce the 2.6.x default engine bit for bit.
class StabilizerConfig {
  /// Creates a [StabilizerConfig]; every omitted lever keeps its 2.6.x default.
  const StabilizerConfig({
    this.matching = const MatchingConfig(),
    this.merge = const MergeConfig(),
    this.stepResponse = const StepResponseConfig(),
    this.retention = const RetentionConfig(),
    this.diagnostics = const DiagnosticsConfig(),
  });

  /// How a fresh block finds its cached identity (band-relaxed fallback).
  final MatchingConfig matching;

  /// How a matched pair's position is merged.
  final MergeConfig merge;

  /// What the engine does when matched blocks move together.
  final StepResponseConfig stepResponse;

  /// How long an unmatched cached block stays matchable.
  final RetentionConfig retention;

  /// Read-only analyses reported on every result.
  final DiagnosticsConfig diagnostics;

  /// A copy with the given stages replaced.
  StabilizerConfig copyWith({
    MatchingConfig? matching,
    MergeConfig? merge,
    StepResponseConfig? stepResponse,
    RetentionConfig? retention,
    DiagnosticsConfig? diagnostics,
  }) =>
      StabilizerConfig(
        matching: matching ?? this.matching,
        merge: merge ?? this.merge,
        stepResponse: stepResponse ?? this.stepResponse,
        retention: retention ?? this.retention,
        diagnostics: diagnostics ?? this.diagnostics,
      );
}

/// Matching-stage levers.
class MatchingConfig {
  /// Creates a [MatchingConfig]; every omitted lever keeps its 2.6.x default.
  const MatchingConfig({this.bandFallback = const BandFallbackConfig()});

  /// The band-relaxed second matching pass. Default `mode: off`.
  /// See `doc/BAND_FALLBACK.md`.
  final BandFallbackConfig bandFallback;
}

/// Merge-stage levers.
class MergeConfig {
  /// Creates a [MergeConfig]; every omitted lever keeps its 2.6.x default.
  const MergeConfig(
      {this.positionModel = PositionMergeModel.agreementWeighted});

  /// The position-merge model. `legacy` reproduces the 0.x numerics.
  final PositionMergeModel positionModel;
}

/// Step-response levers: what happens when matched blocks move together.
class StepResponseConfig {
  /// Creates a [StepResponseConfig]; every omitted lever keeps its 2.6.x default.
  const StepResponseConfig({
    this.mode = StepResponse.coherentShift,
    this.snapThresholdMultiplier = 1.5,
    this.coherentShift = const CoherentShiftConfig(),
  });

  /// `damp` (2.2.x numerics), `snap` (per-block re-anchor) or
  /// `coherentShift` (the default since 2.3.0).
  final StepResponse mode;

  /// `snap` only: a block re-anchors when its displacement exceeds this
  /// multiple of its agreement scale. Must be finite and > 0.
  final double snapThresholdMultiplier;

  /// `coherentShift` only.
  final CoherentShiftConfig coherentShift;
}

/// The coherent-shift detector's quorum and adoption levers.
///
/// The two levers that are calibration- or corpus-dependent rather than
/// algorithmic — the absolute-pixel floor and the re-anchor count — live
/// in [experimental]; their own documentation (on the engine getters)
/// measures why.
class CoherentShiftConfig {
  /// Creates a [CoherentShiftConfig]; every omitted lever keeps its 2.6.x default.
  const CoherentShiftConfig({
    this.minBlocks = 3,
    this.minShare = 0.5,
    this.tolerance = 0.5,
    this.adoptAgreeing = true,
    this.experimental = const ExperimentalCoherentShiftOptions(),
  });

  /// Minimum number of matched movers that must agree for a shift to be
  /// decided. Must be >= 1.
  final int minBlocks;

  /// Minimum share of the capture's eligible matched pairs that must sit
  /// in the agreeing cluster. In (0, 1].
  final double minShare;

  /// Cluster tolerance as a fraction of the candidate translation's
  /// magnitude. Must be finite and > 0.
  final double tolerance;

  /// Once a shift IS decided, matched pairs under their own "moved" gate
  /// that agree with it follow it instead of lagging by the damped
  /// fraction (2.4.0 default). `false` reproduces 2.3.x numerics.
  final bool adoptAgreeing;

  /// Levers kept for experimentation; `null` (the default) leaves each off.
  final ExperimentalCoherentShiftOptions experimental;
}

/// Coherent-shift levers whose useful value is a property of the
/// consumer's capture geometry or corpus, not of the algorithm.
///
/// Leaving both `null` is always safe. See
/// `doc/COHERENT_SHIFT_CALIBRATION.md` for the floor's recipe; the
/// re-anchor count is documented, not recommended (its engine getter
/// measures why it false-fires on ordinary scroll).
class ExperimentalCoherentShiftOptions {
  /// Creates a [ExperimentalCoherentShiftOptions]; every omitted lever keeps its 2.6.x default.
  const ExperimentalCoherentShiftOptions({
    this.floorPx,
    this.reanchorMinBlocks,
  });

  /// Absolute-pixel floor that admits a single surviving mover on its own
  /// magnitude. Must be finite and > 0 when set.
  final double? floorPx;

  /// Relax the quorum on the COUNT axis to this many movers. Must be
  /// >= 1 when set.
  final int? reanchorMinBlocks;
}

/// Retention levers.
class RetentionConfig {
  /// Creates a [RetentionConfig]; every omitted lever keeps its 2.6.x default.
  const RetentionConfig({this.missedFrames = 0});

  /// How many further `stabilize()` calls a not-re-observed block stays
  /// matchable for. `0` (the default) disables retention. Must be >= 0.
  final int missedFrames;
}

/// Diagnostics levers — analyses that are reported, never applied.
class DiagnosticsConfig {
  /// Creates a [DiagnosticsConfig]; every omitted lever keeps its 2.6.x default.
  const DiagnosticsConfig({this.transformEstimateMinPairs = 3});

  /// Minimum matched pairs before `StabilizationResult.transformEstimate`
  /// is computed. Must be >= 3 — two pairs fit any similarity exactly.
  final int transformEstimateMinPairs;
}
