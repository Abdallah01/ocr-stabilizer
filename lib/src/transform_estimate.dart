// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'types/geometry.dart';

/// A similarity transform — isotropic scale plus translation, no rotation
/// — fitted by least squares over one capture's eligible matched pairs
/// (2.6.0, #135): `freshCentre ≈ scale * cachedCentre + translation`,
/// reported on `StabilizationResult.transformEstimate`.
///
/// OBSERVED, never applied: the engine keeps merging every block on its
/// own (contract U9 — no scale or zoom model in the merge). The value is
/// for a consumer's layout layer, which holds geometry the engine never
/// sees (its own overlay boxes) and can rescale it, or decide to rebuild,
/// from one value per capture instead of inspecting every block.
///
/// Reading rules (the zoom corpus entry,
/// `doc/replay/validation/2026-09-zoom/EXPERIMENT.md`, measures each and
/// states the bounds it supports):
/// - **A pure zoom** (the same lines, scaled boxes) fits exactly:
///   [scale] is the zoom factor, [residualPx] is OCR noise (a few px),
///   [fixedPoint] is the zoom origin. [translation] alone is not the
///   zoom origin — read [fixedPoint].
/// - **A coherent translation** (a slab pushing lines down) fits with
///   [scale] ≈ 1 and the step in [translation] — the same vector
///   `StabilizationResult.coherentShift` reports when it fires, here
///   without the quorum.
/// - **A partial step** (the lines above a slab stay, the lines below
///   move) is where a scale can lie. Over a LADDER of lines least squares
///   spreads the step into a scale above 1 AND a large [residualPx] — a
///   line cannot explain a step — so the residual separates "zoom" from
///   "step". But when the pairs form TWO CLUSTERS (two paragraphs with
///   nothing matched between them), a translation of one cluster and a
///   zoom about a point fit the same pairs equally well: the residual
///   measures only the spread WITHIN each cluster, and it can be small.
///   The trim (see [fit]) can produce exactly that shape from a ladder by
///   setting aside the pairs at the step boundary. [largestGapShare]
///   names the shape: near 1 means two clusters, and the estimate cannot
///   tell a step from a zoom — read [scale] only under a bound on it (the
///   corpus entry uses 0.5) and let `coherentShift`, `identityTurnover`
///   or your own source decide the rest.
/// - **A rewrap** starves the fit (most line texts change, few pairs
///   survive) — expect `null` or a [pairCount] near the floor with a
///   large residual; `identityTurnover` names that shape.
/// - [spanPx] is the lever arm the scale was estimated over (the RMS
///   spread of the cached centres). The scale's uncertainty is of order
///   `residualPx / spanPx`: three lines 100 px apart with a 2 px residual
///   pin the scale to ~2 %; the same residual over a 20 px cluster pins
///   nothing.
///
/// The pairs are raw absolute-rect centres (cached → fresh), with no drift
/// correction: a uniform drift lands in [translation], a per-region one in
/// [residualPx], and the estimate does not depend on the drift tracker's
/// same-capture mutations. Eligibility is the coherent-shift detector's
/// (ordinary primary matches: no band admission, nested fragment,
/// provisional cached block, viewport-relative fresh block or carousel
/// child on either side) but the pairs are collected in the REAL match
/// loop, so the estimate exists under every `StepResponse`.
class TransformEstimate {
  /// The fitted isotropic scale. `1.0` for a pure translation. Always
  /// finite and > 0: a fit whose scale would be zero, negative or
  /// non-finite is reported as no estimate (`null`) instead.
  final double scale;

  /// The fitted translation, in the tracked blocks' own coordinate space
  /// — the offset that remains after scaling about the origin. For a zoom
  /// about a point other than the origin this is `(1 - scale) * origin`;
  /// read [fixedPoint] for the origin itself.
  final Offset translation;

  /// How many matched pairs the fit used. Always >= 3: a scale needs two
  /// anchors, and a residual needs a third.
  final int pairCount;

