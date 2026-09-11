// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// The per-capture transform estimate (2.6.0, #135): which matched pairs
// feed the fit and the fit itself. Extracted from
// `StabilizationEngine.stabilize` in #150 with no behaviour change.

import '../observation.dart';
import '../track.dart';
import '../transform_estimate.dart';
import '../types/geometry.dart' show Offset;

/// Collects the cached → fresh centre pairs of one capture and fits the
/// similarity transform they describe. Observed, never applied — nothing
/// in the engine reads the estimate (contract G11 / U9).
///
/// One instance per capture. Pairs are collected in the REAL match loop,
/// every `StepResponse`, under the coherent-shift detector's eligibility
/// (no band admission, nested fragment, provisional cached block,
/// viewport-relative fresh block or carousel child), from RAW rects: no
/// drift correction, so the fit never depends on the tracker's
/// same-capture mutations.
class TransformEstimator<T extends Track<Object?>> {
  /// Creates an estimator; [minPairs] is `DiagnosticsConfig.transformEstimateMinPairs`
  /// (validated `>= 3` by the engine).
  TransformEstimator({required this.minPairs});

  /// Fewest pairs the fit accepts.
  final int minPairs;

  final List<(Offset, Offset)> _pairs = [];

  /// Whether a merged pair contributes to the fit.
  bool eligible(T fresh, T existing, {required bool wasBandFallback}) =>
      !wasBandFallback &&
      !existing.isProvisional &&
      !fresh.isViewportRelative &&
      !fresh.isHorizontalScrollChild &&
      !existing.isHorizontalScrollChild;

  /// Record one ordinary (non-nested) match; ignored when not [eligible].
  void observe(T fresh, T existing, {required bool wasBandFallback}) {
    if (!eligible(fresh, existing, wasBandFallback: wasBandFallback)) return;
    _pairs
        .add((existing.absoluteRect.raw.center, fresh.absoluteRect.raw.center));
  }

  /// The capture's estimate, or null below [minPairs] / on a degenerate
  /// fit (see [TransformEstimate.fit]).
  TransformEstimate? estimate() =>
      TransformEstimate.fit(_pairs, minPairs: minPairs);
}
