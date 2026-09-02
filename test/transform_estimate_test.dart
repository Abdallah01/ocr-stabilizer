// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
//
// #135 — `TransformEstimate`: the least-squares similarity fit (isotropic
// scale + translation, no rotation) over a capture's matched pairs,
// `fresh ≈ scale * cached + translation`. Pure value-type and fit tests;
// the engine-level wiring is in
// stabilization_engine_transform_estimate_test.dart.
import 'package:ocr_stabilizer/ocr_stabilizer.dart';
import 'package:test/test.dart';

(Offset, Offset) _pair(double x, double y, double x2, double y2) =>
    (Offset(x, y), Offset(x2, y2));

/// A column of lines at [ys] (constant x), the ones at index >= [movedFrom]
/// pushed down by [step] — a slab inserted between two lines.
List<(Offset, Offset)> _column(List<double> ys,
        {required int movedFrom, required double step}) =>
    [
      for (var i = 0; i < ys.length; i++)
        _pair(300, ys[i], 300, i >= movedFrom ? ys[i] + step : ys[i]),
    ];

void main() {
  group('TransformEstimate.fit', () {
    test('a pure translation: scale 1, the translation, zero residual', () {
      final e = TransformEstimate.fit([
        _pair(100, 500, 100, 650),
        _pair(100, 600, 100, 750),
        _pair(100, 700, 100, 850),
        _pair(400, 700, 400, 850),
      ]);
      expect(e, isNotNull);
      expect(e!.scale, closeTo(1.0, 1e-9));
      expect(e.translation.dx, closeTo(0, 1e-9));
      expect(e.translation.dy, closeTo(150, 1e-9));
      expect(e.pairCount, 4);
      expect(e.residualPx, closeTo(0, 1e-9));
      expect(e.fixedPoint, isNull,
          reason: 'a translation leaves no point in place');
    });

    test('a pure zoom about the page origin: scale k, zero translation', () {
      const k = 1.25;
      final e = TransformEstimate.fit([
        for (final (x, y) in [(50.0, 500.0), (50.0, 600.0), (50.0, 700.0)])
          _pair(x, y, x * k, y * k),
      ]);
      expect(e, isNotNull);
      expect(e!.scale, closeTo(k, 1e-9));
      expect(e.translation.dx, closeTo(0, 1e-9));
      expect(e.translation.dy, closeTo(0, 1e-9));
      expect(e.residualPx, closeTo(0, 1e-9));
      expect(e.fixedPoint!.dx, closeTo(0, 1e-6));
      expect(e.fixedPoint!.dy, closeTo(0, 1e-6));
    });

    test(
        'a zoom about an arbitrary point recovers that point as the '
        'fixed point (translation = (1 - k) * origin)', () {
      const k = 0.8;
      const origin = Offset(540, 1200);
      Offset zoomed(Offset p) => Offset(
            origin.dx + (p.dx - origin.dx) * k,
            origin.dy + (p.dy - origin.dy) * k,
          );
      final cached = [
        const Offset(100, 800),
        const Offset(900, 1000),
        const Offset(100, 1500),
        const Offset(700, 2200),
      ];
      final e = TransformEstimate.fit([for (final c in cached) (c, zoomed(c))]);
      expect(e, isNotNull);
      expect(e!.scale, closeTo(k, 1e-9));
      expect(e.translation.dx, closeTo((1 - k) * origin.dx, 1e-6));
      expect(e.translation.dy, closeTo((1 - k) * origin.dy, 1e-6));
      expect(e.fixedPoint!.dx, closeTo(origin.dx, 1e-6));
      expect(e.fixedPoint!.dy, closeTo(origin.dy, 1e-6));
    });

    test(
        'a step over an evenly split ladder is NOT a clean fit: the '
        'residual is large relative to the pairs\' own spread', () {
      final e = TransformEstimate.fit(
          _column([800, 900, 1000, 1700, 1800, 1900], movedFrom: 3, step: 300));
      expect(e, isNotNull);
      // Least squares spreads the 300 px step into a scale > 1 ...
      expect(e!.scale, greaterThan(1.1));
      // ... but cannot explain a step with a line: the residual stays
      // in the tens of pixels (26.8 for this fixture; a pure zoom of the
      // same cached centres would be ~0). Read the residual first.
      expect(e.residualPx, greaterThan(20));
      expect(e.spanPx, greaterThan(0));
      expect(e.rejectedPairs, 0,
          reason: 'no pair is an outlier against the others here');
    });

    test('noise around a clean transform lands in residualPx, not scale', () {
      const k = 1.1;
      final noise = [1.0, -1.0, 0.5, -0.5, 1.0, -1.0];
      final e = TransformEstimate.fit([
        for (var i = 0; i < 6; i++)
          _pair(
              100, 500.0 + 200 * i, 100 * k, (500.0 + 200 * i) * k + noise[i]),
      ]);
      expect(e, isNotNull);
      expect(e!.scale, closeTo(k, 0.002));
      expect(e.residualPx, greaterThan(0));
      expect(e.residualPx, lessThan(1.5));
    });

    test(
        'fewer than minPairs pairs, or cached centres that coincide (no '
        'lever arm for a scale), give no estimate; minPairs below 3 is '
        'refused (two pairs fit any similarity exactly)', () {
      expect(TransformEstimate.fit([_pair(0, 0, 0, 10), _pair(0, 100, 0, 110)]),
          isNull,
          reason: 'default minPairs is 3');
      expect(
          TransformEstimate.fit([
            _pair(100, 100, 110, 110),
            _pair(100, 100, 120, 120),
            _pair(100, 100, 130, 130),
          ]),
          isNull,
          reason: 'all cached centres at one point: scale is undefined');
      expect(() => TransformEstimate.fit([], minPairs: 2), throwsArgumentError,
          reason: 'two stacked lines report an arbitrary scale at residual 0');
      expect(() => TransformEstimate.fit([], minPairs: 1), throwsArgumentError);
    });

    test(
        'a few mismatched pairs among clean zoom pairs are trimmed: the '
        'scale recovers, rejectedPairs counts them, pairCount excludes them',
        () {
      const k = 0.8;
      final pairs = [
        for (var i = 0; i < 8; i++)
          _pair(60, 1000.0 + 150 * i, 60 * k, (1000.0 + 150 * i) * k),
        // Two lines the text matcher paired with the WRONG cached line
        // (a near-duplicate sentence a few lines away): their fresh
        // centres sit hundreds of px from where the zoom would put them.
        _pair(60, 1300, 60 * k, 1300 * k + 350),
        _pair(60, 1600, 60 * k, 1600 * k - 420),
      ];
      final e = TransformEstimate.fit(pairs);
      expect(e, isNotNull);
      expect(e!.scale, closeTo(k, 1e-6));
      expect(e.rejectedPairs, 2);
      expect(e.pairCount, 8);
      expect(e.residualPx, closeTo(0, 1e-6));
      expect(e.largestGapShare, closeTo(150 / 1050, 1e-9),
          reason: 'an even ladder of eight: one pitch over seven');
    });

    test(
        'the trim CAN turn a step into a clean-looking zoom — three '
        'paragraphs, a slab under the second: the boundary pairs are the '
        'outliers, the refit sees two clusters — and largestGapShare is '
        'what exposes it', () {
      // The review\'s fixture: eight lines in three paragraphs, the five
      // below the first paragraph pushed down 200 px by a slab.
      final e = TransformEstimate.fit(_column(
          [300, 336, 492, 528, 984, 1020, 1056, 1092],
          movedFrom: 3, step: 200));
      expect(e, isNotNull);
      // The first fit read 51 px of residual; the trim set aside the two
      // pairs at the step boundary (492 stayed, 528 moved) ...
      expect(e!.rejectedPairs, 2);
      expect(e.pairCount, 6);
      // ... and the refit reads a zoom about a point, under the corpus
      // entry\'s 10 px residual bound: a false transform.
      expect(e.scale, closeTo(1.28, 0.01));
      expect(e.residualPx, lessThan(10));
      // What the kept pairs look like: two clusters (300, 336 | 984 …
      // 1092) — the largest gap takes 648 of the 792 px extent.
      expect(e.largestGapShare, closeTo(648 / 792, 1e-9));
      expect(e.largestGapShare, greaterThan(0.5),
          reason: 'the reading rule\'s gap bound refuses this capture');
    });

    test(
        'two clusters read as a clean zoom with NO trim at all (a slab '
        'between two paragraphs): the residual is only the within-cluster '
        'spread — largestGapShare is the only signal', () {
      final e = TransformEstimate.fit(
          _column([300, 336, 372, 1300, 1336, 1372], movedFrom: 3, step: 200));
      expect(e, isNotNull);
      expect(e!.rejectedPairs, 0);
      expect(e.scale, closeTo(1.2, 0.01),
          reason: '1 + 200 px over the 1000 px between the clusters');
      expect(e.residualPx, lessThan(10),
          reason: '0.2 x the 36 px within-cluster offsets: ~6 px');
      expect(e.largestGapShare, closeTo(928 / 1072, 1e-9));
    });

    test(
        'largestGapShare: an even ladder of six reads 0.2, a paragraph '
        'gap among them ~0.33, and the axis is whichever the cached '
        'centres spread most on', () {
      final ladder = TransformEstimate.fit([
        for (var i = 0; i < 6; i++)
          _pair(100, 500.0 + 50 * i, 100, 500.0 + 50 * i + 7),
      ]);
      expect(ladder!.largestGapShare, closeTo(0.2, 1e-9));
      final paragraphs = TransformEstimate.fit([
        for (final y in [0.0, 50.0, 100.0, 200.0, 250.0, 300.0])
          _pair(100, y, 100, y + 7),
      ]);
      expect(paragraphs!.largestGapShare, closeTo(100 / 300, 1e-9));
      // A row of words: the spread is along x, so the gap is read along x.
      final row = TransformEstimate.fit([
        for (final x in [0.0, 100.0, 200.0, 700.0, 800.0])
          _pair(x, 400, x, 405),
      ]);
      expect(row!.largestGapShare, closeTo(500 / 800, 1e-9));
    });

    test(
        'trimming never drops below minPairs: with too few survivors the '
        'untrimmed fit is reported instead', () {
      // Three clean pairs and two far outliers. With the floor at 3 the
      // trim fires (both outliers set aside); with the floor at 4 the same
      // trim would leave 3 < 4, so the untrimmed fit stands.
      final pairs = [
        _pair(0, 100, 0, 100),
        _pair(0, 200, 0, 200),
        _pair(0, 300, 0, 300),
        _pair(0, 400, 0, 1000),
        _pair(0, 500, 0, -100),
      ];
      final loose = TransformEstimate.fit(pairs, minPairs: 3);
      expect(loose, isNotNull);
      expect(loose!.rejectedPairs, 2, reason: 'fixture precondition');
      expect(loose.pairCount, 3);
      final strict = TransformEstimate.fit(pairs, minPairs: 4);
      expect(strict, isNotNull);
      expect(strict!.rejectedPairs, 0,
          reason: 'dropping them would leave 3 < 4');
      expect(strict.pairCount, 5);
    });

    test(
        'a fit whose scale would be <= 0 (mirrored pairs) is rejected as '
        'no estimate rather than a nonsense similarity', () {
      expect(
          TransformEstimate.fit([
            _pair(0, 100, 0, -100),
            _pair(0, 200, 0, -200),
            _pair(0, 300, 0, -300),
          ]),
          isNull);
    });
  });

  group('TransformEstimate value type', () {
    TransformEstimate e({
      double scale = 1.25,
      Offset t = const Offset(0, 0),
      int pairs = 3,
      double residual = 0.5,
      double span = 100,
      double gap = 0.5,
      int rejected = 0,
    }) =>
        TransformEstimate(
          scale: scale,
          translation: t,
          pairCount: pairs,
          residualPx: residual,
          spanPx: span,
          largestGapShare: gap,
          rejectedPairs: rejected,
        );

    test('validates its invariants loudly', () {
      expect(() => e(scale: 0), throwsArgumentError);
      expect(() => e(scale: -1), throwsArgumentError);
      expect(() => e(scale: double.nan), throwsArgumentError);
      expect(() => e(t: const Offset(double.infinity, 0)), throwsArgumentError);
      expect(() => e(pairs: 2), throwsArgumentError);
      expect(() => e(residual: -0.1), throwsArgumentError);
      expect(() => e(span: 0), throwsArgumentError);
      expect(() => e(gap: 0), throwsArgumentError);
      expect(() => e(gap: 1.5), throwsArgumentError);
      expect(() => e(gap: double.nan), throwsArgumentError);
      expect(() => e(rejected: -1), throwsArgumentError);
      expect(e(gap: 1), isA<TransformEstimate>());
      expect(e(), isA<TransformEstimate>());
    });

    test('value equality and hashCode over all seven fields', () {
      expect(e(), e());
      expect(e().hashCode, e().hashCode);
      expect(e(), isNot(e(scale: 1.3)));
      expect(e(), isNot(e(t: const Offset(0, 1))));
      expect(e(), isNot(e(pairs: 4)));
      expect(e(), isNot(e(residual: 0.6)));
      expect(e(), isNot(e(span: 101)));
      expect(e(), isNot(e(gap: 0.6)));
      expect(e(), isNot(e(rejected: 1)));
    });

    test('toString names the fields a log reader wants', () {
      expect(
          e().toString(),
          'TransformEstimate(scale=1.250 translation=Offset(0.0, 0.0) '
          'pairs=3 residual=0.5px span=100.0px rejected=0 gap=0.50)');
    });
  });
}
