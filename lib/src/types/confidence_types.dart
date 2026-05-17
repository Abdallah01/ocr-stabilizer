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
/// Construct via [PositionConfidence.from] for runtime values (asserts the
/// range) or the static [groundTruth] sentinel for deterministic origins
/// (DOM `getBoundingClientRect` reads, etc.) that should win SAR-merge
/// tie-breaks against noisier OCR observations.
extension type const PositionConfidence(double raw) {
  /// Validated factory. Asserts the input is in [0, 1] in debug mode.
  PositionConfidence.from(double v)
      : assert(
          v >= 0.0 && v <= 1.0,
          'PositionConfidence must be in [0.0, 1.0], got $v',
        ),
        raw = v;

  /// Deterministic ground truth (1.0). Used by producers whose position
  /// is read directly from the DOM rather than estimated by OCR.
  static const groundTruth = PositionConfidence(1.0);
}

/// Confidence in a block's OCR text (recognition accuracy). Range [0, 1].
///
/// Construct via [TextConfidence.from] for runtime values or [groundTruth]
/// for deterministic DOM-sourced text.
extension type const TextConfidence(double raw) {
  /// Validated factory. Asserts the input is in [0, 1] in debug mode.
  TextConfidence.from(double v)
      : assert(
          v >= 0.0 && v <= 1.0,
          'TextConfidence must be in [0.0, 1.0], got $v',
        ),
        raw = v;

  /// Deterministic ground truth (1.0). Used by producers whose text is
  /// read directly from the DOM rather than estimated by OCR.
  static const groundTruth = TextConfidence(1.0);
}
