// ignore_for_file: avoid_print

import 'dart:ui';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

/// Minimal example: stabilize two batches of OCR observations using
/// [DefaultTrackedBlock] as the block implementation.
///
/// The engine is constructed with `BandFallbackMode.observeOnly` — the
/// band-relaxed second-pass match path runs and populates
/// [BandFallbackStats], but never returns a band candidate. This is the
/// recommended starting point: read the counters in production captures,
/// then flip to [BandFallbackMode.admit] once the ratios justify it.
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

  // stabilize() rebuilds engine.spatialIndex internally (#13) — the second
  // capture matches against batch1 with no caller-side index management.

  // Second capture: same text at slightly different positions (OCR jitter).
  final batch2 = [
    _block(text: 'Hello world', left: 12, top: 102, width: 200, height: 30),
    _block(text: 'Goodbye', left: 11, top: 149, width: 150, height: 30),
  ];
  final result2 = engine.stabilize(batch2);
  print('Capture 2: ${result2.stableBlocks.length} stable blocks');

  for (final block in result2.stableBlocks) {
    print(
      '  "${block.originalText}" at '
      '(${block.absoluteRect.left.toStringAsFixed(1)}, '
      '${block.absoluteRect.top.toStringAsFixed(1)}) '
      'observations=${block.observationCount}',
    );
  }

  // Band-fallback telemetry — read in production to decide whether to
  // flip the engine into BandFallbackMode.admit. See BandFallbackStats
  // for the per-counter semantics.
  final s = engine.bandStats;
  print('Band stats — primary admits=${s.primaryMatchesAdmitted}, '
      'primary misses=${s.primaryMatchesRejected}, '
      'band would-admit=${s.bandMatchesIdentified}, '
      'rejected text-band=${s.rejectedTextBand}, '
      'rejected obs-floor=${s.rejectedCandidateFloor}');
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
