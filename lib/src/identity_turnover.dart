// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

/// The per-capture identity census (2.5.0), on
/// `StabilizationResult.identityTurnover`.
///
/// Every fresh block a `stabilize()` call receives ends up either MERGED
/// into a tracked identity or ADMITTED as a new one; every cached
/// identity nothing matched is either RETAINED (missed-frame retention)
/// or DROPPED. This value reports those four counts so a consumer can
/// classify a capture without reverse-engineering `stableBlocks`:
///
/// - A steady re-sighting: [merged] ≈ [fresh], [admitted] ≈ 0.
/// - A rewrap (font swap, width change): [admittedShare] high on ONE
///   capture with no `StabilizationResult.coherentShift` — the line
///   texts changed, so the engine reset identity (contract U1; the
///   dynamic-reflow validation entry measured 23 of 30 admitted on the
///   rewrap frame, then 29 of 30 merged on the next). Cached geometry the
///   consumer holds for the old identities is stale and should be
///   rebuilt, not translated.
/// - A slab move: `coherentShift` non-null — the identities survived and
///   moved together; see `CoherentShiftEvent`.
///
/// [fresh] (`merged + admitted`) can be smaller than the batch the
/// consumer passed in: intra-batch NMS removes duplicates before
/// matching, and a nested fragment whose host already merged this
/// capture is folded into that merge rather than counted twice.
class IdentityTurnover {
  /// Fresh blocks that merged into a tracked identity this capture —
  /// through the primary match, a band-fallback admission, or a
  /// nested-fragment confirmation.
  final int merged;

  /// Fresh blocks admitted as NEW identities this capture (no match, or a
  /// nested fragment whose host was contradicted).
  final int admitted;

  /// Cached identities nothing matched this capture, kept in the index by
  /// `missedFrameRetention` for a later re-sighting.
  final int retained;

  /// Cached identities that left tracking this capture: retention
  /// expired, superseded by a fresh block covering their region, or
  /// `missedFrameRetention: 0`.
  final int dropped;

  const IdentityTurnover._(
    this.merged,
    this.admitted,
    this.retained,
    this.dropped,
  );

  /// Creates an identity census.
  ///
  /// Throws [ArgumentError] when any count is negative.
  factory IdentityTurnover({
    required int merged,
    required int admitted,
    required int retained,
    required int dropped,
  }) {
    for (final (name, value) in [
      ('merged', merged),
      ('admitted', admitted),
      ('retained', retained),
      ('dropped', dropped),
    ]) {
      if (value < 0) {
        throw ArgumentError.value(value, name, 'must be >= 0');
      }
    }
    return IdentityTurnover._(merged, admitted, retained, dropped);
  }

  /// The all-zero census — the default on a `StabilizationResult` built
  /// by hand, and what an empty capture over an empty engine reports.
  static const none = IdentityTurnover._(0, 0, 0, 0);

  /// Fresh blocks that produced an identity outcome: [merged] +
  /// [admitted].
  int get fresh => merged + admitted;

  /// [admitted] as a share of [fresh]; `0.0` (never NaN) when [fresh] is
  /// zero. The rewrap detector's input: a value near 1.0 on a capture
  /// with no `coherentShift` means the line boxes changed under the same
  /// content.
  double get admittedShare => fresh == 0 ? 0.0 : admitted / fresh;

  @override
  String toString() => 'IdentityTurnover(merged=$merged admitted=$admitted '
      'retained=$retained dropped=$dropped)';
}