  /// RMS distance, px, between each fresh centre and where the fit puts
  /// its cached centre. ~0 for a clean zoom or translation; large when
  /// the pairs did not move as one transform (a partial step over a
  /// ladder of lines, a rewrap remnant). Small does NOT mean "one
  /// transform" when [largestGapShare] is near 1 — see there.
  final double residualPx;

  /// RMS spread, px, of the cached centres about their mean — the lever
  /// arm the scale was estimated over. Always > 0 (coincident centres
  /// give no estimate).
  final double spanPx;

  /// How many matched pairs the trim step set aside as outliers before
  /// the reported fit (see [fit]): usually pairs the text matcher paired
  /// with the wrong cached line, whose fresh centre sits far from where
  /// every other pair says it should — but a step's boundary pairs can
  /// be set aside the same way. `0` when every pair agreed. Always >= 0;
  /// not part of [pairCount].
  final int rejectedPairs;

  /// The share of the used pairs' extent — along whichever axis their
  /// cached centres spread most on — taken by the largest gap between
  /// two neighbouring cached centres, in (0, 1]. A ladder of consecutive
  /// lines sits low (six evenly spaced lines: 0.2; a paragraph gap among
  /// them: ~0.3); two clusters with nothing matched between them sit near
  /// 1. Near 1 the estimate is AMBIGUOUS: a translation of one cluster
  /// and a zoom about a point fit such pairs equally well, and
  /// [residualPx] then measures only the spread inside each cluster.
  /// Read [scale] under a bound on this value (the zoom corpus entry uses
  /// 0.5). Three pairs never sit below 0.5 — one of their two gaps takes
  /// at least half — which is one more reason a reading rule wants more
  /// pairs than the fit's floor.
  final double largestGapShare;

  /// Creates an estimate.
  ///
  /// Throws [ArgumentError] on a non-finite or non-positive [scale], a
  /// non-finite [translation], [pairCount] < 3, a negative or non-finite
  /// [residualPx], a non-positive or non-finite [spanPx], a negative
  /// [rejectedPairs], or a [largestGapShare] outside (0, 1] — the fit's
  /// own invariants, surfaced loudly.
  TransformEstimate({
    required this.scale,
    required this.translation,
    required this.pairCount,
    required this.residualPx,
    required this.spanPx,
    required this.largestGapShare,
    this.rejectedPairs = 0,
  }) {
    if (rejectedPairs < 0) {
      throw ArgumentError.value(rejectedPairs, 'rejectedPairs', 'must be >= 0');
    }
    if (!scale.isFinite || scale <= 0) {
      throw ArgumentError.value(scale, 'scale', 'must be finite and > 0');
    }
    if (!translation.dx.isFinite || !translation.dy.isFinite) {
      throw ArgumentError.value(translation, 'translation', 'must be finite');
    }
    if (pairCount < 3) {
      throw ArgumentError.value(pairCount, 'pairCount',
          'must be >= 3 — two anchors for a scale, a third for a residual');
    }
    if (!residualPx.isFinite || residualPx < 0) {
      throw ArgumentError.value(
          residualPx, 'residualPx', 'must be finite and >= 0');
    }
    if (!spanPx.isFinite || spanPx <= 0) {
      throw ArgumentError.value(spanPx, 'spanPx', 'must be finite and > 0');
    }
    if (!largestGapShare.isFinite ||
        largestGapShare <= 0 ||
        largestGapShare > 1) {
      throw ArgumentError.value(
          largestGapShare, 'largestGapShare', 'must be in (0, 1]');
    }
  }

  /// The point the transform leaves in place — the zoom origin for a pure
  /// zoom — or `null` when [scale] is 1 (a translation has no fixed
  /// point). Solves `p = scale * p + translation`.
  Offset? get fixedPoint {
    final k = 1 - scale;
    if (k.abs() < 1e-9) return null;
    return Offset(translation.dx / k, translation.dy / k);
  }

