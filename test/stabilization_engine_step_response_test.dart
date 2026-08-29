import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// STEP RESPONSE (#116)
// =============================================================================
// The agreement-weighted position model damps EVERY residual as jitter,
// including a genuine step (an ad/image finishing load pushes every line
// below it down by a fixed offset — #116). `StepResponse` adds two opt-in
// alternatives to the default `damp` behaviour:
//   - `snap`   per-block re-anchor once a residual clears a multiple of the
//              block's own agreement scale.
//   - `coherentShift` a per-batch translation vote: when enough matched
//              pairs agree on (approximately) the same displacement, that
//              displacement is applied as a batch shift before the normal
//              weighted merge runs against the shifted baseline.
// Both are opt-in (constructor default `StepResponse.damp`) and both are
// scoped to `PositionMergeModel.agreementWeighted` — see the "legacy" group
// below. Neither ever touches a provisional (frozen), nested-fragment, or
// band-fallback-admission merge — those are structurally excluded before
// this file's new code ever runs (`_mergeImpl`'s freeze/nested early
// returns, and the `wasBandFallback` guard).
// =============================================================================

typedef _Block = DefaultTrackedBlock<void>;

/// An engine plus a log of every [MergeResult] its merger callback saw, in
/// order — the same "capture inside the merger callback" pattern
/// `tool/replay/src/replay_session.dart`'s `MergeSample` uses. It is the
/// only place `MergeResult.stepResponseApplied` is observable from outside
/// the engine (mirrors how the replay tool reads it, per the #116 brief).
typedef _Rig = ({StabilizationEngine<_Block, void> engine, List<MergeResult> log});

_Rig _engine({
  StepResponse stepResponse = StepResponse.damp,
  PositionMergeModel model = PositionMergeModel.agreementWeighted,
  BandFallbackConfig bandFallback = const BandFallbackConfig(),
  double snapThresholdMultiplier = 1.5,
  int coherentShiftMinBlocks = 3,
  double coherentShiftMinShare = 0.5,
  double coherentShiftTolerance = 0.5,
}) {
  final log = <MergeResult>[];
  final engine = StabilizationEngine<_Block, void>(
    merger: (existing, fresh, merge) {
      log.add(merge);
      return existing.applyMerge(merge);
    },
    positionMergeModel: model,
    stepResponse: stepResponse,
    bandFallback: bandFallback,
    snapThresholdMultiplier: snapThresholdMultiplier,
    coherentShiftMinBlocks: coherentShiftMinBlocks,
    coherentShiftMinShare: coherentShiftMinShare,
    coherentShiftTolerance: coherentShiftTolerance,
  );
  return (engine: engine, log: log);
}

_Block _at(
  double top, {
  double left = 0,
  double width = 200,
  double height = 30,
  String text = 'stable paragraph text',
  double confidence = 0.9,
  bool isViewportRelative = false,
}) {
  return _Block(
    absoluteRect: AbsoluteRect(Rect.fromLTWH(left, top, width, height)),
    payload: null,
    originalText: text,
    positionConfidence: PositionConfidence.from(confidence),
    textConfidence: TextConfidence.from(confidence),
    isViewportRelative: isViewportRelative,
  );
}

