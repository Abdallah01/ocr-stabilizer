// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// Batch-size benchmarks for the two hot entry points (#97):
//
//   StabilizationEngine.stabilize()      — steady-state re-observation cost
//   ParagraphGrouper.groupIntoParagraphs — per-batch grouping cost
//
// Run:  dart run benchmark/stabilize_benchmark.dart
//
// Method: for each batch size, one cold stabilize() seeds the engine, then
// 20 jittered re-observation captures are timed individually and the MEDIAN
// per-capture wall time is reported (median resists GC/JIT outliers; the
// first timed capture is preceded by 3 untimed warmups so JIT compilation
// settles). Grouping is stateless, so it is simply warmed 3× and timed 15×.
// Everything is seeded — two runs time identical work.
//
// Recorded numbers live in doc/benchmarks/ — re-run there when the matching
// code paths change. This file is a plain script (no harness dependency) so
// it adds nothing to the package's dependency surface.
import 'dart:math';

import 'package:ocr_stabilizer/ocr_stabilizer.dart';

const _sizes = [25, 50, 100, 250, 500, 1000, 2000];

void main() {
  // VM-wide JIT warmup: without this, the first size's "cold" number
  // measures first-ever-call compilation of the whole engine, not the
  // engine (observed: 15.3 ms for 100 blocks vs 2.6 ms for 250).
  _benchStabilizeCold(50);
  _benchGrouping(50);
  print('| batch | stabilize cold | stabilize warm (median/capture) | '
      'group (median) |');
  print('|---|---|---|---|');
  for (final size in _sizes) {
    final cold = _benchStabilizeCold(size);
    final warm = _benchStabilizeWarm(size);
    final group = _benchGrouping(size);
    print('| $size | ${_fmt(cold)} | ${_fmt(warm)} | ${_fmt(group)} |');
  }
}

String _fmt(double micros) => micros >= 1000
    ? '${(micros / 1000).toStringAsFixed(1)} ms'
    : '${micros.round()} µs';

// Delegates to the package's own median so the benchmark's "median"
// matches RobustStats everywhere else (true midpoint on even N).
double _median(List<double> xs) => RobustStats.median(xs)!;

/// A column of [size] distinct text lines; [jitterSeed] > 0 perturbs every
/// rect by up to ±1.5 px, the amplitude of real screenshot jitter the
/// engine sees per capture.
List<DefaultTrackedBlock<void>> _batch(int size, int jitterSeed) {
  final rng = Random(jitterSeed);
  return List.generate(size, (i) {
    final dx = jitterSeed == 0 ? 0.0 : rng.nextDouble() * 3 - 1.5;
    final dy = jitterSeed == 0 ? 0.0 : rng.nextDouble() * 3 - 1.5;
    return DefaultTrackedBlock<void>(
      absoluteRect: AbsoluteRect(
        Rect.fromLTWH(60 + dx, i * 40.0 + dy, 800, 30),
      ),
      payload: null,
      originalText: 'synthetic paragraph line number $i with typical length',
    );
  });
}

double _benchStabilizeCold(int size) {
  final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
    merger: (existing, fresh, merge) => existing.applyMerge(merge),
  );
  final batch = _batch(size, 0); // fixture built OUTSIDE the timer
  final sw = Stopwatch()..start();
  engine.stabilize(batch);
  sw.stop();
  return sw.elapsedMicroseconds.toDouble();
}

double _benchStabilizeWarm(int size) {
  final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
    merger: (existing, fresh, merge) => existing.applyMerge(merge),
  );
  engine.stabilize(_batch(size, 0)); // seed
  for (var w = 1; w <= 3; w++) {
    engine.stabilize(_batch(size, w)); // untimed JIT warmup
  }
  final times = <double>[];
  for (var run = 4; run < 24; run++) {
    final batch = _batch(size, run); // fixture built OUTSIDE the timer
    final sw = Stopwatch()..start();
    engine.stabilize(batch);
    sw.stop();
    times.add(sw.elapsedMicroseconds.toDouble());
  }
  return _median(times);
}

/// [size] single-line blocks in paragraphs of three: 8 px gaps inside a
/// paragraph, 40 px between paragraphs — the bimodal gap distribution the
/// grouper's Otsu pass expects from real pages.
List<OcrBlock> _groupingBatch(int size) {
  final blocks = <OcrBlock>[];
  var y = 0.0;
  for (var i = 0; i < size; i++) {
    final box = Rect.fromLTWH(60, y, 800, 30);
    final text = 'synthetic paragraph line number $i with typical length';
    blocks.add(OcrBlock(
      text: text,
      boundingBox: box,
      lines: [OcrLine(text: text, elements: const [], boundingBox: box)],
    ));
    y += 30 + ((i % 3 == 2) ? 40 : 8);
  }
  return blocks;
}

double _benchGrouping(int size) {
  final grouper = ParagraphGrouper();
  final batch = _groupingBatch(size);
  for (var w = 0; w < 3; w++) {
    grouper.groupIntoParagraphs(batch);
  }
  final times = <double>[];
  for (var run = 0; run < 15; run++) {
    final sw = Stopwatch()..start();
    grouper.groupIntoParagraphs(batch);
    sw.stop();
    times.add(sw.elapsedMicroseconds.toDouble());
  }
  return _median(times);
}
