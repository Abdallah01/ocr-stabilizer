import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

// =============================================================================
// LONG-SESSION BOUNDED-STATE REPLAY (#97)
// =============================================================================
// A 900-capture synthetic continuous-scroll session (~15 simulated minutes at
// the 1 Hz capture cadence the package targets) asserting that engine state
// stays BOUNDED. The engine's design says it must: the spatial index is
// rebuilt each stabilize() call from stable + retained blocks only, retention
// expires missed blocks after `missedFrameRetention` calls, and text votes
// are capped per block (`_kMaxTextVotes` in stabilization_engine.dart). This
// test pins that so a future change cannot silently regress it into
// monotonic growth.
//
// Page geometry (all deterministic — no rng anywhere):
//   400 text lines, 40 px vertical spacing, 60 px margin -> page 16,120 px.
//   Viewport 2,200 px; scroll advances 200 px per capture and wraps at
//   13,800 px (so sy + viewport stays on the page). One full pass = 69
//   captures; 900 captures = ~13 passes, so old content is revisited many
//   times after absences far longer than the retention window.
//
// Population ceiling, derived then verified:
//   visible lines per capture      <= 55   (2,200 / 40, +1 boundary line)
//   steady-state retained          <= 10   (5 lines exit per 200 px step,
//                                           kept for retention=2 calls)
//   wrap transient: the whole previous viewport goes missing at once, so
//   for 2 captures after a wrap    <= 55 retained on top of 55 visible,
//   plus ~25 short-lived duplicate identities the text churn spawns while
//   a mismatched line's old identity sits in its retention window.
//   Measured (deterministic fixture): the per-pass maximum is 132 on the
//   first pass, then EXACTLY 145 on every later pass — a flat plateau
//   across 13 passes. Ceiling asserted: 160 (plateau + ~10%). A leak that
//   never expires blocks reaches ~400 tracked identities within two
//   passes, so the assert still discriminates by ~2.5×. The flatness
//   itself is asserted separately below — that is the sharper
//   monotonic-growth detector.
void main() {
  test('900-capture continuous scroll keeps engine state bounded', () {
    const lineCount = 400;
    const spacing = 40.0;
    const margin = 60.0;
    const lineHeight = 30.0;
    const viewH = 2200.0;
    const scrollStep = 200.0;
    const scrollWrap = 13800.0;
    const captures = 900;
    const capsPerPass = 69; // scrollWrap / scrollStep
    const populationCeiling = 160;
    // Mirrors _kMaxTextVotes (private) in stabilization_engine.dart — a
    // deliberate pin: if the cap constant changes, this test must be
    // revisited alongside it.
    const maxTextVotes = 5;

    final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
      merger: (existing, fresh, merge) => existing.applyMerge(merge),
      missedFrameRetention: 2,
    );

    var maxPopulation = 0;
    var maxVotesSeen = 0;
    var maxObservations = 0;
    final perPassMax = <int, int>{};
    for (var cap = 0; cap < captures; cap++) {
      final sy = (cap * scrollStep) % scrollWrap;
      final batch = <DefaultTrackedBlock<void>>[];
      for (var i = 0; i < lineCount; i++) {
        final y = margin + i * spacing;
        if (y < sy || y + lineHeight > sy + viewH) continue;
        // Deterministic text churn: every other observation of a line
        // carries a capture-dependent suffix, so a long-lived identity sees
        // more than [maxTextVotes] DISTINCT texts inside one pass and the
        // vote cap is actually exercised (not vacuously satisfied).
        final suffix = (cap + i).isEven ? '~${cap % 11}' : '';
        batch.add(DefaultTrackedBlock<void>(
          absoluteRect: AbsoluteRect(Rect.fromLTWH(60, y, 800, lineHeight)),
          payload: null,
          originalText: 'line $i of the synthetic page$suffix',
        ));
      }
      final result = engine.stabilize(batch);
      expect(result.stableBlocks, isNotEmpty,
          reason: 'every capture in this fixture has visible lines');

      final population = engine.spatialIndex.allBlocks.length;
      if (population > maxPopulation) maxPopulation = population;
      final pass = cap ~/ capsPerPass;
      if (population > (perPassMax[pass] ?? 0)) perPassMax[pass] = population;
      expect(population, lessThanOrEqualTo(populationCeiling),
          reason: 'tracked population must stay bounded '
              '(capture $cap, scrollY $sy): unbounded growth here means '
              'retention expiry or the rebuild-from-stable index regressed');

      for (final block in engine.spatialIndex.allBlocks) {
        final votes = block.textVotes.length;
        if (votes > maxVotesSeen) maxVotesSeen = votes;
        expect(votes, lessThanOrEqualTo(maxTextVotes),
            reason: 'text votes must stay capped per block (capture $cap)');
        if (block.observationCount > maxObservations) {
          maxObservations = block.observationCount;
        }
      }
    }

    // The sharper leak detector: after the first wrap the fixture is
    // perfectly cyclic, so the per-pass population maximum must be FLAT.
    // Any growth between an early full pass and the last full pass means
    // state survives that should have expired.
    final lastFullPass = (captures ~/ capsPerPass) - 1;
    expect(perPassMax[lastFullPass], lessThanOrEqualTo(perPassMax[1]!),
        reason: 'per-pass max population grew between pass 1 '
            '(${perPassMax[1]}) and pass $lastFullPass '
            '(${perPassMax[lastFullPass]}) — a slow leak, even if still '
            'under the absolute ceiling');

    // Positive controls — prove the bounded quantities were actually
    // exercised, so the ceilings above are not vacuously green.
    expect(maxPopulation, greaterThan(60),
        reason: 'the fixture must drive the population through the '
            'steady-state band (visible + retained), or the ceiling '
            'assert proves nothing');
    expect(maxVotesSeen, equals(maxTextVotes),
        reason: 'the text-churn fixture must actually reach the vote cap');
    // A line is visible for 11 consecutive captures per pass; if merging
    // works, some identity must accumulate close to that many
    // observations at some point during the run. (Checked as a running
    // maximum, not at the end: the run deliberately ends just after a
    // wrap, where every surviving identity is young.)
    expect(maxObservations, greaterThanOrEqualTo(10),
        reason: 'identity persistence across captures must be exercised: '
            'long-visible lines merge, they do not respawn '
            '(max observed: $maxObservations)');
  });
}
