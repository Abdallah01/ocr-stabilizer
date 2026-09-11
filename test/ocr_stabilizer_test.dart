// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// =============================================================================
// OcrStabilizer (#170) — the common path is the general engine, exactly
// =============================================================================
// `OcrStabilizer<P>` exists so a first-time reader types one object with no
// merger callback and one generic parameter. Its whole contract is
// "identical to StabilizationEngine<DefaultTrackedBlock<P>, P> with the
// canonical merger": this file pins that capture for capture over a
// deterministic jittered scroll stream, and pins that the constructor
// options reach the engine (the levers the config getters report).
// =============================================================================

import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

DefaultTrackedBlock<int> _block(String text, double top, int payload,
        {double left = 40}) =>
    DefaultTrackedBlock<int>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, 220, 24),
      originalText: text,
      payload: payload,
    );

/// 40 captures: 12 lines, 40 px apart, scrolled 8 px per capture with
/// deterministic per-line jitter, one line dropping out every 5th capture
/// (retention exercised) and one line's text flipping a character every
/// 7th capture (voting exercised). No randomness anywhere.
List<List<DefaultTrackedBlock<int>>> _stream() {
  final captures = <List<DefaultTrackedBlock<int>>>[];
  for (var c = 0; c < 40; c++) {
    final blocks = <DefaultTrackedBlock<int>>[];
    for (var i = 0; i < 12; i++) {
      if (c % 5 == 4 && i == c % 12) continue; // a miss
      final jitter = ((c * 7 + i * 3) % 5) - 2; // -2..2 px
      final text = (c % 7 == 6 && i == 3) ? 'line 3 (ocr fl1p)' : 'line $i';
      blocks.add(_block(text, 100.0 + i * 40 + c * 8 + jitter, i,
          left: 40.0 + ((c + i) % 3)));
    }
    captures.add(blocks);
  }
  return captures;
}

String _fingerprint(StabilizationResult<DefaultTrackedBlock<int>> r) {
  final blocks = r.stableBlocks
      .map((b) => '${b.originalText}|${b.absoluteRect.left.toStringAsFixed(3)}'
          ',${b.absoluteRect.top.toStringAsFixed(3)}|${b.observationCount}'
          '|${b.payload}|${b.textVotes.keys.join('+')}|${b.isProvisional}')
      .join('\n');
  return '$blocks\n${r.identityTurnover}\n${r.coherentShift}\n'
      '${r.transformEstimate}\n${r.contradictions.length}';
}

void main() {
  group('OcrStabilizer', () {
    test('is capture-for-capture identical to StabilizationEngine with the '
        'canonical DefaultTrackedBlock merger (defaults)', () {
      final a = OcrStabilizer<int>();
      final b = StabilizationEngine<DefaultTrackedBlock<int>, int>(
        merger: (existing, fresh, merge) => existing.applyMerge(merge),
      );
      var captureIndex = 0;
      for (final capture in _stream()) {
        final ra = a.stabilize(capture);
        final rb = b.stabilize(capture);
        expect(_fingerprint(ra), _fingerprint(rb),
            reason: 'capture $captureIndex diverged');
        captureIndex++;
      }
      expect(captureIndex, 40);
    });

    test('is identical under a non-default config too (retention 2, '
        'band fallback observeOnly)', () {
      final config = StabilizerConfig(
        retention: const RetentionConfig(missedFrames: 2),
        matching: MatchingConfig(
          bandFallback:
              const BandFallbackConfig(mode: BandFallbackMode.observeOnly),
        ),
      );
      final a = OcrStabilizer<int>(config: config);
      final b = StabilizationEngine<DefaultTrackedBlock<int>, int>(
        merger: (existing, fresh, merge) => existing.applyMerge(merge),
        config: config,
      );
      for (final capture in _stream()) {
        expect(_fingerprint(a.stabilize(capture)),
            _fingerprint(b.stabilize(capture)));
      }
      expect(a.bandStats.toString(), b.bandStats.toString());
    });

    test('forwards the config: the levers the engine reports come from it',
        () {
      final s = OcrStabilizer<int>(
        config: const StabilizerConfig(
          retention: RetentionConfig(missedFrames: 3),
        ),
      );
      expect(s.missedFrameRetention, 3);
      expect(OcrStabilizer<int>().missedFrameRetention,
          const StabilizerConfig().retention.missedFrames,
          reason: 'no config = the documented defaults, nothing else');
    });

    test('forwards the shared collaborators (driftTracker, spatialIndex)',
        () {
      final drift = DriftTracker();
      final index = SpatialBlockIndex<DefaultTrackedBlock<int>>();
      final s = OcrStabilizer<int>(driftTracker: drift, spatialIndex: index);
      expect(identical(s.driftTracker, drift), isTrue);
      expect(identical(s.spatialIndex, index), isTrue);
    });

    test('the differential stream really exercises retention and voting '
        '(control: the fingerprint is not trivially constant)', () {
      final s = OcrStabilizer<int>();
      final prints = _stream().map((c) => _fingerprint(s.stabilize(c))).toSet();
      expect(prints.length, greaterThan(30));
      final last = s.stabilize(_stream().last);
      expect(last.stableBlocks.any((b) => b.observationCount > 1), isTrue);
    });
  });
}
