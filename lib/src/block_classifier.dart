import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'block_meta.dart';
import 'classification_input.dart';
import 'classification_result.dart';
import 'confidence.dart';
import 'iqr_outlier.dart';
import 'ocr_block.dart';
import 'types/absolute_rect.dart';
import 'types/confidence_types.dart';
import 'types/scroll_context.dart';
import 'types/sticky_fallback.dart';

// =============================================================================
// BLOCK CLASSIFIER SERVICE
// =============================================================================
// Pure-computation service that classifies OCR text groups into block types
// (fixed/sticky, carousel, inner-scroller, normal) and computes absolute
// coordinates.
//
// Platform-agnostic: accepts ClassificationInput (not CaptureSnapshot),
// uses callback for position lookup (not OverlayCacheService), and returns
// ClassificationResult without dedup or translation cache logic.
// =============================================================================

/// Pure-computation service for OCR block classification.
///
/// Classifies groups into fixed/sticky, carousel, inner-scroller, or normal
/// blocks and computes absolute CSS coordinates. Consumer handles dedup and
/// translation cache splitting.
class BlockClassifierService {
  /// Minimum area overlap fraction for exclusion zone filtering.
  ///
  /// A group is dropped when the overlap between its bounding rect and an
  /// exclusion zone is ≥ this threshold. Default 0.5 (50%) matches the
  /// original ExclusionZoneService constant.
  final double exclusionOverlapThreshold;

  /// Clock function for deterministic testing. Defaults to [DateTime.now].
  final DateTime Function() _clock;

