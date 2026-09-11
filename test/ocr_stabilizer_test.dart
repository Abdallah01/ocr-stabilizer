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

/// Every field of every stable block a merger could move, plus every
/// result-level field (PR #174 fan-out: an earlier draft omitted
/// invalidatedTexts / wellObservedTexts / contradiction content — exactly
/// the fields contextualCheck and the vote path write).
String _fingerprint(StabilizationResult<DefaultTrackedBlock<int>> r) {
  String block(DefaultTrackedBlock<int> b) =>
      '${b.originalText}|${b.absoluteRect.left.toStringAsFixed(3)}'
      ',${b.absoluteRect.top.toStringAsFixed(3)}'
      ',${b.absoluteRect.width.toStringAsFixed(3)}'
      ',${b.absoluteRect.height.toStringAsFixed(3)}'
      '|n=${b.observationCount}|p=${b.payload}'
      '|tv=${b.textVotes.entries.map((e) => '${e.key}:${e.value}').join('+')}'
      '|cv=${b.classificationVotes}|car=${b.carouselVotes}'
      '|pc=${b.positionConfidence}|tc=${b.textConfidence}'
      '|sq=${b.sourceQuality}|prov=${b.isProvisional}'
      ':${b.provisionalCapturesRemaining}|g=${b.groupSignature}'
      '|recl=${b.needsReclassification}|co=${b.coordinates}';
  final blocks = r.stableBlocks.map(block).join('\n');
  final contradictions = r.contradictions
      .map((c) => '${c.type.name}:${c.target.originalText}'
          '<-${c.evidence.map((e) => e.originalText).join(',')}')
      .join(';');
  return '$blocks\n${r.identityTurnover}\n${r.coherentShift}\n'
      '${r.transformEstimate}\ninv=${r.invalidatedTexts}'
      '\nwell=${r.wellObservedTexts}\ncontra=$contradictions';
}

/// Field-by-field: BandFallbackStats has no toString, so a string compare
/// is a tautology (PR #174 fan-out).
List<int> _bandCounters(BandFallbackStats s) => [
      s.primaryMatchesAdmitted,
      s.primaryMatchesRejected,
      s.candidatesConsidered,
      s.rejectedCandidateFloor,
      s.rejectedSpatial,
      s.rejectedTextBand,
      s.bandMatchesIdentified,
      s.matchesAdmitted,
    ];

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
      expect(_bandCounters(a.bandStats), _bandCounters(b.bandStats));
      expect(a.bandStats.candidatesConsidered, greaterThan(0),
          reason: 'control: the observeOnly pass actually ran');
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

    test('forwards submapMembership into the drift tracker it builds '
        '(PR #174 fan-out P1: was declared, not pinned)', () {
      final membership = CssSubmapMembership(regionSize: 640);
      final s = OcrStabilizer<int>(submapMembership: membership);
      expect(identical(s.driftTracker.submapMembership, membership), isTrue);
      expect(s.driftTracker.regionSize, 640);
    });

    test('forwards contextualCheck: a check that fires invalidates the '
        'text (PR #174 fan-out P1; mirrors the engine test)', () {
      final s = OcrStabilizer<int>(
        contextualCheck: (fresh, existing) =>
            fresh.groupSignature != existing.groupSignature,
      );
      s.stabilize([_block('same text', 100, 1).copyWith(groupSignature: 7)]);
      final r = s.stabilize(
          [_block('same text', 100, 1).copyWith(groupSignature: 9)]);
      expect(r.invalidatedTexts, contains('same text'));
      // And without the check, the same pair is a plain re-observation.
      final plain = OcrStabilizer<int>();
      plain.stabilize([_block('same text', 100, 1).copyWith(groupSignature: 7)]);
      expect(
          plain
              .stabilize(
                  [_block('same text', 100, 1).copyWith(groupSignature: 9)])
              .invalidatedTexts,
          isEmpty);
    });

    test('the differential stream really exercises misses, text flips and '
        're-observation (control: each named branch is observed)', () {
      final captures = _stream();
      expect(captures.where((c) => c.length == 11), isNotEmpty,
          reason: 'the miss branch drops one line every 5th capture');
      expect(
          captures.any((c) => c.any((b) => b.originalText.contains('fl1p'))),
          isTrue,
          reason: 'the text-flip branch fires every 7th capture');

      final s = OcrStabilizer<int>(
          config: const StabilizerConfig(
              retention: RetentionConfig(missedFrames: 2)));
      var sawTwoVotes = false;
      var sawDropThenReturn = false;
      int? missedPayload; // the line the previous capture dropped
      final prints = <String>{};
      for (var i = 0; i < captures.length; i++) {
        final r = s.stabilize(captures[i]);
        prints.add(_fingerprint(r));
        if (r.stableBlocks.any((b) => b.textVotes.length >= 2)) {
          sawTwoVotes = true;
        }
        // stableBlocks holds this capture's observations; a RETAINED line
        // shows up when it returns: its identity survived the miss, so its
        // observation count continues instead of restarting at 1.
        if (missedPayload != null) {
          final back = r.stableBlocks
              .where((b) => b.payload == missedPayload)
              .toList();
          if (back.isNotEmpty && back.first.observationCount > 1) {
            sawDropThenReturn = true;
          }
        }
        missedPayload = captures[i].length == 11 ? i % 12 : null;
      }
      expect(prints.length, greaterThan(30));
      expect(sawTwoVotes, isTrue,
          reason: 'the flip must reach the vote table (voting exercised)');
      expect(sawDropThenReturn, isTrue,
          reason: 'a missed line must be retained (retention exercised)');
      expect(s.stabilize(captures.last).stableBlocks
              .any((b) => b.observationCount > 1),
          isTrue);
    });
  });
}
