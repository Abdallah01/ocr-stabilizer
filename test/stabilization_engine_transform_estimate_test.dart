// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #135 — `StabilizationResult.transformEstimate`: the similarity fit over
// this capture's eligible matched pairs, reported on every result and
// NEVER applied (contract U9 keeps the merge per block). Eligibility is
// the coherent-shift detector's: ordinary primary matches only — no band
// admission, no nested fragment, no provisional cached block, no
// viewport-relative fresh block, no carousel child on either side — and
// unlike the detector it is collected in the REAL match loop, so it
// exists under `damp` and `snap` too. The pairs are raw absolute-rect
// centres, cached -> fresh: no drift correction (a uniform drift lands in
// the translation, a per-region one in the residual), so the estimate is
// independent of the drift tracker's same-capture mutations.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

DefaultTrackedBlock<void> _at(
  Rect r,
  String text, {
  int observations = 3,
  bool carousel = false,
  bool vr = false,
}) =>
    DefaultTrackedBlock<void>(
      absoluteRect: AbsoluteRect(r),
      payload: null,
      originalText: text,
      observationCount: observations,
      isHorizontalScrollChild: carousel,
      isViewportRelative: vr,
    );

StabilizationEngine<DefaultTrackedBlock<void>, void> _engine({
  StepResponse stepResponse = StepResponse.coherentShift,
  int? minPairs,
  BandFallbackConfig bandFallback = const BandFallbackConfig(),
}) =>
    StabilizationEngine<DefaultTrackedBlock<void>, void>(
      merger: (existing, fresh, merge) => existing.applyMerge(merge),
      stepResponse: stepResponse,
      missedFrameRetention: 3,
      bandFallback: bandFallback,
      transformEstimateMinPairs: minPairs ?? 3,
    );

const _texts = [
  'alpha block text one',
  'bravo block text two',
  'charlie block text three',
  'delta block text four',
];

List<DefaultTrackedBlock<void>> _page(
        {double scale = 1.0, double dy = 0, bool vr = false}) =>
    [
      for (var i = 0; i < 4; i++)
        _at(
          Rect.fromLTWH(40 * scale, (500 + 100.0 * i) * scale + dy, 300 * scale,
              20 * scale),
          _texts[i],
          vr: vr,
        ),
    ];

