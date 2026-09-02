// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'dart:convert';
import 'dart:io';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

import '../tool/replay/src/capture_stream.dart';
import '../tool/replay/src/replay_session.dart';

// =============================================================================
// README DEMO-GIF PROVENANCE (#106 review)
// =============================================================================
// The README caption calls the demo GIF "engine output, not an
// illustration". The pixel half of that chain (render_demo_gif.py) stays
// declared-tier, but the ENGINE half — the substantive claim — is enforced
// here: the committed jitter corpus really contains per-frame raw box
// scatter, and replaying it through the engine's DEFAULT configuration
// really damps it, in the exact page region the GIF shows. If the corpus
// is swapped, the default model changes, or stabilization stops damping
// this stream, the caption is false and this test goes red.
//
// #122 added a second claim to both captions: the committed frames were
// rendered under the pre-2.3.0 `StepResponse.damp`, and re-dumping the
// same corpus under the current default is byte-identical, so the
// captions' "defaults" wording survives without a re-render. That
// comparison was a one-time manual dump diff; [dumpDemoFrames] re-runs it
// here on every test run, for BOTH corpora, so neither the equality nor
// the "coherentShift never fires on this control stream" reason for it
// stays a prose claim.

/// Replays [stream] through `tool/replay/dump_frames.dart`'s construction —
/// the tool that renders both README demo GIFs — and returns the frame dump
/// it would write, plus every step response the engine actually applied.
///
/// Each capture is returned JSON-encoded, so comparing two dumps is
/// literally the captions' "byte-identical frames and counts" claim, over
/// the same three per-capture sets `dump_frames.dart` writes (`raw` /
/// `stable` / `tracked`). One string per capture rather than one for the
/// whole dump so a mismatch reports capture indices instead of printing
/// two 50 KB blobs.
///
/// [retention] is that corpus's documented render value (`missedFrameRetention`
/// — see each corpus entry's dump command). [stepResponse] left null
/// constructs the engine exactly as `dump_frames.dart` does since #122:
/// unset, so it follows `StabilizationEngine`'s own default; the returned
/// `engine` is what each GIF's canary reads that default off.
({
  StabilizationEngine<ReplayBlock, Object> engine,
  List<String> frames,
  List<StepResponse> applied,
}) dumpDemoFrames(
  CaptureStream stream, {
  required int retention,
  StepResponse? stepResponse,
}) {
  final applied = <StepResponse>[];
  ReplayBlock merge(ReplayBlock existing, ReplayBlock fresh, MergeResult m) {
    final s = m.stepResponseApplied;
    if (s != null) applied.add(s);
    return existing.applyMerge(m);
  }

  // Two ctor calls, not one with a nullable argument: "left unset" is the
  // thing under test on the default arm — passing a resolved value would
  // read the default here instead of in the engine.
  final engine = stepResponse == null
      ? StabilizationEngine<ReplayBlock, Object>(
          positionMergeModel: PositionMergeModel.agreementWeighted,
          missedFrameRetention: retention,
          merger: merge,
        )
      : StabilizationEngine<ReplayBlock, Object>(
          positionMergeModel: PositionMergeModel.agreementWeighted,
          missedFrameRetention: retention,
          stepResponse: stepResponse,
          merger: merge,
        );
  final viewport = stream.viewport;
  if (viewport != null) {
    engine.updateViewport(
      viewportWidth: viewport.width,
      viewportHeight: viewport.height,
    );
  }
  // The same applier and default policy dump_frames.dart runs, so this
  // dump cannot drift from the committed one.
  final buckets = BucketPolicyApplier(engine, BucketPolicy.auto);
  final frames = <String>[];
  for (final batch in stream.batches) {
    buckets.beforeBatch(batch);
    final result = engine.stabilize(batch.blocks);
    Map<String, Object> enc(ReplayBlock b) => {
          'rect': [
            b.absoluteRect.raw.left,
            b.absoluteRect.raw.top,
            b.absoluteRect.raw.right,
            b.absoluteRect.raw.bottom,
          ],
          'text': b.originalText,
          'obs': b.observationCount,
        };
    frames.add(jsonEncode({
      'cap': batch.captureId,
      'raw': [for (final b in batch.blocks) enc(b)],
      'stable': [for (final b in result.stableBlocks) enc(b)],
      'tracked': [for (final b in engine.spatialIndex.allBlocks) enc(b)],
    }));
  }
  return (engine: engine, frames: frames, applied: applied);
}

