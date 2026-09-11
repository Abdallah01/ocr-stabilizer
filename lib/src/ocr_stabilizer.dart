// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'default_tracked_block.dart';
import 'stabilization_engine.dart';

/// The common path (#170): a [StabilizationEngine] over
/// [DefaultTrackedBlock]s with the merger already wired.
///
/// ```dart
/// final stabilizer = OcrStabilizer<MyPayload>();
///
/// // Each capture:
/// final result = stabilizer.stabilize(observations);
/// for (final block in result.stableBlocks) {
///   render(block.originalText, block.absoluteRect);
/// }
/// ```
///
/// One generic parameter — your payload type — and no `merger` callback:
/// for [DefaultTrackedBlock] that callback is always
/// `existing.applyMerge(merge)`, so this class supplies it. Everything else
/// is inherited unchanged (`stabilize`, `merge`, the result type, the
/// telemetry getters), and every [StabilizationEngine] constructor option
/// is forwarded, so a caller who later needs a custom `Track` type moves to
/// [StabilizationEngine] with no behaviour change — the two are equivalent
/// capture for capture (`test/ocr_stabilizer_test.dart` pins that).
///
/// Start with the defaults. The configuration is the escape hatch:
///
/// ```dart
/// OcrStabilizer<MyPayload>(
///   config: StabilizerConfig(retention: RetentionConfig(missedFrames: 2)),
/// );
/// ```
class OcrStabilizer<P> extends StabilizationEngine<DefaultTrackedBlock<P>, P> {
  /// Every parameter is optional and forwarded verbatim to
  /// [StabilizationEngine.new]; see that constructor for what each does.
  OcrStabilizer({
    super.config,
    super.driftTracker,
    super.spatialIndex,
    super.submapMembership,
    super.contextualCheck,
  }) : super(merger: (existing, _, merge) => existing.applyMerge(merge));
}
