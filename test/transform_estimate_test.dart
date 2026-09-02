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

    test('a zoom about an arbitrary point recovers that point as the '
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

    test('a step (half the pairs moved, half did not) is NOT a clean fit: '
        'the residual is large relative to the pairs\' own spread', () {
      final e = TransformEstimate.fit([
        _pair(100, 800, 100, 800),
        _pair(100, 900, 100, 900),
        _pair(100, 1000, 100, 1000),
        _pair(100, 1700, 100, 2000),
        _pair(100, 1800, 100, 2100),
        _pair(100, 1900, 100, 2200),
      ]);
      expect(e, isNotNull);
      // Least squares spreads the 300 px step into a scale > 1 ...
      expect(e!.scale, greaterThan(1.1));
      // ... but cannot explain a step with a line: the residual stays
      // in the tens of pixels (26.8 for this fixture; a pure zoom of the
      // same cached centres would be ~0). Read the residual first.
      expect(e.residualPx, greaterThan(20));
      expect(e.spanPx, greaterThan(0));
    });

    test('noise around a clean transform lands in residualPx, not scale', () {
      const k = 1.1;
      final noise = [1.0, -1.0, 0.5, -0.5, 1.0, -1.0];
      final e = TransformEstimate.fit([
        for (var i = 0; i < 6; i++)
          _pair(100, 500.0 + 200 * i, 100 * k, (500.0 + 200 * i) * k + noise[i]),
      ]);
      expect(e, isNotNull);
      expect(e!.scale, closeTo(k, 0.002));
      expect(e.residualPx, greaterThan(0));
      expect(e.residualPx, lessThan(1.5));
    });

    test('fewer than minPairs pairs, or cached centres that coincide (no '
        'lever arm for a scale), give no estimate', () {
      expect(TransformEstimate.fit([_pair(0, 0, 0, 10), _pair(0, 100, 0, 110)]),
          isNull,
          reason: 'default minPairs is 3');
      expect(
          TransformEstimate.fit(
              [_pair(0, 0, 0, 10), _pair(0, 100, 0, 110)], minPairs: 2),
          isNotNull);
      expect(
          TransformEstimate.fit([
            _pair(100, 100, 110, 110),
            _pair(100, 100, 120, 120),
            _pair(100, 100, 130, 130),
          ]),
          isNull,
          reason: 'all cached centres at one point: scale is undefined');
      expect(() => TransformEstimate.fit([], minPairs: 1), throwsArgumentError,
          reason: 'minPairs must be >= 2 — a scale needs two anchors');
    });

    test('a few mismatched pairs among clean zoom pairs are trimmed: the '
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
    });

    test('a half-and-half step is NOT trimmed into a false transform: no '
        'pair is an outlier against the others, so all stay and the '
        'residual keeps telling the truth', () {
      final e = TransformEstimate.fit([
        _pair(100, 800, 100, 800),
        _pair(100, 900, 100, 900),
        _pair(100, 1000, 100, 1000),
        _pair(100, 1700, 100, 2000),
        _pair(100, 1800, 100, 2100),
        _pair(100, 1900, 100, 2200),
      ]);
      expect(e!.rejectedPairs, 0);
      expect(e.pairCount, 6);
      expect(e.residualPx, greaterThan(20));
    });

    test('trimming never drops below minPairs: with too few survivors the '
        'untrimmed fit is reported instead', () {
      final e = TransformEstimate.fit([
        _pair(0, 100, 0, 100),
        _pair(0, 200, 0, 200),
        _pair(0, 300, 0, 900), // an outlier among three
      ]);
      expect(e, isNotNull);
      expect(e!.rejectedPairs, 0, reason: 'dropping it would leave 2 < 3');
      expect(e.pairCount, 3);
    });

    test('a fit whose scale would be <= 0 (mirrored pairs) is rejected as '
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
    }) =>
        TransformEstimate(
          scale: scale,
          translation: t,
          pairCount: pairs,
          residualPx: residual,
          spanPx: span,
        );

    test('validates its invariants loudly', () {
      expect(() => e(scale: 0), throwsArgumentError);
      expect(() => e(scale: -1), throwsArgumentError);
      expect(() => e(scale: double.nan), throwsArgumentError);
      expect(() => e(t: const Offset(double.infinity, 0)), throwsArgumentError);
      expect(() => e(pairs: 1), throwsArgumentError);
      expect(() => e(residual: -0.1), throwsArgumentError);
      expect(() => e(span: 0), throwsArgumentError);
      expect(e(), isA<TransformEstimate>());
    });

    test('value equality and hashCode over all six fields', () {
      expect(e(), e());
      expect(e().hashCode, e().hashCode);
      expect(e(), isNot(e(scale: 1.3)));
      expect(e(), isNot(e(t: const Offset(0, 1))));
      expect(e(), isNot(e(pairs: 4)));
      expect(e(), isNot(e(residual: 0.6)));
      expect(e(), isNot(e(span: 101)));
      final rejected = TransformEstimate(
          scale: 1.25,
          translation: const Offset(0, 0),
          pairCount: 3,
          residualPx: 0.5,
          spanPx: 100,
          rejectedPairs: 1);
      expect(e(), isNot(rejected));
      expect(
          () => TransformEstimate(
              scale: 1.25,
              translation: const Offset(0, 0),
              pairCount: 3,
              residualPx: 0.5,
              spanPx: 100,
              rejectedPairs: -1),
          throwsArgumentError);
    });

    test('toString names the fields a log reader wants', () {
      expect(e().toString(),
          'TransformEstimate(scale=1.250 translation=Offset(0.0, 0.0) '
          'pairs=3 residual=0.5px span=100.0px rejected=0)');
    });
  });
}
