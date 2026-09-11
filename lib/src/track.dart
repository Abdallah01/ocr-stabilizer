// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'carousel_votes.dart';
import 'text_vote.dart';
import 'observation.dart';

/// An [Observation] plus what the engine has learned about it across
/// captures: the observation count, the vote histograms, the provisional
/// state.
///
/// The engine stores tracks and returns tracks; a fresh block enters as a
/// track at its first observation (every state field at its initial value,
/// which is what `DefaultTrackedBlock`'s defaults give). The engine never
/// reads these fields from a fresh block — only from the matched existing
/// one — and writes them only through `MergeResult`, applied by the
/// consumer's merger via immutable replacement (e.g. `copyWith`). The
/// interface itself is read-only.
///
/// Separated from [Observation] because not every component needs the
/// history (the classifier, the paragraph grouper and the spatial index
/// work on observations alone).
abstract interface class Track<T> implements Observation<T> {
  /// Number of times this block has been observed across captures.
  int get observationCount;

  /// Histogram of observed hierarchy weights across SAR merges.
  Map<int, int> get classificationVotes;

  /// Histogram of observed carousel indices across SAR merges.
  CarouselVotes get carouselVotes;

  /// Histogram of text variants keyed by normalized significant characters.
  /// Each entry tracks accumulated confidence evidence for one text variant.
  Map<String, TextVote> get textVotes;

  /// Whether this block is in the ambiguous band awaiting cluster resolution.
  bool get isProvisional;

  /// Countdown of captures remaining before provisional resolution.
  int get provisionalCapturesRemaining;

  /// NLP neighborhood hash for translation invalidation (0 = single-block).
  int get groupSignature;

  /// Whether classification votes flipped to a different weight tier.
  bool get needsReclassification;
}
