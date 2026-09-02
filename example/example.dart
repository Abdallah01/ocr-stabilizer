// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// ignore_for_file: avoid_print

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

/// Minimal example: stabilize two batches of OCR observations using
/// [DefaultTrackedBlock] as the block implementation.
///
/// The engine is constructed with `BandFallbackMode.observeOnly` — the
/// band-relaxed second-pass match path runs and populates
/// [BandFallbackStats], but never returns a band candidate. This is the
/// recommended starting point: read the counters in production captures,
/// then flip to [BandFallbackMode.admit] once the ratios justify it.
/// Note that [BandFallbackStats.matchesAdmitted] stays at zero in
/// observeOnly by construction — the counter only ticks when a band
/// match is actually returned, which requires [BandFallbackMode.admit].
void main() {
  final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
    merger: (existing, fresh, merge) => existing.applyMerge(merge),
    bandFallback: const BandFallbackConfig(mode: BandFallbackMode.observeOnly),
  );

  // First capture: two text blocks observed.
  final batch1 = [
    _block(text: 'Hello world', left: 10, top: 100, width: 200, height: 30),
    _block(text: 'Goodbye', left: 10, top: 150, width: 150, height: 30),
  ];
  final result1 = engine.stabilize(batch1);
  print('Capture 1: ${result1.stableBlocks.length} stable blocks');

  // stabilize() rebuilds engine.spatialIndex internally — the second
  // capture matches against batch1 with no caller-side index management.

  // Second capture: same text at slightly different positions (OCR jitter).
  final batch2 = [
    _block(text: 'Hello world', left: 12, top: 102, width: 200, height: 30),
    _block(text: 'Goodbye', left: 11, top: 149, width: 150, height: 30),
  ];
  final result2 = engine.stabilize(batch2);
  print('Capture 2: ${result2.stableBlocks.length} stable blocks');
  // 2.5.0 — what the engine decided this capture, without reading blocks:
  // the identity census, and the coherent shift if one was decided
  // (`null` here — the two captures agree, nothing moved as a slab).
  print('  ${result2.identityTurnover}');
  print('  coherent shift: ${result2.coherentShift ?? 'none'}');

  for (final block in result2.stableBlocks) {
    print(
      '  "${block.originalText}" at '
      '(${block.absoluteRect.left.toStringAsFixed(1)}, '
      '${block.absoluteRect.top.toStringAsFixed(1)}) '
      'observations=${block.observationCount}',
    );
  }

  // Band-fallback telemetry — read in production to decide whether to
  // flip the engine into BandFallbackMode.admit. With this minimal
  // example's clean synthetic data, the primary path matches every
  // observation so the band counters stay at or near zero. In real OCR
  // captures, single-character jitter will tick `bandMatchesIdentified`
  // and the `rejected*` counters; only those non-zero ratios justify a
  // flip to admit mode. See `BandFallbackStats` for per-counter
  // semantics and the decomposability invariant.
  final s = engine.bandStats;
  print('Band stats —\n'
      '  primary admits=${s.primaryMatchesAdmitted}\n'
      '  primary misses=${s.primaryMatchesRejected}\n'
      '  candidates considered=${s.candidatesConsidered}\n'
      '  band would-admit=${s.bandMatchesIdentified}\n'
      '  rejected obs-floor=${s.rejectedCandidateFloor}\n'
      '  rejected spatial=${s.rejectedSpatial}\n'
      '  rejected text-band=${s.rejectedTextBand}\n'
      '  matches admitted=${s.matchesAdmitted}');
}

DefaultTrackedBlock<void> _block({
  required String text,
  required double left,
  required double top,
  required double width,
  required double height,
}) {
  return DefaultTrackedBlock<void>(
    absoluteRect: AbsoluteRect(Rect.fromLTWH(left, top, width, height)),
    payload: null,
    originalText: text,
  );
}
