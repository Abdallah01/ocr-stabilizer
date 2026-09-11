// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// The two geometry readings every position-model stage shares (#150
// extraction from `StabilizationEngine`). ONE definition each: the merge's
// agreement computation, the snap threshold, the coherent-shift "moved"
// gate, the clustering tolerance and the adoption tolerance all read these
// functions, so they cannot drift apart (PR #132 review C3 — the 16 px
// fallback used to be written out at three sites).

import '../observation.dart';

/// Jitter allowance multiplier for the agreement-weighted position model:
/// the agreement scale is this multiple of the existing (tracked) block's
/// OWN height (#75; the region's median block height through 1.0.x). A
/// residual equal to the full allowance scores agreement 0; a residual
/// well inside it scores partial agreement.
///
/// Why 3, why the block's own height and not the drift margin, and how
/// the value transfers across OCR engines: `doc/decisions/agreement-jitter-allowance.md`.
const double kAgreementJitterAllowance = 3.0;

/// THE definition of a block's height for the position machinery. A
/// non-finite or non-positive rect counts as 16 px.
double blockHeight(Observation<Object?> block) {
  final h = block.absoluteRect.raw.height;
  return (!h.isFinite || h <= 0) ? 16.0 : h;
}

/// The block's own jitter-allowance scale — [kAgreementJitterAllowance]
/// (3x) times its own height ([blockHeight]). The merge's agreement
/// computation, `StepResponse.snap`'s threshold check and the
/// coherent-shift "moved" gate all reference literally this scale (#116).
double agreementScale(Observation<Object?> existing) =>
    blockHeight(existing) * kAgreementJitterAllowance;