  /// Creates a block classifier with optional exclusion threshold and clock.
  BlockClassifierService({
    this.exclusionOverlapThreshold = 0.5,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Classify OCR text groups and compute absolute coordinates.
  ///
  /// Returns [ClassificationResult] containing all groups that pass
  /// classification filters (exclusion zones, viewport guard, animation
  /// deferral). The consumer handles dedup and translation cache splitting.
  ///
  /// [positionLookup] provides O(1) position history for stability scoring.
  /// When null, stability defaults to 0.5 (neutral). The callback must not
  /// throw — wrap implementations in try-catch and return null on failure.
  ClassificationResult classifyGroups({
    required List<List<OcrBlock>> textGroups,
    required ClassificationInput input,
    required List<Rect> fixedStickyRects,
    List<bool> fixedStickyIsFixed = const [],
    List<Rect> exclusionRects = const [],
    Offset? Function(String originalText)? positionLookup,
  }) {
    final scale = input.imageToLayoutScale;
    // #12: Tighter guard — very small scale causes numerical instability
    final cssPerPx = scale > 0.001 ? 1.0 / scale : 1.0;

    // Position confidence: freshness component
    final vitalsAgeMs = _clock().difference(input.captureTime).inMilliseconds;
    final capFreshness = computeFreshness(vitalsAgeMs);

    // Average block height for adaptive stability thresholds
    final allOcrBlocks = textGroups.expand((g) => g).toList();
    final avgBlockHeightCss = allOcrBlocks.isEmpty
        ? null
        : allOcrBlocks
                .map((b) => b.boundingBox.height * cssPerPx)
                .fold(0.0, (double a, double b) => a + b) /
            allOcrBlocks.length;

    // IQR upper fence for viewport guard
    final allCssHeights =
        allOcrBlocks.map((b) => b.boundingBox.height * cssPerPx).toList();
    final heightFence = IqrOutlier.upperFence(allCssHeights);

    final classified = <ClassifiedGroup>[];
    int droppedExclusion = 0;
    int droppedViewport = 0;
    int deferredAnimating = 0;

    for (final group in textGroups) {
      // #5: Guard against empty groups (would crash reduce())
      if (group.isEmpty) {
        if (kDebugMode) {
          debugPrint('[BlockClassifier] empty group in textGroups — skipping');
        }
        continue;
      }

      // ── Group bounding rect in CSS px ──
      final gL =
          group.map((b) => b.boundingBox.left).reduce((a, b) => a < b ? a : b) *
              cssPerPx;
      final gT =
          group.map((b) => b.boundingBox.top).reduce((a, b) => a < b ? a : b) *
              cssPerPx;
      final gR = group
              .map((b) => b.boundingBox.right)
              .reduce((a, b) => a > b ? a : b) *
          cssPerPx;
      final gB = group
              .map((b) => b.boundingBox.bottom)
              .reduce((a, b) => a > b ? a : b) *
          cssPerPx;
      final cx = (gL + gR) / 2;
      final cy = (gT + gB) / 2;
      final groupRect = Rect.fromLTRB(gL, gT, gR, gB);
      final groupArea = groupRect.width * groupRect.height;

      // ── Hit-test: fixed/sticky ──
      bool insideFixedSticky = false;
      bool fromStickyElement = false;
      if (fixedStickyRects.isNotEmpty) {
        for (int i = 0; i < fixedStickyRects.length; i++) {
          final r = fixedStickyRects[i];
          if (cx >= r.left && cx <= r.right && cy >= r.top && cy <= r.bottom) {
            final intersection = groupRect.intersect(r);
            if (groupArea <= 0 ||
                (intersection.width * intersection.height) / groupArea >= 0.5) {
              insideFixedSticky = true;
              fromStickyElement =
                  i < fixedStickyIsFixed.length && !fixedStickyIsFixed[i];
              break;
            }
          }
        }
      }

      // ── Hit-test: exclusion zones ──
      if (!insideFixedSticky && exclusionRects.isNotEmpty) {
        if (groupArea > 0) {
          bool insideExclusion = false;
          for (final er in exclusionRects) {
            final intersection = groupRect.intersect(er);
            if (!intersection.isEmpty) {
              final overlapArea = intersection.width * intersection.height;
              if (overlapArea / groupArea >= exclusionOverlapThreshold) {
                insideExclusion = true;
                break;
              }
            }
          }
          if (insideExclusion) {
            droppedExclusion++;
            // #2: Guard with kDebugMode
            if (kDebugMode) {
              final exclText = group.map((b) => b.text).join(' ');
              debugPrint(
                '[Classify] EXCLUSION DROP: "${exclText.length > 30 ? '${exclText.substring(0, 30)}…' : exclText}"',
              );
            }
            continue;
          }
        }
      }

      // ── Hit-test: carousel ──
      int matchedHzIndex = -1;
      if (input.carousels.isNotEmpty) {
        for (int hi = 0; hi < input.carousels.length; hi++) {
          final hr = input.carousels[hi].rect;
          if (cx >= hr.left &&
              cx <= hr.right &&
              cy >= hr.top &&
              cy <= hr.bottom) {
            matchedHzIndex = hi;
            break;
          }
        }
      }
      final insideHzScroller = !insideFixedSticky && matchedHzIndex >= 0;

      // ── Defer blocks in animating carousels ──
      if (insideHzScroller &&
          matchedHzIndex >= 0 &&
          matchedHzIndex < input.carousels.length &&
          input.carousels[matchedHzIndex].isAnimating) {
        deferredAnimating++;
        continue;
      }

      // ── Hit-test: inner-scroller ──
      bool fallbackIsIc = false;
      if (input.hasInnerScroller) {
        final icViewportTopCss = input.innerScrollerTop - input.viewportPageTop;
        final icViewportBottomCss =
            icViewportTopCss + input.innerScrollerHeight;
        fallbackIsIc = cy >= icViewportTopCss && cy < icViewportBottomCss;
      }
      final bool isIcChild = !insideFixedSticky && fallbackIsIc;
      final double icTop = isIcChild ? input.innerScrollerTop : 0.0;

      // ── Effective scroll offsets ──
      final double effectiveScrollY;
      if (insideFixedSticky) {
        effectiveScrollY = 0.0;
      } else if (isIcChild) {
        effectiveScrollY = input.scrollY;
      } else {
        effectiveScrollY = input.viewportPageTop;
      }

      final double effectiveScrollX;
      if (insideFixedSticky) {
        effectiveScrollX = 0.0;
      } else if (insideHzScroller) {
        effectiveScrollX = input.carousels[matchedHzIndex].scrollLeft;
      } else {
        effectiveScrollX = input.scrollX;
      }

      // Fallback scroll for sticky demotion
      final double fallbackScrollY =
          fallbackIsIc ? input.scrollY : input.viewportPageTop;
      final double fallbackScrollX = matchedHzIndex >= 0
          ? input.carousels[matchedHzIndex].scrollLeft
          : input.scrollX;

      // ── Absolute rect (coordinate transformation) ──
      final leftPx =
          group.map((b) => b.boundingBox.left).reduce((a, b) => a < b ? a : b);
      final topPx =
          group.map((b) => b.boundingBox.top).reduce((a, b) => a < b ? a : b);
      final rightPx =
          group.map((b) => b.boundingBox.right).reduce((a, b) => a > b ? a : b);
      final bottomPx = group
          .map((b) => b.boundingBox.bottom)
          .reduce((a, b) => a > b ? a : b);

      var rawRect = Rect.fromLTRB(
        leftPx * cssPerPx + effectiveScrollX,
        topPx * cssPerPx + effectiveScrollY,
        rightPx * cssPerPx + effectiveScrollX,
        bottomPx * cssPerPx + effectiveScrollY,
      );

      // ── Affine transform correction ──
      if (isIcChild && input.innerScrollerTransform != null) {
        rawRect = applyInverseTransform(rawRect, input.innerScrollerTransform!);
      } else if (insideHzScroller &&
          matchedHzIndex >= 0 &&
          matchedHzIndex < input.carousels.length) {
        final hzTransform = input.carousels[matchedHzIndex].transform;
        if (hzTransform != null) {
          rawRect = applyInverseTransform(rawRect, hzTransform);
        }
      }
      final absoluteRect = AbsoluteRect(rawRect);

      // ── Viewport guard ──
      final originalText = group.map((b) => b.text).join(' ');
      if (input.viewportHeight > 0) {
        final minLimit = input.viewportHeight * 0.30;
        final rawLimit = heightFence ?? input.viewportHeight * 0.6;
        final limit = rawLimit < minLimit ? minLimit : rawLimit;
        if (absoluteRect.height > limit) {
          droppedViewport++;
          // #2: Guard with kDebugMode
          if (kDebugMode) {
            debugPrint(
              '[Classify] VIEWPORT DROP: h=${absoluteRect.height.toStringAsFixed(0)} '
              'limit=${limit.toStringAsFixed(0)} text="${originalText.length > 30 ? '${originalText.substring(0, 30)}…' : originalText}"',
            );
          }
          continue;
        }
      }

      // ── Position confidence ──
      // #4: Wrap callback in try-catch to prevent pipeline abort
      double? positionDelta;
      try {
        final lastPos = positionLookup?.call(originalText);
        if (lastPos != null) {
          positionDelta = (lastPos - absoluteRect.topLeft).distance;
        }
      } catch (e) {
        if (kDebugMode) {
          debugPrint(
            '[BlockClassifier] positionLookup threw: $e — using neutral stability',
          );
        }
      }
      final stability = computeStability(
        positionDelta,
        referenceHeight: avgBlockHeightCss,
      );
      final posConf = (capFreshness * 0.5 + stability * 0.5).clamp(0.0, 1.0);
      final txtConf = computeTextConfidence(group);

      // Debug: flag IC blocks without containerId
      if (kDebugMode && isIcChild && input.innerScrollerContainerId == null) {
        debugPrint(
          '[BlockClassifier] IC block without containerId — drift will fall back to normal: space',
        );
      }

      // #8: Use nested ScrollContext and StickyFallback types
      final meta = BlockMeta(
        isViewportRelative: insideFixedSticky,
        isInnerScrollerChild: isIcChild,
        innerScrollerTop: icTop,
        containerId: isIcChild ? input.innerScrollerContainerId : null,
        captureContext: ScrollContext(
          scrollY: effectiveScrollY,
          scrollX: effectiveScrollX,
          hzScrollerIndex: matchedHzIndex,
        ),
        isFromStickyElement: fromStickyElement,
        stickyFallback: StickyFallback(
          scrollY: fallbackScrollY,
          scrollX: fallbackScrollX,
          isIc: fallbackIsIc,
          hzScrollerIndex: matchedHzIndex,
        ),
        positionConfidence: PositionConfidence.from(posConf),
        textConfidence: TextConfidence.from(txtConf),
      );

      classified.add(
        ClassifiedGroup(group: group, absoluteRect: absoluteRect, meta: meta),
      );
    }

    // #2: Guard with kDebugMode
    if (kDebugMode) {
      debugPrint(
        '[Classify] ${textGroups.length} groups → '
        '${classified.length} classified, '
        'dropped: $droppedExclusion exclusion, $droppedViewport viewport, '
        '$deferredAnimating deferred (animating) '
        '(heightFence=${heightFence?.toStringAsFixed(0) ?? "null"}, '
        'vvH=${input.viewportHeight.toStringAsFixed(0)})',
      );

      if (deferredAnimating > 0) {
        debugPrint(
          '[BlockClassifier] deferred $deferredAnimating block(s) in animating carousel',
        );
      }
    }

    return ClassificationResult(
      classified: classified,
      cssPerImagePx: cssPerPx,
      droppedExclusion: droppedExclusion,
      droppedViewport: droppedViewport,
      deferredAnimating: deferredAnimating,
    );
  }

  /// Undo a CSS affine transform [matrix] from [rect].
  ///
  /// The 6-element matrix is `[a, b, c, d, tx, ty]` matching the CSS
  /// `matrix(a,b,c,d,tx,ty)` function. The inverse is applied to recover
  /// the un-transformed bounding box.
  static Rect applyInverseTransform(Rect rect, List<double> matrix) {
    if (matrix.length < 6) return rect;
    final a = matrix[0], b = matrix[1], c = matrix[2], d = matrix[3];
    final tx = matrix[4], ty = matrix[5];

    // Fast path: pure translation (identity rotation/scale)
    if ((a - 1.0).abs() < 0.001 &&
        b.abs() < 0.001 &&
        c.abs() < 0.001 &&
        (d - 1.0).abs() < 0.001) {
      return rect.shift(Offset(-tx, -ty));
    }

    // Full affine inverse
    final det = a * d - b * c;
    if (det.abs() < 1e-6) return rect;
    final invDet = 1.0 / det;
    final ia = d * invDet;
    final ib = -b * invDet;
    final ic = -c * invDet;
    final id = a * invDet;
    final itx = -(ia * tx + ic * ty);
    final ity = -(ib * tx + id * ty);

    Offset xform(double px, double py) =>
        Offset(ia * px + ic * py + itx, ib * px + id * py + ity);

    final c1 = xform(rect.left, rect.top);
    final c2 = xform(rect.right, rect.top);
    final c3 = xform(rect.right, rect.bottom);
    final c4 = xform(rect.left, rect.bottom);

    return Rect.fromLTRB(
      [c1.dx, c2.dx, c3.dx, c4.dx].reduce((a, b) => a < b ? a : b),
      [c1.dy, c2.dy, c3.dy, c4.dy].reduce((a, b) => a < b ? a : b),
      [c1.dx, c2.dx, c3.dx, c4.dx].reduce((a, b) => a > b ? a : b),
      [c1.dy, c2.dy, c3.dy, c4.dy].reduce((a, b) => a > b ? a : b),
    );
  }

  /// Compute a hash signature of the group composition.
  ///
  /// Returns `0` for single-block groups. For multi-block groups, returns
  /// [Object.hashAll] of sorted text values — changes when group composition
  /// changes, triggering contextual translation invalidation.
  static int computeGroupSignature(List<OcrBlock> group) {
    if (group.length <= 1) return 0;
    final texts = group.map((b) => b.text).toList()..sort();
    return Object.hashAll(texts);
  }
}
