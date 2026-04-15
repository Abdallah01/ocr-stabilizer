/// Accumulated evidence for a single text variant observed at a block position.
///
/// Used by the text quality accumulation system to track how much confidence
/// evidence supports each OCR reading. The string with the highest accumulated
/// [score] becomes the active `originalText` for translation.
class TextVote {
  /// Best visual representation for translation — the reading with the
  /// highest single-observation `textConfidence`, not the first observation.
  final String rawText;

  /// Accumulated confidence across all observations of this text variant.
  final double score;

  /// Highest single-observation confidence that contributed to this entry.
  /// Independent of [score] — tracks the cleanest individual reading.
  final double bestConfidence;

  /// Creates a text vote entry.
  const TextVote({
    required this.rawText,
    required this.score,
    required this.bestConfidence,
  });
}
