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
        reason: 'the caption says 19 captures');

    double establishedDisp(PositionMergeModel model) {
      final merges = replay(stream, model: model)
          .merges
          .where((m) => m.obsNBefore >= 3)
          .toList();
      expect(merges, isNotEmpty,
          reason: 'the dwell fixture must produce established chains');
      return merges.map((m) => m.displacement).reduce((a, b) => a + b) /
          merges.length;
    }

    final legacy = establishedDisp(PositionMergeModel.legacy);
    final agreement = establishedDisp(PositionMergeModel.agreementWeighted);
    expect(legacy, greaterThanOrEqualTo(8),
        reason: 'raw ML Kit jitter on established chains must be real '
            '(measured ~15 px/merge at render time) — if this drops, the '
            'corpus changed and the GIF no longer shows what the caption '
            'says');
    expect(agreement, lessThanOrEqualTo(6),
        reason: 'the stabilized panel must actually hold steady '
            '(measured ~4.2 px/merge at render time)');
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
    );
    expect(engine.positionMergeModel, PositionMergeModel.agreementWeighted,
        reason: 'the README caption says "defaults"; if the default model '
            'changes, re-render the GIF and reword the caption');

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
