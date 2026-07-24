// =============================================================================
// #78 — ANOMALY-CLASS DIAGNOSTICS VISIBLE IN ALL BUILD MODES
// =============================================================================
// Since the 0.8.0 debugLogger opt-in, every logger call site was additionally
// gated behind the package's kDebugMode mirror — false in profile/release —
// so anomaly-class events (non-finite input skips, positionLookup throws)
// vanished exactly where consumers need them: on-device profile runs. The
// #78 split: chatty lines stay kDebugMode-gated; anomaly-class lines are
// delivered UNgated to a wired logger.
//
// Under `dart test` kDebugMode is TRUE, so the behavioral half alone cannot
// distinguish gated from ungated emits — the source-shape group pins the
// absence of the gate directly (that half is the change detector; mutation:
// re-wrap an anomaly emit in `if (kDebugMode)` → its shape test goes red).

import 'dart:io';
import 'dart:math';

import 'package:test/test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

DefaultTrackedBlock<void> _blockWithTop(double top) {
  return DefaultTrackedBlock<void>(
    absoluteRect: AbsoluteRect(Rect.fromLTWH(100, top, 200, 30)),
    payload: null,
    originalText: 'anomaly probe paragraph',
  );
}

/// Minimal ClassificationInput (mirrors block_classifier_test.dart).
class _TestInput implements ClassificationInput {
  @override
  final double scrollY = 100;
  @override
  final double scrollX = 0;
  @override
  final double imageToLayoutScale = 2.0;
  @override
  final double viewportHeight = 800;
  @override
  final double viewportPageTop = 100;
  @override
  final bool hasInnerScroller = false;
  @override
  final double innerScrollerTop = 0;
  @override
  final double innerScrollerHeight = 0;
  @override
  final List<double>? innerScrollerTransform = null;
  @override
  final ContainerId? innerScrollerContainerId = null;
  @override
  final List<CarouselInput> carousels = const [];
  @override
  final DateTime captureTime = DateTime(2026, 1, 1);
}

void main() {
  group('#78 behavioral — anomaly events reach a wired logger', () {
    test('DriftTracker logs the non-finite drift skip', () {
      final logs = <String>[];
      final tracker = DriftTracker(debugLogger: logs.add);
      tracker.addObservation(_blockWithTop(50), const Offset(double.nan, 0));
      expect(logs.where((l) => l.contains('non-finite drift')), hasLength(1),
          reason: '#78 — a non-finite input is exactly what a consumer '
              'wires a logger to see');
    });

    test('DriftTracker logs the non-finite top skip', () {
      final logs = <String>[];
      final tracker = DriftTracker(debugLogger: logs.add);
      tracker.addObservation(_blockWithTop(double.nan), const Offset(1, 1));
      expect(logs.where((l) => l.contains('non-finite top')), hasLength(1));
    });

    test('BlockClassifierService logs a positionLookup throw', () {
      final logs = <String>[];
      final classifier = BlockClassifierService(debugLogger: logs.add);
      final result = classifier.classifyGroups(
        textGroups: [
          [
            OcrBlock(
              text: '测试段落',
              lines: const [],
              boundingBox: const Rect.fromLTRB(100, 100, 200, 150),
            ),
          ],
        ],
        input: _TestInput(),
        fixedStickyRects: [],
        positionLookup: (_) => throw StateError('boom'),
      );
      expect(result.classified, hasLength(1),
          reason: 'the throw must not abort classification (neutral '
              'stability fallback)');
      expect(logs.where((l) => l.contains('positionLookup threw')),
          hasLength(1),
          reason: '#78 — a swallowed callback throw with no trace in any '
              'non-debug build is the silent-failure shape this splits out');
    });
  });

  group('#78 source shape — anomaly emits are NOT kDebugMode-gated', () {
    // The emitting statement (literal line + 2 lines above, covering the
    // `if (kDebugMode) {` block-opener form) must not carry the gate.
    void expectUngated(String path, String literal) {
      final lines = File(path).readAsLinesSync();
      final idx = lines.indexWhere((l) => l.contains(literal));
      expect(idx, greaterThanOrEqualTo(0),
          reason: 'anomaly literal "$literal" not found in $path — if the '
              'message changed, update this lock in the same PR');
      final region = lines.sublist(max(0, idx - 2), idx + 1).join('\n');
      expect(region.contains('kDebugMode'), isFalse,
          reason: '#78 — "$literal" is anomaly-class: it must reach a wired '
              'logger in profile/release builds, so the emit must not sit '
              'behind the kDebugMode mirror (chatty lines keep the gate; '
              'this one must not)');
    }

    test('DriftTracker non-finite drift emit is ungated', () {
      expectUngated('lib/src/drift_tracker.dart', 'skip non-finite drift');
    });

    test('DriftTracker non-finite top emit is ungated', () {
      expectUngated('lib/src/drift_tracker.dart', 'skip non-finite top');
    });

    test('BlockClassifier positionLookup-throw emit is ungated', () {
      expectUngated('lib/src/block_classifier.dart', 'positionLookup threw');
    });
  });
}