  /// Fits `fresh ≈ scale * cached + translation` over [pairs] (cached
  /// centre, fresh centre) by least squares, with ONE trim step.
  ///
  /// Returns `null` when fewer than [minPairs] pairs are given, when the
  /// cached centres coincide (no lever arm — the scale is undefined), or
  /// when the fitted scale is not positive (mirrored pairs — no sensible
  /// similarity). Throws [ArgumentError] for [minPairs] < 3: two pairs
  /// always fit a similarity exactly, so their residual is 0 whatever
  /// happened and the scale they report is arbitrary.
  ///
  /// Closed form: with `x̄`, `ȳ` the mean cached and fresh centres,
  /// `scale = Σ (x - x̄)·(y - ȳ) / Σ |x - x̄|²` and
  /// `translation = ȳ - scale * x̄`; [residualPx] is the RMS of
  /// `|y - (scale * x + translation)|`, [spanPx] the RMS of `|x - x̄|`,
  /// and [largestGapShare] the largest gap between neighbouring cached
  /// centres along their wider axis, over that axis's extent — all three
  /// over the pairs the reported fit used.
  ///
  /// **The trim** (measured on the zoom corpus): text-first matching
  /// occasionally pairs a fresh line with the WRONG cached line — a
  /// near-duplicate sentence a few lines away — and one such pair,
  /// hundreds of px from where every other pair sits, drags a plain
  /// least-squares scale anywhere (a real 0.8x zoom read as 1.04 with a
  /// 179 px residual). So: fit once, take each pair's residual, set aside
  /// every pair whose residual exceeds three times the median residual,
  /// and refit over the rest — provided at least [minPairs] remain;
  /// otherwise the untrimmed fit stands, with [rejectedPairs] 0. Three
  /// times the median is the same value-only, order-independent shape as
  /// the coherent-shift quorum's clustering.
  ///
  /// What the trim CANNOT promise is to leave a step alone. Over a ladder
  /// with an even split (half the lines moved, half did not) no pair is
  /// an outlier against the others and nothing is set aside. But with
  /// three paragraphs and a slab between two of them, the pairs at the
  /// step boundary ARE the first fit's outliers; the refit sees two
  /// clusters and reads a zoom about a point with a small residual (a
  /// synthetic eight-line page with a 200 px slab: 1.28 at 9.8 px after
  /// the trim, 51 px before it). That shape is what [largestGapShare]
  /// reports, and why it belongs in any reading rule; the coherent-shift
  /// quorum and floor (#119) remain the instruments for a step.
  static TransformEstimate? fit(
    List<(Offset cached, Offset fresh)> pairs, {
    int minPairs = 3,
  }) {
    if (minPairs < 3) {
      throw ArgumentError.value(minPairs, 'minPairs',
          'must be >= 3 — two pairs fit any similarity exactly');
    }
    final first = _leastSquares(pairs, minPairs);
    if (first == null) return null;
    final residuals = [for (final p in pairs) first._residualOf(p)];
    final sorted = [...residuals]..sort();
    final n = sorted.length;
    final median =
        n.isOdd ? sorted[n ~/ 2] : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
    final threshold = 3 * median;
    final kept = <(Offset, Offset)>[
      for (var i = 0; i < pairs.length; i++)
        if (residuals[i] <= threshold) pairs[i],
    ];
    if (kept.length == pairs.length || kept.length < minPairs) return first;
    final trimmed = _leastSquares(kept, minPairs);
    if (trimmed == null) return first;
    return TransformEstimate(
      scale: trimmed.scale,
      translation: trimmed.translation,
      pairCount: trimmed.pairCount,
      residualPx: trimmed.residualPx,
      spanPx: trimmed.spanPx,
      largestGapShare: trimmed.largestGapShare,
      rejectedPairs: pairs.length - kept.length,
    );
  }

