// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause
//
// PR #138 review (P1): `CoherentShiftEvent.memberCount` must be counted
// at the APPLICATION site, never from plan membership. Membership
// (`memberDrift.containsKey(existing)`) is keyed on the cached block
// alone; application is gated in `_mergeImpl` on step-response
// eligibility — a band admission, a viewport-relative fresh block, or a
// carousel-child fresh block never receives the translation — and nothing
// stops a SECOND fresh block from reaching the same cached member through
// such a path in the same capture. The first cut of 2.5.0 counted that
// second block as a member (members=4 while only 3 merges applied the
// shift) and its `MergeResult` said `stepResponseApplied == null`.
//
// Fixture: the three-voter +150 step, plus one extra fresh block in the
// step capture that carries a voter's text at that voter's OLD rect and
// is flagged a horizontal-scroll (carousel) child — it primary-matches
// the same cached member (a carousel fresh may match a non-carousel
// cached; only both-carousel-different-index pairs are refused) but is
// step-response-ineligible, so its merge damps. The event must report 3.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

DefaultTrackedBlock<Object> _block(
  String text, {
  required double top,
  bool carousel = false,
}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(0, top, 100, 20),
      payload: const Object(),
      originalText: text,
      observationCount: 3,
      isHorizontalScrollChild: carousel,
    );

const _texts = [
  'alpha block text one',
  'bravo block text two',
  'charlie block text three',
];

void main() {
  test(
      'a second fresh block reaching a plan member through a '
      'step-response-INELIGIBLE path (carousel child) is not a member: '
      'memberCount equals the merges whose MergeResult applied the shift', () {
    var applied = 0;
    var damped = 0;
    String? carouselStep = 'unset';
    final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
      merger: (existing, fresh, m) {
        if (m.stepResponseApplied == StepResponse.coherentShift) {
          applied++;
        } else {
          damped++;
        }
        if (fresh.isHorizontalScrollChild) {
          carouselStep = m.stepResponseApplied?.name;
        }
        return existing.applyMerge(m);
      },
      missedFrameRetention: 3,
    );
    engine.stabilize([
      for (var i = 0; i < 3; i++) _block(_texts[i], top: 500 + 100.0 * i),
    ]);
    final r = engine.stabilize([
      for (var i = 0; i < 3; i++)
        _block(_texts[i], top: 650 + 100.0 * i), // the +150 step
      // The extra fresh block: voter A's text at A's OLD rect, a carousel
      // child — matches cached A by text, but its merge is ineligible.
      _block(_texts[0], top: 500, carousel: true),
    ]);

    expect(carouselStep, isNull,
        reason: 'precondition: the carousel merge damped (no step applied) — '
            'if this fails the fixture no longer reaches the ineligible '
            'path and proves nothing');
    expect(applied, 3, reason: 'precondition: the three voters applied it');
    expect(damped, 1);
    final e = r.coherentShift;
    expect(e, isNotNull);
    expect(e!.memberCount, applied,
        reason: 'the event summarises APPLIED merges — the first 2.5.0 cut '
            'reported 4 here (plan membership keyed on the cached block)');
    expect(e.memberCount, 3);
    expect(e.adoptedCount, 0);
    expect(e.decidedBy, CoherentShiftSource.quorum);
  });

  test(
      'MergeOutput.stepResponseApplied carries the applied step to a '
      'direct merge() caller — the same value MergeResult reported', () {
    StepResponse? viaResult;
    final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
      stepResponse: StepResponse.snap,
      merger: (existing, fresh, m) {
        viaResult = m.stepResponseApplied;
        return existing.applyMerge(m);
      },
    );
    final cached = _block(_texts[0], top: 500);
    // A 400 px residual on a 20 px block clears snap's threshold.
    final out = engine.merge(_block(_texts[0], top: 900), cached);
    expect(viaResult, StepResponse.snap, reason: 'precondition');
    expect(out.stepResponseApplied, StepResponse.snap,
        reason: 'MergeOutput mirrors MergeResult.stepResponseApplied');
  });
}
