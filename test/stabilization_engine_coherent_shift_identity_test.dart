// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause
//
// #116: `_detectCoherentShift` builds `memberDrift` -- a map from each
// coherent-shift member's EXISTING block to that member's own frozen
// per-region drift snapshot -- as a plain `Map<T, Offset>`. Every OTHER
// `T`-keyed collection in the engine (`matchedExisting`, the classification/
// carousel vote maps, the contradicted-hosts set, ...) is built with
// `.identity()` on purpose, because `T` is the CONSUMER's type and may
// define VALUE equality -- an Equatable-style block keyed on `originalText`
// only, which this engine explicitly supports (see the batch-NMS
// eviction-identity regression, `stabilization_engine_nms_test.dart`).
//
// `memberDrift` was the one collection that stayed value-keyed. Two
// coherent-shift members that are `==`-equal (same text) but sit in
// DIFFERENT drift regions collapse onto ONE map entry: `containsKey`
// still reports `true` for both existing blocks (nothing looks missing),
// but the LATER member's write silently overwrites the EARLIER member's
// frozen snapshot, so one of the two members' real merge reads back the
// WRONG region's drift.
import 'package:test/test.dart';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

/// Block with VALUE equality on [originalText] only -- copied from
/// `stabilization_engine_nms_test.dart`'s `_EquatableBlock` (the engine's
/// documented Equatable-style consumer-block shape) and extended with
/// [applyMerge] so warm-up captures can thread the engine's own merged
/// position back in as the next capture's tracked baseline (mirroring
/// `DefaultTrackedBlock.applyMerge`, used the same way by
/// `stabilization_engine_coherent_shift_frozen_drift_test.dart`).
class _TextKeyedBlock implements ObservableBlock<void> {
  @override
  final AbsoluteRect absoluteRect;
  @override
  final String originalText;
  @override
  final PositionConfidence positionConfidence;
  @override
  final TextConfidence textConfidence;

  _TextKeyedBlock({
    required this.absoluteRect,
    required this.originalText,
    this.positionConfidence = const PositionConfidence(1.0),
    this.textConfidence = const TextConfidence(1.0),
  });

  _TextKeyedBlock applyMerge(MergeResult m) => _TextKeyedBlock(
        absoluteRect: m.mergedRect,
        originalText: m.winningOriginalText,
        positionConfidence: m.positionConfidence,
        textConfidence: m.textConfidence,
      );

  @override
  bool operator ==(Object other) =>
      other is _TextKeyedBlock && other.originalText == originalText;

  @override
  int get hashCode => originalText.hashCode;

  // ── Inert interface plumbing (unused by this scenario) ──
  @override
  ContainerId? get containerId => null;
  @override
  bool get isViewportRelative => false;
  @override
  bool get isInnerScrollerChild => false;
  @override
  double get innerScrollerTop => 0;
  @override
  bool get isHorizontalScrollChild => false;
  @override
  bool get isFromStickyElement => false;
  @override
  int get sourceQuality => 0;
  @override
  void get payload {}
  @override
  ScrollContext get scrollContext =>
      const ScrollContext(scrollY: 0, scrollX: 0, hzScrollerIndex: -1);
  @override
  StickyFallback get stickyFallback => const StickyFallback(
      scrollY: 0, scrollX: 0, isIc: false, hzScrollerIndex: -1);
  @override
  int get observationCount => 1;
  @override
  Map<int, int> get classificationVotes => const {};
  @override
  Map<int, int> get carouselIdVotes => const {-1: 1};
  @override
  Map<String, TextVote> get textVotes => const {};
  @override
  bool get isProvisional => false;
  @override
  int get provisionalCapturesRemaining => 0;
  @override
  int get groupSignature => 0;
  @override
  bool get needsReclassification => false;
}

_TextKeyedBlock _block(String text, {required double left, required double top}) =>
    _TextKeyedBlock(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, 100, 20),
      originalText: text,
    );

/// Block A and block B carry this SAME text -- the whole point:
/// `_TextKeyedBlock`'s `==` cannot tell them apart, only identity can. Block
/// A lives at left=0 (drift region 0, `top` < 500) and block B at left=300
/// (drift region 1, `top` in [500, 1000)) -- same text, different region.
const _sharedText = 'shared paragraph text alpha and beta';

