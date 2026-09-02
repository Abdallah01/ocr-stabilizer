// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// =============================================================================
// Confidence Extension Types
// =============================================================================
//
// Wrap `double` confidence values in nominally distinct types so the type
// system rejects accidental mixing of position-vs-text confidence at the
// boundaries that consume them. Zero runtime cost — Dart erases extension
// types to their representation `double` in compiled output.
//
// Pattern mirrors `lib/src/types/absolute_rect.dart` and `container_id.dart`.
//
// CONTRACT (#98 decision): the scalar IS the API. The component signals
// that shape it along the way — cross-capture agreement, observation
// depth, drift regime, overlap quality — are internal and refactorable
// without notice. Consumers must not reverse-engineer components from
// scalar deltas; if a use case genuinely needs the breakdown, reopen #98
// with that use case rather than depending on incidental numerics.
// =============================================================================

import '../internal/confidence_validation.dart';

/// Confidence in a block's `absoluteRect` (position accuracy). Range [0, 1].
///
/// The primary constructor `PositionConfidence(double)` is `const` and
/// **unchecked** — it is the only `const`-capable path, kept for `const`
/// sentinels with literal in-range values. It validates nothing: an
/// out-of-range or NaN value built this way flows into the engine
/// unchecked. (`MergeResult`'s constructor guards engine *output*, but code
/// that reads `raw` directly — e.g. dedup quality scoring — does not.)
/// For any runtime value use [PositionConfidence.from], which validates
/// and throws.
extension type const PositionConfidence(double raw) {
  /// Validated factory for runtime values. Throws [ArgumentError] on a NaN,
  /// non-finite, or out-of-[0, 1] input — in release builds as well as
  /// debug. Not `const`; see the type doc for the `const` path.
  factory PositionConfidence.from(double value) {
    assertConfidenceRange('PositionConfidence', value);
    return PositionConfidence(value);
  }

  /// Deterministic ground truth (1.0). Used by producers whose position
  /// is read directly from the DOM rather than estimated by OCR.
  static const groundTruth = PositionConfidence(1.0);
}

/// Confidence in a block's OCR text (recognition accuracy). Range [0, 1].
///
/// The primary constructor `TextConfidence(double)` is `const` and
/// **unchecked** — it is the only `const`-capable path, kept for `const`
/// sentinels with literal in-range values. It validates nothing: an
/// out-of-range or NaN value built this way flows into the engine
/// unchecked. (`MergeResult`'s constructor guards engine *output*, but code
/// that reads `raw` directly — e.g. dedup quality scoring — does not.)
/// For any runtime value use [TextConfidence.from], which validates
/// and throws.
extension type const TextConfidence(double raw) {
  /// Validated factory for runtime values. Throws [ArgumentError] on a NaN,
  /// non-finite, or out-of-[0, 1] input — in release builds as well as
  /// debug. Not `const`; see the type doc for the `const` path.
  factory TextConfidence.from(double value) {
    assertConfidenceRange('TextConfidence', value);
    return TextConfidence(value);
  }

  /// Deterministic ground truth (1.0). Used by producers whose text is
  /// read directly from the DOM rather than estimated by OCR.
  static const groundTruth = TextConfidence(1.0);
}