void main() {
  group('StepResponse constructor default', () {
    // #116 A/B (2026-08-29, all 17 streams, corrected agreementWeighted
    // baseline): coherentShift 14/17 vs snap 11/17, zero false-triggered
    // step events on any control stream (snap false-triggered on 4 of 10).
    // The engine now defaults to coherentShift; StepResponse.damp restores
    // the pre-2.3.0 numerics exactly (still a documented, exact-numerics
    // no-op path — see the (a)/(i)/legacy groups below, which explicitly
    // pass damp/legacy and are unaffected by this default change).
    test('defaults to coherentShift', () {
      final engine = StabilizationEngine<_Block, void>(
        merger: (existing, fresh, merge) => existing.applyMerge(merge),
      );
      expect(engine.stepResponse, StepResponse.coherentShift);
    });
  });

  // The four #116 tunables previously had no constructor validation, unlike
  // every other engine config knob (`missedFrameRetention`, the
  // `BandFallbackConfig` fields via `_validateBandFallbackConfig`). Two
  // failure classes matter here specifically because they're SILENT: a NaN
  // multiplier/tolerance makes every comparison false, so the option looks
  // configured but the corresponding StepResponse permanently never fires
  // (mirrors the NaN hazard `_validateBandFallbackConfig`'s own comment
  // documents for `bandLevenshteinFloor`/`bandJaccardFloor`); a
  // non-positive `coherentShiftMinBlocks` makes its own gate
  // (`bestGroup.length < coherentShiftMinBlocks`) permanently false, i.e.
  // unreachable rather than merely lenient.
  group('StepResponse constructor validation', () {
    StabilizationEngine<_Block, void> build({
      double snapThresholdMultiplier = 1.5,
      int coherentShiftMinBlocks = 3,
      double coherentShiftMinShare = 0.5,
      double coherentShiftTolerance = 0.5,
    }) {
      return StabilizationEngine<_Block, void>(
        merger: (existing, fresh, merge) => existing.applyMerge(merge),
        snapThresholdMultiplier: snapThresholdMultiplier,
        coherentShiftMinBlocks: coherentShiftMinBlocks,
        coherentShiftMinShare: coherentShiftMinShare,
        coherentShiftTolerance: coherentShiftTolerance,
      );
    }

    test('snapThresholdMultiplier rejects NaN, non-finite and <= 0', () {
      expect(() => build(snapThresholdMultiplier: double.nan),
          throwsA(isA<ArgumentError>()));
      expect(() => build(snapThresholdMultiplier: double.infinity),
          throwsA(isA<ArgumentError>()));
      expect(() => build(snapThresholdMultiplier: 0.0),
          throwsA(isA<ArgumentError>()));
      expect(() => build(snapThresholdMultiplier: -1.5),
          throwsA(isA<ArgumentError>()));
      expect(() => build(snapThresholdMultiplier: 1.5), returnsNormally);
    });

    test('coherentShiftMinBlocks rejects < 1', () {
      expect(() => build(coherentShiftMinBlocks: 0),
          throwsA(isA<ArgumentError>()));
      expect(() => build(coherentShiftMinBlocks: -3),
          throwsA(isA<ArgumentError>()));
      expect(() => build(coherentShiftMinBlocks: 1), returnsNormally);
    });

    test('coherentShiftMinShare rejects NaN, non-finite and outside [0.0, 1.0]',
        () {
      expect(() => build(coherentShiftMinShare: double.nan),
          throwsA(isA<ArgumentError>()));
      expect(() => build(coherentShiftMinShare: double.infinity),
          throwsA(isA<ArgumentError>()));
      expect(() => build(coherentShiftMinShare: -0.1),
          throwsA(isA<ArgumentError>()));
      expect(() => build(coherentShiftMinShare: 1.1),
          throwsA(isA<ArgumentError>()));
      expect(() => build(coherentShiftMinShare: 0.0), returnsNormally);
      expect(() => build(coherentShiftMinShare: 1.0), returnsNormally);
    });

    test('coherentShiftTolerance rejects NaN, non-finite and negative', () {
      expect(() => build(coherentShiftTolerance: double.nan),
          throwsA(isA<ArgumentError>()));
      expect(() => build(coherentShiftTolerance: double.infinity),
          throwsA(isA<ArgumentError>()));
      expect(() => build(coherentShiftTolerance: -0.1),
          throwsA(isA<ArgumentError>()));
      expect(() => build(coherentShiftTolerance: 0.0), returnsNormally);
    });
  });

  group('(a) damp reproduces the pinned #58 numerics', () {
    test('scale is 3x own height; residual 60 against scale 90 -> 0.7083', () {
      // Reuses the exact expectation pinned in
      // stabilization_engine_position_model_test.dart ("agreement scale is
      // the 3x-own-height jitter allowance") — StepResponse.damp (the
      // default) must not perturb the #58 numerics at all.
      final rig = _engine(stepResponse: StepResponse.damp);
      // confidence 0.5 to match the original fixture exactly (this repo's
      // `_at` default in stabilization_engine_position_model_test.dart) —
      // the pinned 0.7083 depends on the confidence seed.
      for (final top in [10.0, 10.0, 10.0]) {
        rig.engine.stabilize([_at(top, confidence: 0.5)]);
      }
      final merged =
          rig.engine.stabilize([_at(70.0, confidence: 0.5)]).stableBlocks.single;
      expect(merged.positionConfidence.raw, closeTo(0.7083, 0.005));
      expect(rig.log.last.stepResponseApplied, isNull,
          reason: 'damp never sets a step response');
    });
  });

  group('(b) snap re-anchors past the threshold', () {
    test('5x at top=100 then a jump to top=400: damp stays well below 400, '
        'snap lands exactly on 400 with observationCount 6 and the flag set',
        () {
      final damp = _engine(stepResponse: StepResponse.damp);
      final snap = _engine(stepResponse: StepResponse.snap);
      for (final rig in [damp, snap]) {
        for (var i = 0; i < 5; i++) {
          rig.engine.stabilize([_at(100)]);
        }
      }
      final dampResult = damp.engine.stabilize([_at(400)]).stableBlocks.single;
      final snapResult = snap.engine.stabilize([_at(400)]).stableBlocks.single;

      expect(dampResult.absoluteRect.raw.top, lessThan(250),
          reason: 'sanity: damp must still be damping most of the 300px '
              'jump — a 5-times-observed block is positionally sticky');
      expect(snapResult.absoluteRect.raw.top, closeTo(400.0, 0.01),
          reason: 'residual 300 > snapThresholdMultiplier(1.5) x scale '
              '(3 x 30 = 90) = 135 -> full re-anchor to the corrected rect');
      expect(snapResult.observationCount, 6);
      expect(snap.log.last.stepResponseApplied, StepResponse.snap);
      expect(damp.log.last.stepResponseApplied, isNull);
    });
  });

  group('(c) snap does not fire on sub-threshold jitter', () {
    test('12px residual (well under 135) merges identically under snap and '
        'damp', () {
      final damp = _engine(stepResponse: StepResponse.damp);
      final snap = _engine(stepResponse: StepResponse.snap);
      for (final rig in [damp, snap]) {
        for (var i = 0; i < 3; i++) {
          rig.engine.stabilize([_at(100)]);
        }
      }
      final dampResult = damp.engine.stabilize([_at(112)]).stableBlocks.single;
      final snapResult = snap.engine.stabilize([_at(112)]).stableBlocks.single;
      expect(snapResult.absoluteRect.raw.top,
          closeTo(dampResult.absoluteRect.raw.top, 0.001));
      expect(snapResult.positionConfidence.raw,
          closeTo(dampResult.positionConfidence.raw, 0.0001));
      expect(snap.log.last.stepResponseApplied, isNull);
    });
  });

  group('(d) snap never fires on a provisional (frozen) block', () {
    test('a huge residual on a frozen block still freezes: unchanged rect, '
        'unchanged observationCount, no flag', () {
      final rig = _engine(
        stepResponse: StepResponse.snap,
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
        ),
      );
      final engine = rig.engine;

      // Seed + band-admit exactly like stabilization_engine_band_admit_test
      // (`_at` has no observationCount parameter, so build the seed block
      // directly).
      final seeded = engine.stabilize([
        _Block(
          absoluteRect: AbsoluteRect(Rect.fromLTWH(0, 0, 200, 30)),
          payload: null,
          originalText: 'hello world',
          observationCount: 5,
        )
      ]).stableBlocks.single;
      expect(seeded.observationCount, greaterThanOrEqualTo(5));

      final bandFresh = _Block(
        absoluteRect: AbsoluteRect(Rect.fromLTWH(0, 0, 200, 30)),
        payload: null,
        // 7 of 11 significant chars differ: fails primary Lev 0.70 AND
        // Jaccard 0.80, clears the band floors (same fixture text as the
        // admit test).
        originalText: 'hxlxo wxrxd',
      );
      final admitted = engine.stabilize([bandFresh]).stableBlocks.firstWhere(
          (b) => b.absoluteRect.raw.left == 0);
      expect(admitted.isProvisional, isTrue,
          reason: 'sanity: the fixture must actually reach band admission');
      expect(engine.bandStats.matchesAdmitted, 1);
      final obsBeforeFreeze = admitted.observationCount;
      final topBeforeFreeze = admitted.absoluteRect.raw.top;

      // Re-observe the now-provisional block with a big jump (150px, still
      // inside the 200px default spatial bucket so it is found as a
      // candidate) and the text it currently holds, so it matches. If snap
      // protection were broken this merge would land at top=150.
      final refresh = _Block(
        absoluteRect: AbsoluteRect(Rect.fromLTWH(0, 150, 200, 30)),
        payload: null,
        originalText: admitted.originalText,
      );
      final after = engine.stabilize([refresh]).stableBlocks.firstWhere(
          (b) => b.absoluteRect.raw.left == 0);

      expect(after.observationCount, obsBeforeFreeze,
          reason: 'freeze path signature (#57): frozen captures accrue no '
              'observation evidence');
      expect(after.absoluteRect.raw.top, topBeforeFreeze,
          reason: 'a provisional block never moves, regardless of '
              'stepResponse');
      expect(rig.log.last.stepResponseApplied, isNull);
      expect(rig.log.last.isProvisional, isTrue,
          reason: 'sanity: this merge really did go through the freeze '
              'path (still provisional, remaining > 0)');
    });
  });

  group('(e) coherentShift: 4 of 5 move +150, 1 stays', () {
    // The jump (150px) is deliberately kept under the spatial index's
    // default 200px bucket height: `SpatialBlockIndex.candidates` only
    // offers the 3x3 cell neighborhood around the FRESH block's own cell
    // (`absoluteCellKey`, rounded on the block's center), so a jump at or
    // beyond one full bucket height can round to a cell more than 1 away
    // from the existing block's cell and silently fail to match at all —
    // an unmatched fresh block is admitted as new AT ITS OWN (already
    // shifted) position, which would make every assertion below pass
    // vacuously instead of exercising the vote. A jump strictly under one
    // bucket height crosses at most one cell boundary regardless of
    // phase, so matching is guaranteed. 150 still clears the "moved"
    // threshold (scale = 3 x height 30 = 90).
    test('the 4 land at exactly +150, the 1 is damped as before, flags set '
        'on the 4 only', () {
      final coherent = _engine(stepResponse: StepResponse.coherentShift);
      final damp = _engine(stepResponse: StepResponse.damp);

      _Block mover(double top, String text) =>
          _at(top, text: text, height: 30);
      List<_Block> batch1() => [
            mover(50, 'alpha block text'),
            mover(600, 'bravo block text'),
            mover(1100, 'charlie block text'),
            mover(1600, 'delta block text'),
            mover(2100, 'echo block text'),
          ];
      List<_Block> batch2() => [
            mover(200, 'alpha block text'), // +150
            mover(750, 'bravo block text'), // +150
            mover(1250, 'charlie block text'), // +150
            mover(1750, 'delta block text'), // +150
            mover(2120, 'echo block text'), // +20 (stays, sub-scale jitter)
          ];

      coherent.engine.stabilize(batch1());
      damp.engine.stabilize(batch1());
      final coherentResult = coherent.engine.stabilize(batch2()).stableBlocks;
      final dampResult = damp.engine.stabilize(batch2()).stableBlocks;

      _Block byText(List<_Block> blocks, String text) =>
          blocks.firstWhere((b) => b.originalText == text);

      for (final text in [
        'alpha block text',
        'bravo block text',
        'charlie block text',
        'delta block text',
      ]) {
        final expectedTop = byText(batch1(), text).absoluteRect.raw.top + 150;
        final got = byText(coherentResult, text);
        expect(got.observationCount, 2,
            reason: '$text: sanity — must have actually MERGED (obsCount '
                '2), not been admitted as an unmatched new block (obsCount '
                '1), or the exact-landing assertion below is vacuous');
        expect(got.absoluteRect.raw.top, closeTo(expectedTop, 0.01),
            reason: '$text: coherentShift must land exactly on the group '
                'median displacement, not a damped fraction of it');
      }

      final echoCoherent = byText(coherentResult, 'echo block text');
      final echoDamp = byText(dampResult, 'echo block text');
      expect(echoCoherent.observationCount, 2,
          reason: 'sanity: the non-mover must also have merged');
      expect(echoCoherent.absoluteRect.raw.top,
          closeTo(echoDamp.absoluteRect.raw.top, 0.01),
          reason: 'the non-mover must be damped exactly as it would be '
              'under StepResponse.damp — it never joins the vote');
      expect(echoCoherent.absoluteRect.raw.top, isNot(closeTo(2120.0, 5.0)),
          reason: 'sanity: damp still moves it SOME amount toward 2120, so '
              'this is not a vacuously-unmatched block either');

      final movedFlags = [
        for (final text in [
          'alpha block text',
          'bravo block text',
          'charlie block text',
          'delta block text',
        ])
          coherent.log
              .firstWhere((m) => m.winningOriginalText == text)
              .stepResponseApplied,
      ];
      expect(movedFlags, everyElement(StepResponse.coherentShift));
      final echoFlag = coherent.log
          .firstWhere((m) => m.winningOriginalText == 'echo block text')
          .stepResponseApplied;
      expect(echoFlag, isNull,
          reason: 'the non-mover never receives a step response');
    });
  });

  group('(f) coherentShift: 2 movers among 5 -> no shift (min blocks)', () {
    test('below coherentShiftMinBlocks, the batch is bit-identical to damp',
        () {
      final coherent = _engine(stepResponse: StepResponse.coherentShift);
      final damp = _engine(stepResponse: StepResponse.damp);

      _Block mover(double top, String text) => _at(top, text: text);
      List<_Block> batch1() => [
            mover(50, 'one block text'),
            mover(600, 'two block text'),
            mover(1100, 'three block text'),
            mover(1600, 'four block text'),
            mover(2100, 'five block text'),
          ];
      List<_Block> batch2() => [
            mover(200, 'one block text'), // +150 (mover)
            mover(750, 'two block text'), // +150 (mover)
            mover(1100, 'three block text'), // stays
            mover(1600, 'four block text'), // stays
            mover(2100, 'five block text'), // stays
          ];

      coherent.engine.stabilize(batch1());
      damp.engine.stabilize(batch1());
      final coherentResult = coherent.engine.stabilize(batch2()).stableBlocks;
      final dampResult = damp.engine.stabilize(batch2()).stableBlocks;

      expect(coherentResult.length, dampResult.length);
      for (final text in ['one block text', 'two block text']) {
        final got = coherentResult.firstWhere((b) => b.originalText == text);
        expect(got.observationCount, 2,
            reason: '$text: sanity — both movers must have actually '
                'MERGED, or "no shift" below would be vacuous');
      }
      for (final c in coherentResult) {
        final d = dampResult.firstWhere((b) => b.originalText == c.originalText);
        expect(c.absoluteRect.raw.top, closeTo(d.absoluteRect.raw.top, 1e-9),
            reason: '${c.originalText}: only 2 moved (< coherentShiftMin'
                'Blocks 3) — the whole batch must fall back to damp');
        expect(c.positionConfidence.raw,
            closeTo(d.positionConfidence.raw, 1e-9));
      }
      expect(coherent.log.every((m) => m.stepResponseApplied == null), isTrue);
    });

    // `_detectCoherentShift` gates on min-blocks TWICE: once on the total
    // moved count (the case above — 2 movers never even reach clustering)
    // and again on the WINNING cluster's own size (this case — 4 movers
    // split evenly into two clusters of 2, so the total clears
    // coherentShiftMinBlocks and the winning cluster clears
    // coherentShiftMinShare at exactly 0.5, but the cluster itself is
    // still below coherentShiftMinBlocks). Isolating this second gate
    // matters for mutation coverage: the case above alone cannot tell the
    // two checks apart.
    test('4 movers split evenly into two size-2 clusters: the winning '
        'cluster clears the share gate (50%) but not its own min-blocks '
        'gate -> still no shift', () {
      final coherent = _engine(stepResponse: StepResponse.coherentShift);
      final damp = _engine(stepResponse: StepResponse.damp);

      _Block mover(double top, String text) => _at(top, text: text);
      List<_Block> batch1() => [
            mover(50, 'one block text'),
            mover(600, 'two block text'),
            mover(1100, 'three block text'),
            mover(1600, 'four block text'),
          ];
      // Cluster A: +120 (one, two). Cluster B: +190 (three, four). Gap 70px
      // far exceeds tolerance (0.5 x 30 = 15), so they never merge into
      // one group of 4 — the largest group is size 2 either way.
      List<_Block> batch2() => [
            mover(170, 'one block text'), // +120
            mover(720, 'two block text'), // +120
            mover(1290, 'three block text'), // +190
            mover(1790, 'four block text'), // +190
          ];

      coherent.engine.stabilize(batch1());
      damp.engine.stabilize(batch1());
      final coherentResult = coherent.engine.stabilize(batch2()).stableBlocks;
      final dampResult = damp.engine.stabilize(batch2()).stableBlocks;

      for (final c in coherentResult) {
        expect(c.observationCount, 2,
            reason: '${c.originalText}: sanity — must have actually '
                'merged, or "no shift" below would be vacuous');
      }
      for (final c in coherentResult) {
        final d = dampResult.firstWhere((b) => b.originalText == c.originalText);
        expect(c.absoluteRect.raw.top, closeTo(d.absoluteRect.raw.top, 1e-9),
            reason: '${c.originalText}: the winning 2-block cluster is '
                'still below coherentShiftMinBlocks (3)');
      }
      expect(coherent.log.every((m) => m.stepResponseApplied == null), isTrue);
    });
  });

  group('(g) coherentShift: 3 movers with different vectors -> no shift '
      '(tolerance)', () {
    test('displacements too spread out to cluster: bit-identical to damp',
        () {
      final coherent = _engine(stepResponse: StepResponse.coherentShift);
      final damp = _engine(stepResponse: StepResponse.damp);

      _Block mover(double top, String text) => _at(top, text: text);
      List<_Block> batch1() => [
            mover(50, 'one block text'),
            mover(600, 'two block text'),
            mover(1100, 'three block text'),
          ];
      // Displacements +100, +150, +190: each exceeds the "moved" scale
      // (90), and each consecutive gap (50px, 40px) far exceeds
      // coherentShiftTolerance(0.5) x height(30) = 15px, so no run of
      // >= coherentShiftMinBlocks(3) can form. All three stay under the
      // 200px bucket height so every pair is guaranteed to match spatially
      // (see the note on group (e)).
      List<_Block> batch2() => [
            mover(150, 'one block text'), // +100
            mover(750, 'two block text'), // +150
            mover(1290, 'three block text'), // +190
          ];

      coherent.engine.stabilize(batch1());
      damp.engine.stabilize(batch1());
      final coherentResult = coherent.engine.stabilize(batch2()).stableBlocks;
      final dampResult = damp.engine.stabilize(batch2()).stableBlocks;

      for (final c in coherentResult) {
        expect(c.observationCount, 2,
            reason: '${c.originalText}: sanity — must have actually '
                'merged, or "no shift" below would be vacuous');
      }
      for (final c in coherentResult) {
        final d = dampResult.firstWhere((b) => b.originalText == c.originalText);
        expect(c.absoluteRect.raw.top, closeTo(d.absoluteRect.raw.top, 1e-9));
      }
      expect(coherent.log.every((m) => m.stepResponseApplied == null), isTrue);
    });
  });

  group('(h) coherentShift: VR blocks never vote nor shift', () {
    test('a VR block that moves like the group is still damped, not '
        'snapped to the group shift', () {
      final coherent = _engine(stepResponse: StepResponse.coherentShift);
      final damp = _engine(stepResponse: StepResponse.damp);

      _Block mover(double top, String text, {bool vr = false}) =>
          _at(top, text: text, isViewportRelative: vr);
      List<_Block> batch1() => [
            mover(50, 'one block text'),
            mover(600, 'two block text'),
            mover(1100, 'three block text'),
            mover(0, 'vr banner text', vr: true),
          ];
      List<_Block> batch2() => [
            mover(200, 'one block text'), // +150
            mover(750, 'two block text'), // +150
            mover(1250, 'three block text'), // +150
            mover(150, 'vr banner text', vr: true), // +150 too, but VR
          ];

      coherent.engine.stabilize(batch1());
      damp.engine.stabilize(batch1());
      final coherentResult = coherent.engine.stabilize(batch2()).stableBlocks;
      final dampResult = damp.engine.stabilize(batch2()).stableBlocks;

      final vrCoherent =
          coherentResult.firstWhere((b) => b.originalText == 'vr banner text');
      final vrDamp =
          dampResult.firstWhere((b) => b.originalText == 'vr banner text');
      expect(vrCoherent.observationCount, 2,
          reason: 'sanity: the VR block must have actually merged');
      expect(vrCoherent.absoluteRect.raw.top,
          closeTo(vrDamp.absoluteRect.raw.top, 0.01),
          reason: 'the VR block must be damped exactly as under '
              'StepResponse.damp — it never joins the vote despite a '
              'matching displacement');
      expect(vrCoherent.absoluteRect.raw.top, isNot(closeTo(150.0, 5.0)),
          reason: 'sanity: prove it was NOT snapped to the group shift');

      final batch1Tops = {
        'one block text': 50.0,
        'two block text': 600.0,
        'three block text': 1100.0,
      };
      for (final text in batch1Tops.keys) {
        final got =
            coherentResult.firstWhere((b) => b.originalText == text);
        expect(got.observationCount, 2,
            reason: '$text: sanity — must have actually merged');
        expect(got.absoluteRect.raw.top, closeTo(batch1Tops[text]! + 150, 0.01),
            reason: '$text: the 3 non-VR movers must still form a valid '
                'group without the VR block diluting the share');
      }

      final vrFlag = coherent.log
          .firstWhere((m) => m.winningOriginalText == 'vr banner text')
          .stepResponseApplied;
      expect(vrFlag, isNull);
    });

    // #116 finding D: only the VR exclusion above was tested for
    // coherentShift; carousel children get the identical treatment in
    // `_detectCoherentShift`'s eligible-pairs loop
    // (`fresh.isHorizontalScrollChild || existing.isHorizontalScrollChild`)
    // but had no test proving it.
    test('a carousel-child block that moves like the group is still '
        'damped, not snapped to the group shift', () {
      final coherent = _engine(stepResponse: StepResponse.coherentShift);
      final damp = _engine(stepResponse: StepResponse.damp);

      const carousel = ScrollContext(hzScrollerIndex: 0);
      _Block carouselMover(double top, String text) => _Block(
            absoluteRect: AbsoluteRect(Rect.fromLTWH(0, top, 200, 30)),
            payload: null,
            originalText: text,
            isHorizontalScrollChild: true,
            scrollContext: carousel,
          );
      List<_Block> batch1() => [
            _at(50, text: 'one block text'),
            _at(600, text: 'two block text'),
            _at(1100, text: 'three block text'),
            carouselMover(0, 'carousel card text'),
          ];
      List<_Block> batch2() => [
            _at(200, text: 'one block text'), // +150
            _at(750, text: 'two block text'), // +150
            _at(1250, text: 'three block text'), // +150
            carouselMover(150, 'carousel card text'), // +150 too, but carousel
          ];

      coherent.engine.stabilize(batch1());
      damp.engine.stabilize(batch1());
      final coherentResult = coherent.engine.stabilize(batch2()).stableBlocks;
      final dampResult = damp.engine.stabilize(batch2()).stableBlocks;

      final carouselCoherent = coherentResult
          .firstWhere((b) => b.originalText == 'carousel card text');
      final carouselDamp =
          dampResult.firstWhere((b) => b.originalText == 'carousel card text');
      expect(carouselCoherent.observationCount, 2,
          reason: 'sanity: the carousel block must have actually merged');
      expect(carouselCoherent.absoluteRect.raw.top,
          closeTo(carouselDamp.absoluteRect.raw.top, 0.01),
          reason: 'the carousel-child block must be damped exactly as under '
              'StepResponse.damp — it never joins the vote despite a '
              'matching displacement');
      expect(carouselCoherent.absoluteRect.raw.top, isNot(closeTo(150.0, 5.0)),
          reason: 'sanity: prove it was NOT snapped to the group shift');

      final carouselFlag = coherent.log
          .firstWhere((m) => m.winningOriginalText == 'carousel card text')
          .stepResponseApplied;
      expect(carouselFlag, isNull);
    });
  });

  group('(k) snap never re-anchors a VR or carousel-child block, even via '
      'merge() called directly (#116 finding D)', () {
    // _detectCoherentShift already excludes viewport-relative and
    // horizontal-scroll-child blocks from its eligible-pairs computation
    // (group (h) above). `_mergeImpl`'s SNAP branch had no equivalent
    // exclusion — `stepResponseEligible` only checked `wasBandFallback`
    // and `positionMergeModel`. These tests call the PUBLIC `merge()`
    // entry point directly (not `stabilize()`) to prove the fix lives in
    // `_mergeImpl` itself, reachable by any consumer that does its own
    // block matching — not merely a `stabilize()`-loop side effect.
    test('a VR block: residual well past threshold, snap must still not '
        'fire', () {
      final rig = _engine(stepResponse: StepResponse.snap);
      final existing = _at(100, isViewportRelative: true);
      final fresh = _at(400, isViewportRelative: true);
      final output = rig.engine.merge(fresh, existing);

      expect(rig.log.last.stepResponseApplied, isNull,
          reason: 'a viewport-relative block must never be snapped — a '
              'different coordinate contract than the page-absolute '
              'shift snap re-anchors within');
      expect(output.merged.absoluteRect.raw.top, closeTo(250.0, 0.01),
          reason: 'without snap firing, the merge must fall back to '
              "damp's ordinary weighted-average lerp (w=0.5 for two "
              '0.9-confidence, single-observation blocks -> exact '
              'midpoint of 100 and 400) instead of a full re-anchor to '
              '400');
    });

    test('a carousel-child block: residual well past threshold, snap must '
        'still not fire', () {
      final rig = _engine(stepResponse: StepResponse.snap);
      const carousel = ScrollContext(hzScrollerIndex: 0);
      final existing = _Block(
        absoluteRect: const AbsoluteRect(Rect.fromLTWH(0, 100, 200, 30)),
        payload: null,
        originalText: 'stable paragraph text',
        isHorizontalScrollChild: true,
        scrollContext: carousel,
      );
      final fresh = _Block(
        absoluteRect: const AbsoluteRect(Rect.fromLTWH(0, 400, 200, 30)),
        payload: null,
        originalText: 'stable paragraph text',
        isHorizontalScrollChild: true,
        scrollContext: carousel,
      );
      final output = rig.engine.merge(fresh, existing);

      expect(rig.log.last.stepResponseApplied, isNull,
          reason: 'a horizontal-scroll-child (carousel) block must never '
              'be snapped — carousel motion is not page-scroll motion, '
              "matching _detectCoherentShift's own exclusion");
      expect(output.merged.absoluteRect.raw.top, closeTo(250.0, 0.01),
          reason: 'without snap firing, the merge must fall back to '
              "damp's ordinary weighted-average lerp (w=0.5 for two "
              '0.9-confidence, single-observation blocks -> exact '
              'midpoint of 100 and 400) instead of a full re-anchor to '
              '400');
    });
  });

  group('(i) coherentShift on a static batch is bit-identical to damp', () {
    test('nothing moved: every rect and confidence matches damp exactly',
        () {
      final coherent = _engine(stepResponse: StepResponse.coherentShift);
      final damp = _engine(stepResponse: StepResponse.damp);

      List<_Block> batch(int n) => [
            for (var i = 0; i < n; i++)
              _at(i * 200.0, text: 'block number $i'),
          ];

      coherent.engine.stabilize(batch(6));
      damp.engine.stabilize(batch(6));
      final coherentResult = coherent.engine.stabilize(batch(6)).stableBlocks;
      final dampResult = damp.engine.stabilize(batch(6)).stableBlocks;

      expect(coherentResult, isNotEmpty);
      expect(coherentResult.length, dampResult.length);
      for (final c in coherentResult) {
        final d = dampResult.firstWhere((b) => b.originalText == c.originalText);
        expect(c.absoluteRect.raw.left, d.absoluteRect.raw.left);
        expect(c.absoluteRect.raw.top, d.absoluteRect.raw.top);
        expect(c.absoluteRect.raw.width, d.absoluteRect.raw.width);
        expect(c.absoluteRect.raw.height, d.absoluteRect.raw.height);
        expect(c.positionConfidence.raw, d.positionConfidence.raw);
      }
    });
  });

  // #116 finding E: `_detectCoherentShift`'s two remaining force-unwraps
  // (the final tx/ty computation) are safe by construction — `bestGroup`
  // is checked non-null immediately above them and is never empty (every
  // window searched has size >= coherentShiftMinBlocks, and the
  // constructor rejects coherentShiftMinBlocks < 1). This group pins the
  // TRULY empty candidate set — a first-ever capture, before anything has
  // been established to match against at all — as an explicit regression
  // test rather than relying on it being an implicit side effect of every
  // other group's own first `stabilize()` call.
  group('(k2) coherentShift on a first-ever capture never crashes on an '
      'empty candidate set', () {
    test('no established blocks to match against yet: ordinary admission, '
        'no coherent-shift vote possible', () {
      final rig = _engine(stepResponse: StepResponse.coherentShift);
      final result = rig.engine.stabilize([
        _at(50, text: 'alpha block'),
        _at(600, text: 'bravo block'),
        _at(1100, text: 'charlie block'),
      ]);

      expect(result.stableBlocks, hasLength(3),
          reason: 'a first-ever capture matches nothing — every fresh '
              'block is admitted as new, not merged');
      for (final b in result.stableBlocks) {
        expect(b.observationCount, 1);
      }
      expect(rig.log, isEmpty,
          reason: 'no merges happened at all — the merger callback is '
              'never invoked for a brand-new admission, so there is '
              'nothing for a coherent-shift vote to even consider');
    });
  });

  group('(j) neither option touches a nested-fragment or band-fallback '
      'merge', () {
    const kPara = Rect.fromLTWH(33, 754, 300, 52);
    const kLine = Rect.fromLTWH(33, 762, 280, 18);
    const kParaText =
        'The quick brown fox jumps over the lazy dog near the river bank';
    const kLineText = 'The quick brown fox jumps';

    for (final sr in [StepResponse.snap, StepResponse.coherentShift]) {
      test('nested-fragment confirmation ($sr): flag null, geometry '
          'untouched', () {
        final rig = _engine(stepResponse: sr);
        rig.engine.stabilize(
            [_Block(absoluteRect: const AbsoluteRect(kPara), payload: null, originalText: kParaText)]);
        final host = rig.engine
            .stabilize([
              _Block(
                  absoluteRect: const AbsoluteRect(kPara),
                  payload: null,
                  originalText: kParaText)
            ])
            .stableBlocks
            .single;

        final fragment = rig.engine
            .stabilize([
              _Block(
                  absoluteRect: const AbsoluteRect(kLine),
                  payload: null,
                  originalText: kLineText)
            ])
            .stableBlocks
            .single;

        expect(rig.log.last.isNestedFragment, isTrue,
            reason: 'sanity: the fixture must actually reach the nested '
                'path');
        expect(fragment.absoluteRect.raw, host.absoluteRect.raw,
            reason: 'nested confirmations never move — geometry is the '
                "host's, always");
        expect(rig.log.last.stepResponseApplied, isNull);
      });

      test('band-fallback admission ($sr): flag null even though the '
          'admission runs the full merge math', () {
        final rig = _engine(
          stepResponse: sr,
          bandFallback: const BandFallbackConfig(
            mode: BandFallbackMode.admit,
            candidateObservationFloor: 1,
          ),
        );
        rig.engine.stabilize([
          _Block(
              absoluteRect: AbsoluteRect(Rect.fromLTWH(0, 0, 200, 30)),
              payload: null,
              originalText: 'hello world',
              observationCount: 5)
        ]);
        rig.engine.stabilize([
          _Block(
              absoluteRect: AbsoluteRect(Rect.fromLTWH(0, 0, 200, 30)),
              payload: null,
              originalText: 'hxlxo wxrxd')
        ]);
        expect(rig.engine.bandStats.matchesAdmitted, 1,
            reason: 'sanity: the fixture must actually band-admit');
        expect(rig.log.last.isProvisional, isTrue);
        expect(rig.log.last.stepResponseApplied, isNull);
      });
    }
  });

  group('legacy: step response is a documented no-op', () {
    test('snap under PositionMergeModel.legacy never fires', () {
      final legacyDamp =
          _engine(model: PositionMergeModel.legacy, stepResponse: StepResponse.damp);
      final legacySnap =
          _engine(model: PositionMergeModel.legacy, stepResponse: StepResponse.snap);
      for (final rig in [legacyDamp, legacySnap]) {
        for (var i = 0; i < 5; i++) {
          rig.engine.stabilize([_at(100)]);
        }
      }
      final dampResult =
          legacyDamp.engine.stabilize([_at(400)]).stableBlocks.single;
      final snapResult =
          legacySnap.engine.stabilize([_at(400)]).stableBlocks.single;
      expect(snapResult.absoluteRect.raw.top, dampResult.absoluteRect.raw.top,
          reason: 'legacy has no residual/scale concept for snap to gate '
              'on — StepResponse is a documented no-op under '
              'PositionMergeModel.legacy');
      expect(legacySnap.log.last.stepResponseApplied, isNull);
    });

    test('coherentShift under PositionMergeModel.legacy never detects a '
        'shift', () {
      final rig = _engine(
          model: PositionMergeModel.legacy,
          stepResponse: StepResponse.coherentShift);
      _Block mover(double top, String text) => _at(top, text: text);
      rig.engine.stabilize([
        mover(50, 'one block text'),
        mover(600, 'two block text'),
        mover(1100, 'three block text'),
        mover(1600, 'four block text'),
      ]);
      rig.engine.stabilize([
        mover(350, 'one block text'),
        mover(900, 'two block text'),
        mover(1400, 'three block text'),
        mover(1900, 'four block text'),
      ]);
      expect(rig.log.every((m) => m.stepResponseApplied == null), isTrue);
    });
  });
}
