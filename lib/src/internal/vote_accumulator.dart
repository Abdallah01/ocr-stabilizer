// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// The vote half of a merge (classification, carousel, text votes, text
// confidence, source quality), extracted from
// `StabilizationEngine._mergeImpl` steps 4a–4d in #150 with no behaviour
// change. Pure over the two blocks.

import 'dart:math' show max;

import '../carousel_votes.dart';
import '../hierarchy_weight.dart';
import '../observation.dart';
import '../text_dedup_utils.dart';
import '../text_vote.dart';
import '../track.dart';

/// What one merge decided about a block's votes and text.
typedef VoteOutcome = ({
  Map<int, int> classificationVotes,
  bool needsReclassification,
  CarouselVotes carouselVotes,
  Map<String, TextVote> textVotes,
  String winningText,
  bool textWasPromoted,
  double mergedTextConfidence,
  int sourceQuality,
});

/// Accumulates one fresh observation into an existing block's votes.
class VoteAccumulator {
  /// Creates an accumulator; [maxTextVotes] bounds the text-vote map.
  const VoteAccumulator({this.maxTextVotes = 5});

  /// Maximum text vote entries per block to prevent OOM on noisy edges.
  final int maxTextVotes;

  /// Steps 4a–4d of a merge, in that order.
  VoteOutcome accumulate({
    required Observation<Object?> fresh,
    required Track<Object?> existing,
  }) {
    // 4a. Classification vote accumulation
    final classVotes = Map<int, int>.from(existing.classificationVotes);
    classVotes[fresh.hierarchyWeight] =
        (classVotes[fresh.hierarchyWeight] ?? 0) + 1;
    final bestWeight =
        classVotes.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
    final needsReclass = bestWeight != existing.hierarchyWeight;

    // 4b. Carousel ID vote accumulation (#148: the value type owns the
    // histogram; a freshly constructed block carries no phantom vote to
    // clear).
    final carouselVotes =
        existing.carouselVotes.record(fresh.scrollContext.hzScrollerIndex);

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
          score: existing.textConfidence.raw,
          bestConfidence: existing.textConfidence.raw,
        );
      }
    }

    final freshText = fresh.originalText;
    final normalizedKey = String.fromCharCodes(
      TextDedupUtils.significantCharList(freshText),
    );
    final existingVote = updatedTextVotes[normalizedKey];
    final bestRaw = (existingVote == null ||
            fresh.textConfidence.raw > existingVote.bestConfidence)
        ? freshText
        : existingVote.rawText;
    updatedTextVotes[normalizedKey] = TextVote(
      rawText: bestRaw,
      bestConfidence: max(
        fresh.textConfidence.raw,
        existingVote?.bestConfidence ?? 0.0,
      ),
      score: (existingVote?.score ?? 0.0) + fresh.textConfidence.raw,
    );
    // Bounded growth: cap at top entries
    if (updatedTextVotes.length > maxTextVotes) {
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
      final existingTC = existing.textConfidence.raw;
      final freshTC = fresh.textConfidence.raw;
      final totalTextConf = existingTC + freshTC;
      final tw = totalTextConf > 0 ? freshTC / totalTextConf : 0.5;
      mergedTextConf = (existingTC * (1 - tw) + freshTC * tw).clamp(0.0, 1.0);
    } else {
      mergedTextConf = existing.textConfidence.raw;
    }

    // 4d. Source quality: prefer higher tier
    final mergedSourceQuality = max(
      existing.sourceQuality,
      fresh.sourceQuality,
    );

    return (
      classificationVotes: classVotes,
      needsReclassification: needsReclass,
      carouselVotes: carouselVotes,
      textVotes: updatedTextVotes,
      winningText: winningText,
      textWasPromoted: textWasPromoted,
      mergedTextConfidence: mergedTextConf,
      sourceQuality: mergedSourceQuality,
    );
  }
}