/// Asserts the #122 provenance claim for one demo corpus: the engine's
/// default step response is still the one [expectedDefault] names, and
/// dumping [stream] under it is byte-identical to dumping it under the
/// `damp` the committed GIF was rendered with — because the step response
/// never fires on this control stream.
void expectDefaultStepResponseChangesNothing(
  CaptureStream stream, {
  required int retention,
  required StepResponse expectedDefault,
  required String gif,
}) {
  final defaulted = dumpDemoFrames(stream, retention: retention);
  expect(defaulted.engine.stepResponse, expectedDefault,
      reason: 'the $gif caption says "defaults" and names '
          '${expectedDefault.name}; if the default step response changes, '
          'the caption names the wrong value and the equality below is '
          'about the wrong pair (#122)');
  expect(defaulted.engine.coherentShiftAdoptAgreeing, isTrue,
      reason: 'the README caption also names coherentShiftAdoptAgreeing '
          'as an engine default since 2.4.0; adoption only widens '
          'membership of a DECIDED shift, so the applied-isEmpty '
          'assertion below is what proves it cannot move these frames — '
          'if this default flips again, re-verify and reword the caption');
  // The mechanism first, because it is the reason the equality below holds
  // and it names the problem in one line when it breaks.
  expect(defaulted.applied, isEmpty,
      reason: 'the $gif dump is unchanged by the default step response only '
          'because that response never fires on this control stream (#122, '
          'stated in prose by tool/replay/dump_frames.dart) — if it starts '
          'firing, the caption needs re-verifying even if the frames below '
          'still match');
  final rendered = dumpDemoFrames(
    stream,
    retention: retention,
    stepResponse: StepResponse.damp,
  );
  expect(defaulted.frames, hasLength(rendered.frames.length),
      reason: 'the $gif caption claims identical frame COUNTS under the '
          'current default and under the ${StepResponse.damp.name} the GIF '
          'was rendered with (#122)');
  final divergedAt = [
    for (var i = 0; i < defaulted.frames.length; i++)
      if (defaulted.frames[i] != rendered.frames[i]) i,
  ];
  expect(divergedAt, isEmpty,
      reason: 'the $gif caption claims byte-identical frames under the '
          'current default and under the ${StepResponse.damp.name} the GIF '
          'was rendered with (#122); these capture indices no longer match, '
          'so re-render the GIF or reword the caption — dump both with '
          'tool/replay/dump_frames.dart to see how they differ');
}

