// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause
//
// #116 finding A, equivalence guard: every committed `*.ab.json`'s
// `agreementWeighted` arm (StepResponse.damp, band off in both replay
// tools per doc/replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md) was
// produced by `abReport()` BEFORE the pre-pass restructuring. Replaying
// every one of the 17 committed streams now and comparing `mergeCount`,
// `nestedFragmentMerges`, and (where the committed file's schema carries
// it) `identityByCapture` against the committed numbers pins that the
// restructuring did not silently change damp's own numerics.
//
// NOTE: band-relaxed fallback is off (`BandFallbackConfig.mode` defaults
// to `BandFallbackMode.off`) in every one of these streams, so this test
// does NOT exercise finding A's actual regression (the band branch is
// unreachable here) — see
// stabilization_engine_prepass_band_interleaving_test.dart for the test
// that does. This is a regression guard on top of that proof, not a
// substitute for it.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../tool/replay/src/ab_report.dart';
import '../../tool/replay/src/capture_stream.dart';

/// The 17-stream #116 A/B corpus: every `.jsonl` with a committed
/// `.ab.json` counterpart, excluding the `.grouped` pregroup variants
/// (those replay through an extra pregroup stage `abReport` does not
/// reproduce on its own).
const _streams = [
  'doc/replay/validation/2026-08-dynamic-reflow/pushdown',
  'doc/replay/validation/2026-08-dynamic-reflow/rewrap',
  'doc/replay/validation/2026-08-dynamic-reflow/variants/pushdown-050',
  'doc/replay/validation/2026-08-dynamic-reflow/variants/pushdown-150',
  'doc/replay/validation/2026-08-dynamic-reflow/variants/pushdown-300-early',
  'doc/replay/validation/2026-08-dynamic-reflow/variants/pushdown-300-late',
  'doc/replay/validation/2026-08-dynamic-reflow/variants/pushdown-600',
  'doc/replay/validation/2026-08-dynamic-reflow/variants/pushup-300',
  'doc/replay/validation/2026-08-mlkit-on-device/dwell-bk',
  'doc/replay/validation/2026-08-mlkit-on-device/dwell',
  'doc/replay/validation/2026-08-mlkit-on-device/scroll',
  'doc/replay/validation/2026-08-paddleocr-matrix/ocr-jitter-dwell',
  'doc/replay/validation/2026-08-paddleocr-matrix/scroll',
  'doc/replay/validation/2026-08-paddleocr-matrix/stable-dwell',
  'doc/replay/validation/2026-08-tesseract-matrix/ocr-jitter-dwell',
  'doc/replay/validation/2026-08-tesseract-matrix/scroll',
  'doc/replay/validation/2026-08-tesseract-matrix/stable-dwell',
];

void main() {
  group('committed *.ab.json agreementWeighted arm (#116 finding A '
      'equivalence guard)', () {
    for (final base in _streams) {
      test(base, () {
        final stream =
            CaptureStream.parse(File('$base.jsonl').readAsLinesSync());
        final committed =
            jsonDecode(File('$base.ab.json').readAsStringSync())
                as Map<String, Object?>;
        final committedArm =
            committed['agreementWeighted'] as Map<String, Object?>;

        final fresh = abReport(stream);
        final freshArm = fresh['agreementWeighted'] as Map<String, Object?>;

        expect(freshArm['mergeCount'], committedArm['mergeCount'],
            reason: '$base: mergeCount under StepResponse.damp must be '
                'byte-identical to the committed reference');
        expect(
            freshArm['nestedFragmentMerges'],
            committedArm['nestedFragmentMerges'],
            reason: '$base: nestedFragmentMerges under StepResponse.damp '
                'must be byte-identical to the committed reference');

        if (committedArm.containsKey('identityByCapture')) {
          expect(freshArm['identityByCapture'],
              committedArm['identityByCapture'],
              reason: '$base: identityByCapture under StepResponse.damp '
                  'must be byte-identical to the committed reference');
        }
      });
    }
  });
}