void main() {
  test(
      'a pure zoom about the page origin reports scale k, ~zero '
      'translation, a tiny residual — and the merge itself stays per block '
      '(no coherentShift; the estimate is observed, never applied)', () {
    final engine = _engine();
    engine.stabilize(_page());
    engine.stabilize(_page());
    final r = engine.stabilize(_page(scale: 1.25));
    final e = r.transformEstimate;
    expect(e, isNotNull);
    expect(e!.scale, closeTo(1.25, 1e-9));
    expect(e.translation.dx, closeTo(0, 1e-6));
    expect(e.translation.dy, closeTo(0, 1e-6));
    expect(e.pairCount, 4);
    expect(e.residualPx, closeTo(0, 1e-6));
    expect(e.largestGapShare, closeTo(1 / 3, 1e-9),
        reason: 'four evenly spaced lines: one pitch over three');
    expect(r.coherentShift, isNull, reason: 'scaled displacements never agree');
    expect(r.identityTurnover.merged, 4, reason: 'text-first match holds');
    // Not applied: the merged boxes are damped toward the new geometry,
    // not snapped to scale * cached.
    final tops = r.stableBlocks.map((b) => b.absoluteRect.raw.top).toList()
      ..sort();
    expect(tops.first, greaterThan(500), reason: 'moved toward 625');
    expect(tops.first, lessThan(625), reason: 'but not all the way — damped');
  });

  test(
      'a coherent translation (+150 px step) reports scale ~1 and the '
      'translation, alongside the coherentShift event', () {
    final engine = _engine();
    engine.stabilize(_page());
    engine.stabilize(_page());
    final r = engine.stabilize(_page(dy: 150));
    final e = r.transformEstimate;
    expect(e, isNotNull);
    expect(e!.scale, closeTo(1.0, 1e-9));
    expect(e.translation.dy, closeTo(150, 1e-6));
    expect(e.residualPx, closeTo(0, 1e-6));
    expect(r.coherentShift, isNotNull, reason: 'fixture precondition');
  });

  test(
      'the estimate exists under damp and snap too — it is collected in '
      'the real match loop, not the coherent-shift pre-pass', () {
    for (final sr in [StepResponse.damp, StepResponse.snap]) {
      final engine = _engine(stepResponse: sr);
      engine.stabilize(_page());
      engine.stabilize(_page());
      final e = engine.stabilize(_page(scale: 1.1)).transformEstimate;
      expect(e, isNotNull, reason: '$sr');
      expect(e!.scale, closeTo(1.1, 1e-9), reason: '$sr');
    }
  });

  test(
      'a session\'s first sighting (nothing cached) and a capture with '
      'fewer than transformEstimateMinPairs eligible pairs report null', () {
    final engine = _engine(minPairs: 4);
    expect(engine.stabilize(_page()).transformEstimate, isNull);
    engine.stabilize(_page());
    // Only three of the four lines re-sighted: below the floor of 4.
    final three = _page(scale: 1.1).sublist(0, 3);
    expect(engine.stabilize(three).transformEstimate, isNull);
    // The default floor (3) would have accepted the same capture.
    final loose = _engine();
    loose.stabilize(_page());
    loose.stabilize(_page());
    expect(loose.stabilize(_page(scale: 1.1).sublist(0, 3)).transformEstimate,
        isNotNull);
  });

  test(
      'a carousel-child fresh block is not a pair: its match merges but '
      'is excluded from the fit (the detector\'s eligibility rule)', () {
    final engine = _engine();
    engine.stabilize(_page());
    engine.stabilize(_page());
    // Three clean scaled lines plus a fourth carrying the fourth line's
    // text at its OLD, unscaled box (so it still matches — a carousel
    // fresh block may match a non-carousel cached one) but flagged a
    // horizontal-scroll child. Included, that unmoved pair would pull the
    // scale below 1.25; excluded, the fit stays exact.
    final fresh = _page(scale: 1.25).sublist(0, 3)
      ..add(_at(const Rect.fromLTWH(40, 800, 300, 20), _texts[3],
          carousel: true));
    final r = engine.stabilize(fresh);
    expect(r.identityTurnover.merged, 4, reason: 'the carousel child merged');
    final e = r.transformEstimate;
    expect(e, isNotNull);
    expect(e!.pairCount, 3, reason: 'the ineligible pair is left out');
    expect(e.scale, closeTo(1.25, 1e-9),
        reason: 'an unmoved fourth pair would have dragged the scale down');
  });

  test(
      'a viewport-relative fresh block is not a pair: a page of VR blocks '
      'merges in full and reports no estimate', () {
    final engine = _engine();
    engine.stabilize(_page(vr: true));
    engine.stabilize(_page(vr: true));
    final r = engine.stabilize(_page(scale: 1.25, vr: true));
    expect(r.identityTurnover.merged, 4,
        reason: 'VR matches VR — the pairs exist, they are just ineligible');
    expect(r.transformEstimate, isNull);
  });

  test(
      'a band-fallback admission is not a pair: the admission merges (and '
      'counts in bandStats) but is excluded from the fit', () {
    final engine = _engine(
      bandFallback: const BandFallbackConfig(
        mode: BandFallbackMode.admit,
        candidateObservationFloor: 1,
      ),
    );
    // Three ordinary lines plus one whose text will be corrupted on the
    // re-sighting so that only the band path can match it.
    final seed = _page().sublist(0, 3)
      ..add(_at(const Rect.fromLTWH(40, 800, 300, 20), 'hello world',
          observations: 5));
    engine.stabilize(seed);
    engine.stabilize(seed);
    // The corrupted line sits at its OLD box: included, that unmoved pair
    // would pull the scale below 1.25; excluded, the fit stays exact.
    final fresh = _page(scale: 1.25).sublist(0, 3)
      ..add(_at(const Rect.fromLTWH(40, 800, 300, 20), 'hxlxo wxrxd'));
    final r = engine.stabilize(fresh);
    expect(engine.bandStats.matchesAdmitted, 1, reason: 'fixture precondition');
    expect(r.identityTurnover.merged, 4, reason: 'the admission merged');
    final e = r.transformEstimate;
    expect(e, isNotNull);
    expect(e!.pairCount, 3, reason: 'the band-admitted pair is left out');
    expect(e.scale, closeTo(1.25, 1e-9));
  });

  test(
      'a provisional cached block (a band admission still inside its '
      'window) is not a pair', () {
    // Seed the index with four provisional blocks — the state a band
    // admission leaves behind — and re-sight them scaled.
    final index = SpatialBlockIndex<DefaultTrackedBlock<void>>();
    final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
      merger: (existing, fresh, merge) => existing.applyMerge(merge),
      spatialIndex: index,
    );
    for (var i = 0; i < 4; i++) {
      index.add(DefaultTrackedBlock<void>(
        absoluteRect: AbsoluteRect(Rect.fromLTWH(40, 500 + 100.0 * i, 300, 20)),
        payload: null,
        originalText: _texts[i],
        observationCount: 1,
        isProvisional: true,
        provisionalCapturesRemaining: 2,
      ));
    }
    final r = engine.stabilize(_page(scale: 1.1));
    expect(r.identityTurnover.merged, 4, reason: 'fixture precondition');
    expect(r.transformEstimate, isNull);
  });

  test('transformEstimateMinPairs below 3 is rejected at construction', () {
    expect(() => _engine(minPairs: 1), throwsArgumentError);
    expect(() => _engine(minPairs: 2), throwsArgumentError,
        reason: 'two pairs fit any similarity exactly — residual 0, '
            'arbitrary scale');
    expect(() => _engine(minPairs: 3), returnsNormally);
  });
}
