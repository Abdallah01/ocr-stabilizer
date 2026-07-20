import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:ocr_stabilizer/ocr_stabilizer.dart';

// =============================================================================
// PRIMARY MATCH VIA JACCARD-ONLY SIMILARITY (v0.5.1)
// =============================================================================
// Regression: a candidate admitted purely through the Jaccard arm can have
// Levenshtein 0.0 (full character reordering, e.g. a two-character swap).
// Pre-0.5.1 the best-candidate loop seeded bestPrimarySim at 0.0 with a
// strict `>` comparison, so such a candidate never registered and the
// observation was treated as brand new.
// =============================================================================

DefaultTrackedBlock<void> _block(String text) {
  return DefaultTrackedBlock<void>(
    absoluteRect: const AbsoluteRect(Rect.fromLTWH(10, 100, 200, 30)),
    payload: null,
    originalText: text,
  );
}

void main() {
  group('StabilizationEngine primary match via Jaccard arm', () {
    test('reordered two-character text merges instead of duplicating', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
        merger: (existing, fresh, merge) => existing.applyMerge(merge),
      );

      final r1 = engine.stabilize([_block('ab')]);
      expect(r1.stableBlocks, hasLength(1));
      expect(r1.stableBlocks.single.observationCount, 1);

      // "ba" vs "ab": Levenshtein 0.0 (2 edits / max length 2), Jaccard 1.0
      // — scores.match is true purely through the Jaccard arm.
      final r2 = engine.stabilize([_block('ba')]);
      expect(r2.stableBlocks, hasLength(1));
      expect(
        r2.stableBlocks.single.observationCount,
        2,
        reason: 'Jaccard-only similarity must merge as a primary match, '
            'not spawn a new block',
      );
    });

    test('reordered two-character CJK text merges (OCR segment swap)', () {
      final engine = StabilizationEngine<DefaultTrackedBlock<void>, void>(
        merger: (existing, fresh, merge) => existing.applyMerge(merge),
      );

      engine.stabilize([_block('北京')]);
      final r2 = engine.stabilize([_block('京北')]);
      expect(r2.stableBlocks, hasLength(1));
      expect(r2.stableBlocks.single.observationCount, 2);
    });
  });
}
