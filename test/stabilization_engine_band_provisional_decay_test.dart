// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'package:test/test.dart';

import 'package:ocr_stabilizer/src/band_fallback_config.dart';
import 'package:ocr_stabilizer/src/default_tracked_block.dart';
import 'package:ocr_stabilizer/src/stabilization_engine.dart';
import 'package:ocr_stabilizer/src/types/absolute_rect.dart';

DefaultTrackedBlock<Object> _block(String text,
        {required double left,
        required double top,
        int observationCount = 1}) =>
    DefaultTrackedBlock<Object>(
      absoluteRect: AbsoluteRect.fromLTWH(left, top, 50, 20),
      payload: const Object(),
      originalText: text,
      observationCount: observationCount,
    );

void main() {
  group('StabilizationEngine band — provisional decay after admission (#20)',
      () {
    test('band admit → 3 confirming captures → block becomes non-provisional',
        () {
      final engine = StabilizationEngine<DefaultTrackedBlock<Object>, Object>(
        merger: (existing, fresh, m) => existing.applyMerge(m),
        bandFallback: const BandFallbackConfig(
          mode: BandFallbackMode.admit,
          candidateObservationFloor: 1,
          provisionalCaptures: 3,
        ),
      );

      // Step A: seed an existing block with high observationCount.
      engine.stabilize(
          [_block('hello world', left: 0, top: 0, observationCount: 5)]);

      // Step B: band-admit a fresh observation at the same rect.
      // After this capture the merged block is provisional with captures=3.
      // Text-vote winner: 'hello world' (seed seeded first, tie → first wins).
      final r1 = engine.stabilize([_block('hxlxo wxrxd', left: 0, top: 0)]);
      final after1 =
          r1.stableBlocks.firstWhere((b) => b.absoluteRect.raw.left == 0);
      expect(after1.isProvisional, isTrue);
      expect(after1.provisionalCapturesRemaining, 3);

      // Step C: Capture #2 — feed 'hello world' which matches existing text
      // via primary path (Lev = 1.0), triggering the freeze path (captures: 3 → 2).
      final r2 = engine.stabilize([_block('hello world', left: 0, top: 0)]);
      final after2 =
          r2.stableBlocks.firstWhere((b) => b.absoluteRect.raw.left == 0);
      expect(after2.isProvisional, isTrue);
      expect(after2.provisionalCapturesRemaining, 2);

      // Step D: Capture #3 — captures: 2 → 1.
      final r3 = engine.stabilize([_block('hello world', left: 0, top: 0)]);
      final after3 =
          r3.stableBlocks.firstWhere((b) => b.absoluteRect.raw.left == 0);
      expect(after3.isProvisional, isTrue);
      expect(after3.provisionalCapturesRemaining, 1);

      // Step E: Capture #4 — captures: 1 → 0 → block graduates.
      final r4 = engine.stabilize([_block('hello world', left: 0, top: 0)]);
      final after4 =
          r4.stableBlocks.firstWhere((b) => b.absoluteRect.raw.left == 0);
      expect(after4.isProvisional, isFalse);
      expect(after4.provisionalCapturesRemaining, 0);
    });
  });
}