/// Block C's own text -- distinct, and spatially far enough from A/B (left=
/// 600, region 2) that it never becomes a text- or spatial-match candidate
/// for either. It exists only to satisfy `coherentShiftMinBlocks` (3).
const _anchorText = 'anchor paragraph text gamma only';

String _roleFor(double left) {
  if (left == 0) return 'A';
  if (left == 300) return 'B';
  return 'C';
}

void main() {
  test(
      'coherent-shift memberDrift is identity-keyed: two ==-equal members '
      'in DIFFERENT drift regions each get their OWN frozen snapshot '
      '(#116)', () {
    final driftCorrectionByRole = <String, Offset>{};
    final mergedTopByRole = <String, double>{
      'A': 100.0,
      'B': 700.0,
      'C': 1300.0,
    };

    final engine = StabilizationEngine<_TextKeyedBlock, void>(
      stepResponse: StepResponse.coherentShift,
      missedFrameRetention: 3,
      merger: (existing, fresh, m) {
        final role = _roleFor(fresh.absoluteRect.left);
        driftCorrectionByRole[role] = m.driftCorrection;
        final merged = existing.applyMerge(m);
        mergedTopByRole[role] = merged.absoluteRect.top;
        return merged;
      },
    );

    // Capture 1: seed. Brand-new blocks -- no existing match, so nothing
    // merges and no drift observation is recorded.
    engine.stabilize([
      _block(_sharedText, left: 0, top: mergedTopByRole['A']!),
      _block(_sharedText, left: 300, top: mergedTopByRole['B']!),
      _block(_anchorText, left: 600, top: mergedTopByRole['C']!),
    ]);

    // Captures 2-4: warm-up. Block A drifts +5 EVERY capture, computed off
    // its own last MERGED position (captured via the merger callback above)
    // -- so the raw per-capture drift the engine records
    // (`fresh.top - existing.top`) is exactly 5 every time, regardless of
    // the merge-weight formula. Block B and block C hold perfectly still,
    // so their raw drift stays exactly zero every time. Three captures
    // cross `DriftTracker`'s 3-observation floor (`medianDriftForKey`
    // returns `Offset.zero` below that) for block A's region, leaving
    // region A's median drift non-zero and region B's median drift exactly
    // zero going into the final capture.
    for (var i = 0; i < 3; i++) {
      engine.stabilize([
        _block(_sharedText, left: 0, top: mergedTopByRole['A']! + 5),
        _block(_sharedText, left: 300, top: mergedTopByRole['B']!),
        _block(_anchorText, left: 600, top: mergedTopByRole['C']!),
      ]);
    }

    final regionADrift =
        engine.driftTracker.medianDriftForKey(SpaceKey.normal(0));
    final regionBDrift =
        engine.driftTracker.medianDriftForKey(SpaceKey.normal(1));
    expect(regionADrift, isNot(Offset.zero),
        reason: 'fixture invalid: region 0 (block A\'s space key) must '
            'have built up a non-zero median drift from warm-up before '
            'the final capture, or this test cannot discriminate the bug');
    expect(regionBDrift, Offset.zero,
        reason: 'fixture invalid: region 1 (block B\'s space key) must '
            'stay at zero drift -- block B never moved during warm-up');

    // Capture 5: A, B and C all shift by the SAME large step (dy=200,
    // well past the ~60px agreement-jitter allowance for a 20px-tall
    // block) -- a clean 3-member coherent-shift group. A and B sit in
    // DIFFERENT drift regions and share the SAME text, so they are
    // `==`-equal but never `identical()` -- exactly the pair the buggy
    // value-keyed `memberDrift` map collapses into one entry.
    engine.stabilize([
      _block(_sharedText, left: 0, top: mergedTopByRole['A']! + 200),
      _block(_sharedText, left: 300, top: mergedTopByRole['B']! + 200),
      _block(_anchorText, left: 600, top: mergedTopByRole['C']! + 200),
    ]);

    expect(driftCorrectionByRole['A'], regionADrift,
        reason: 'block A\'s coherent-shift merge must report its OWN '
            'frozen region-0 drift snapshot. With the value-keyed '
            'memberDrift map, A\'s ==-equal-but-different-region sibling '
            '(B) overwrites A\'s entry, so A wrongly reports region 1\'s '
            '(zero) drift instead of its own.');
    expect(driftCorrectionByRole['B'], regionBDrift,
        reason: 'block B\'s coherent-shift merge must report its OWN '
            'frozen region-1 drift snapshot');
  });
}