void main() {
  test(
      'hero GIF (ML Kit): dwell stream shows real jitter the default '
      'model damps on established chains', () {
    // The README hero GIF renders from this committed on-device stream
    // (doc/replay/validation/2026-08-mlkit-on-device/). Its caption
    // claims real ML Kit jitter and a steady stabilized panel; the
    // engine half of that claim is asserted here by replaying the
    // stream through both position models (same construction as
    // ab-report).
    final stream = CaptureStream.parse(
      File('doc/replay/validation/2026-08-mlkit-on-device/dwell.jsonl')
          .readAsLinesSync(),
    );
    expect(stream.batches, hasLength(19),
        reason: 'the committed stream has 19 captures');
    // The caption renders the first 14 of them (captures 0-18); the
    // remaining five are the closing fling that leaves the GIF's fixed
    // page region (entry correction note, 2026-08-29).
    expect(stream.batches.take(14).last.captureId, 18,
        reason: 'the demo cut must end at capture 18');
    expect(stream.batches[14].captureId, greaterThan(18),
        reason: 'everything after the cut is the fling');

    // Caption: "StabilizationEngine defaults, currently
    // StepResponse.coherentShift since 2.3.0", on frames rendered under
    // the pre-2.3.0 damp. The displacement measurements below go through
    // replay(), whose OWN stepResponse default stays pinned to damp on
    // purpose (see replay_session.dart), so they never exercise the
    // engine's real default — this block does, in dump_frames.dart's
    // construction with the entry's documented retention 2.
    expectDefaultStepResponseChangesNothing(
      stream,
      retention: 2,
      expectedDefault: StepResponse.coherentShift,
      gif: 'hero',
    );

    double establishedDisp(PositionMergeModel model) {
      // Nested-fragment confirmations (#112) move nothing by construction
      // and are excluded here exactly as ab_report's displacement buckets
      // exclude them — this test mirrors that construction.
      final merges = replay(stream, model: model)
          .merges
          .where((m) => m.obsNBefore >= 3 && !m.nestedFragment)
          .toList();
      expect(merges, isNotEmpty,
          reason: 'the dwell fixture must produce established chains');
      return merges.map((m) => m.displacement).reduce((a, b) => a + b) /
          merges.length;
    }

    final legacy = establishedDisp(PositionMergeModel.legacy);
    final agreement = establishedDisp(PositionMergeModel.agreementWeighted);
    // replay() applies the stream's meta.vp (2.1.0), so these are the
    // production-geometry figures: 8.1 px/merge legacy, 2.9 agreement at
    // the 2.1.0 render (the 2.0.0 render, on the 200 px default buckets,
    // measured ~15 and ~4.2 — the difference is four cross-neighbourhood
    // matches production bucket sizes never offer).
    expect(legacy, greaterThanOrEqualTo(8),
        reason: 'raw ML Kit jitter on established chains must be real '
            '(measured 8.1 px/merge at render time) — if this drops, the '
            'corpus changed and the GIF no longer shows what the caption '
            'says');
    expect(agreement, lessThanOrEqualTo(6),
        reason: 'the stabilized panel must actually hold steady '
            '(measured 2.9 px/merge at render time)');
    expect(agreement * 2, lessThan(legacy),
        reason: 'the visible raw-vs-stabilized contrast is the point of '
            'the demo');
  });

  test(
      'secondary GIF (Tesseract): corpus jitter is real and '
      'engine-damped in-region', () {
    final stream = CaptureStream.parse(
      File(
        'doc/replay/validation/2026-08-tesseract-matrix/'
        'ocr-jitter-dwell.jsonl',
      ).readAsLinesSync(),
    );
    // Caption: "12 jittered captures of one viewport".
    expect(stream.batches, hasLength(12));

    // Caption: "StabilizationEngine defaults" — the demo pipeline passes
    // agreementWeighted explicitly; pin that this IS the default so the
    // wording cannot silently drift into a mislabel.
    final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
      merger: (existing, fresh, m) => existing.applyMerge(m),
      // stepResponse (#122, 2026-08-29): left unset, unlike the #116
      // finding G review cycle that pinned this outright to
      // StepResponse.damp. That pin existed because this GIF was
      // rendered before the #116 A/B flipped StabilizationEngine's own
      // default from StepResponse.damp to StepResponse.coherentShift
      // (2.3.0), and the committed corpus's provenance was "the engine's
      // defaults AT RENDER TIME", which was damp. #122 re-dumped this
      // corpus (doc/replay/validation/2026-08-tesseract-matrix/
      // ocr-jitter-dwell.jsonl) under both values via
      // tool/replay/dump_frames.dart's construction and found
      // byte-identical output — coherentShift never fires on this
      // control stream — so the pin now follows the current default
      // again, same as positionMergeModel below. That re-dump is not a
      // one-time hand measurement any more: the
      // expectDefaultStepResponseChangesNothing call below re-runs both
      // halves of it (the equality AND the zero fire count) every run.
    );
    expect(engine.positionMergeModel, PositionMergeModel.agreementWeighted,
        reason: 'the README caption says "defaults"; if the default model '
            'changes, re-render the GIF and reword the caption');
    expect(engine.stepResponse, StepResponse.coherentShift,
        reason: 'the README caption says "defaults"; if the default step '
            'response changes, re-verify this GIF\'s frames are still '
            'byte-identical under it (#122) before trusting the caption '
            'again, and re-render if not');
    // …and that re-verification, run here rather than by hand. The corpus
    // entry's dump command uses no retention.
    expectDefaultStepResponseChangesNothing(
      stream,
      retention: 0,
      expectedDefault: StepResponse.coherentShift,
      gif: 'Tesseract twin',
    );
    // 2.1.0: replay on the corpus viewport, as replay()/dump_frames do —
    // the 200 px default buckets are not production geometry.
    expect(stream.viewport, isNotNull,
        reason: 'the committed corpus header must carry meta.vp');
    engine.updateViewport(
      viewportWidth: stream.viewport!.width,
      viewportHeight: stream.viewport!.height,
    );

    // The page region render_demo_gif.py crops to (REGION top/bottom).
    bool inRegion(double top) => top > 830 && top < 1630;

    final rawTops = <String, List<double>>{};
    final stableTops = <String, List<double>>{};
    for (final batch in stream.batches) {
      for (final b in batch.blocks) {
        final top = b.absoluteRect.raw.top;
        if (inRegion(top)) {
          rawTops.putIfAbsent(b.originalText, () => []).add(top);
        }
      }
      final result = engine.stabilize(batch.blocks);
      for (final b in result.stableBlocks) {
        final top = b.absoluteRect.raw.top;
        if (inRegion(top)) {
          stableTops.putIfAbsent(b.originalText, () => []).add(top);
        }
      }
    }

    // Max top-coordinate spread across frames, over texts observed often
    // enough to be a visible line in the animation.
    double maxSpread(Map<String, List<double>> tops) {
      var worst = 0.0;
      for (final v in tops.values) {
        if (v.length < 4) continue;
        var lo = v.first, hi = v.first;
        for (final t in v) {
          if (t < lo) lo = t;
          if (t > hi) hi = t;
        }
        if (hi - lo > worst) worst = hi - lo;
      }
      return worst;
    }

    final rawSpread = maxSpread(rawTops);
    final stableSpread = maxSpread(stableTops);
    expect(rawSpread, greaterThanOrEqualTo(15),
        reason: 'the raw panel must actually jitter (measured 22 px when '
            'the GIF was rendered) — if this drops, the corpus changed '
            'and the GIF no longer shows what the caption says');
    expect(stableSpread, lessThanOrEqualTo(8),
        reason: 'the stabilized panel must actually hold steady '
            '(measured 6.5 px at render time)');
    expect(stableSpread, lessThan(rawSpread / 2),
        reason: 'the visible raw-vs-stabilized contrast is the point of '
            'the demo');
  });
}
