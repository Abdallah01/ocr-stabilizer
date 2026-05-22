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
// =============================================================================

/// Confidence in a block's [absoluteRect] (position accuracy). Range [0, 1].
///
/// The primary constructor `PositionConfidence(double)` is `const` and
/// **unchecked** — it is the only `const`-capable path and exists for
/// `const` test/benchmark sentinels with literal in-range values. For any
/// runtime value use [PositionConfidence.from], which validates and throws.
/// An out-of-range value built via the primary constructor passes silently
/// until [MergeResult]'s boundary guards reject it — use [from] for
/// anything that is not a compile-time literal.
extension type const PositionConfidence(double raw) {
  /// Validated factory for runtime values. Throws [ArgumentError] on a NaN
  /// or out-of-[0, 1] input — in release builds as well as debug. Cannot be
  /// `const` (it throws); see the type doc for the `const` path.
  factory PositionConfidence.from(double v) {
    if (v.isNaN || v < 0.0 || v > 1.0) {
      throw ArgumentError.value(
        v,
        'PositionConfidence',
        'must be in [0.0, 1.0]',
      );
    }
    return PositionConfidence(v);
  }

  /// Deterministic ground truth (1.0). Used by producers whose position
  /// is read directly from the DOM rather than estimated by OCR.
  static const groundTruth = PositionConfidence(1.0);
}

/// Confidence in a block's OCR text (recognition accuracy). Range [0, 1].
///
/// The primary constructor `TextConfidence(double)` is `const` and
/// **unchecked** — it is the only `const`-capable path and exists for
/// `const` test/benchmark sentinels with literal in-range values. For any
/// runtime value use [TextConfidence.from], which validates and throws.
/// An out-of-range value built via the primary constructor passes silently
/// until [MergeResult]'s boundary guards reject it — use [from] for
/// anything that is not a compile-time literal.
extension type const TextConfidence(double raw) {
  /// Validated factory for runtime values. Throws [ArgumentError] on a NaN
  /// or out-of-[0, 1] input — in release builds as well as debug. Cannot be
  /// `const` (it throws); see the type doc for the `const` path.
  factory TextConfidence.from(double v) {
    if (v.isNaN || v < 0.0 || v > 1.0) {
      throw ArgumentError.value(
        v,
        'TextConfidence',
        'must be in [0.0, 1.0]',
      );
    }
    return TextConfidence(v);
  }

  /// Deterministic ground truth (1.0). Used by producers whose text is
  /// read directly from the DOM rather than estimated by OCR.
  static const groundTruth = TextConfidence(1.0);
}