  /// Distance, px, from [pair]'s fresh centre to where this transform puts
  /// its cached centre.
  double _residualOf((Offset, Offset) pair) {
    final (c, f) = pair;
    final ex = f.dx - (scale * c.dx + translation.dx);
    final ey = f.dy - (scale * c.dy + translation.dy);
    return math.sqrt(ex * ex + ey * ey);
  }

  /// The plain least-squares fit over [pairs] — see [fit] for the closed
  /// form and the null cases. [rejectedPairs] is always 0 here.
  static TransformEstimate? _leastSquares(
    List<(Offset cached, Offset fresh)> pairs,
    int minPairs,
  ) {
    final n = pairs.length;
    if (n < minPairs) return null;
    var mx = 0.0, my = 0.0, fx = 0.0, fy = 0.0;
    for (final (c, f) in pairs) {
      mx += c.dx;
      my += c.dy;
      fx += f.dx;
      fy += f.dy;
    }
    mx /= n;
    my /= n;
    fx /= n;
    fy /= n;
    var sxx = 0.0, sxy = 0.0;
    for (final (c, f) in pairs) {
      final dx = c.dx - mx;
      final dy = c.dy - my;
      sxx += dx * dx + dy * dy;
      sxy += dx * (f.dx - fx) + dy * (f.dy - fy);
    }
    if (sxx <= 0 || !sxx.isFinite) return null;
    final scale = sxy / sxx;
    if (!scale.isFinite || scale <= 0) return null;
    final translation = Offset(fx - scale * mx, fy - scale * my);
    var ss = 0.0;
    for (final (c, f) in pairs) {
      final ex = f.dx - (scale * c.dx + translation.dx);
      final ey = f.dy - (scale * c.dy + translation.dy);
      ss += ex * ex + ey * ey;
    }
    return TransformEstimate(
      scale: scale,
      translation: translation,
      pairCount: n,
      residualPx: math.sqrt(ss / n),
      spanPx: math.sqrt(sxx / n),
      largestGapShare: _largestGapShare(pairs),
    );
  }

  /// The largest gap between neighbouring cached centres along the axis
  /// they spread most on, as a share of that axis's extent. The extent is
  /// > 0 whenever the pairs have any spread at all (which [_leastSquares]
  /// has already required), so the share is in (0, 1].
  static double _largestGapShare(List<(Offset cached, Offset fresh)> pairs) {
    var minX = double.infinity, maxX = double.negativeInfinity;
    var minY = double.infinity, maxY = double.negativeInfinity;
    for (final (c, _) in pairs) {
      minX = math.min(minX, c.dx);
      maxX = math.max(maxX, c.dx);
      minY = math.min(minY, c.dy);
      maxY = math.max(maxY, c.dy);
    }
    final alongX = maxX - minX >= maxY - minY;
    final values = [for (final (c, _) in pairs) alongX ? c.dx : c.dy]..sort();
    final extent = values.last - values.first;
    var gap = 0.0;
    for (var i = 1; i < values.length; i++) {
      gap = math.max(gap, values[i] - values[i - 1]);
    }
    return gap / extent;
  }

  /// Value equality over all seven fields.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TransformEstimate &&
          other.scale == scale &&
          other.translation == translation &&
          other.pairCount == pairCount &&
          other.residualPx == residualPx &&
          other.spanPx == spanPx &&
          other.rejectedPairs == rejectedPairs &&
          other.largestGapShare == largestGapShare;

  @override
  int get hashCode => Object.hash(scale, translation, pairCount, residualPx,
      spanPx, rejectedPairs, largestGapShare);

  @override
  String toString() => 'TransformEstimate(scale=${scale.toStringAsFixed(3)} '
      'translation=$translation pairs=$pairCount '
      'residual=${residualPx.toStringAsFixed(1)}px '
      'span=${spanPx.toStringAsFixed(1)}px rejected=$rejectedPairs '
      'gap=${largestGapShare.toStringAsFixed(2)})';
}
