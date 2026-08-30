// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause
//
// #116 finding A, equivalence guard: every committed `*.ab.json`'s
// `agreementWeighted` arm (StepResponse.damp, band off in both replay
// tools per doc/replay/validation/2026-08-dynamic-reflow/EXPERIMENT.md) was
// produced by `abReport()` BEFORE the pre-pass restructuring. Replaying
// every one of the 17 committed streams now and comparing `mergeCount`
// and `nestedFragmentMerges` against the committed numbers pins that the
// restructuring did not silently change damp's own numerics.
//
// NOTE: band-relaxed fallback is off (`BandFallbackConfig.mode` defaults
// to `BandFallbackMode.off`) in every one of these streams, so this test
// does NOT exercise finding A's actual regression (the band branch is
// unreachable here) — see
// stabilization_engine_prepass_band_interleaving_test.dart for the test
// that does. This is a regression guard on top of that proof, not a
// substitute for it.
//
// #121 (on top of the above): a committed file's `legacy` and
// `agreementWeighted` arms must carry EVERY field `_arm()` emits — the
// whole schema listed in `_armFields` below, each entry compared for
// equality against a fresh replay rather than merely checked for
// presence, and no longer silently skipped via a `containsKey` guard.
// The `agreementSnap`/`agreementCoherent` arms must be present. Applies
// to every stream except the two carved out below.
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

/// #121: `pushdown`/`rewrap` are dynamic-reflow's original two streams —
/// committed before the `variants/*` split (#116) and before the
/// per-capture step-response fields existed at all. They still carry the
/// 5-field / 2-arm schema that #121's nine files were regenerated out
/// of, but are NOT in that issue's file list, so tightening their check
/// is out of this guard's scope; they keep the pre-#121 lenient
/// (`containsKey`-guarded) check below instead of the unconditional
/// full-schema one every other stream gets.
const _preStepResponseSchema = {
  'doc/replay/validation/2026-08-dynamic-reflow/pushdown',
  'doc/replay/validation/2026-08-dynamic-reflow/rewrap',
};

/// #121: the WHOLE per-arm schema — every key `_arm()` returns in
/// `tool/replay/src/ab_report.dart`, in that function's own order. Each
/// one is checked for equality against a fresh replay, not just for
/// presence, so "the regeneration was purely additive" is enforced
/// rather than declared. Keep this list in sync with `_arm()`: a field
/// added there and not here is a field the committed references quietly
/// stop being pinned on.
const _armFields = [
  'mergeCount',
  'nestedFragmentMerges',
  'displacementByObsN',
  'wellObservedPconf',
  'wellObservedPconfSaturated',
  'meanTopLagByCapture',
  'stepEventsByCapture',
  'identityByCapture',
];

/// Assert `$base`'s committed [armName] arm carries every [_armFields]
/// entry and that each equals the fresh replay's value. The arm name is
/// interpolated into every `reason` so a red line says WHICH arm of
/// which stream drifted, not just which stream.
void _expectArmEquivalent(
  String base,
  String armName,
  Map<String, Object?> freshArm,
  Map<String, Object?> committedArm,
) {
  for (final field in _armFields) {
    expect(committedArm.keys, contains(field),
        reason: '$base/$armName: committed .ab.json is missing '
            '$field (#121)');
    expect(freshArm[field], committedArm[field],
        reason: '$base/$armName: $field must be byte-identical to the '
            'committed reference');
  }
}

void main() {
  group('committed *.ab.json equivalence (#116 finding A guard, #121 '
      'committed-schema equality)', () {
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

        if (_preStepResponseSchema.contains(base)) {
          // Pre-#121-schema streams: the original lenient check — only
          // assert a field the committed file actually claims to carry.
          // Out of #121's scope (see the const's doc comment above).
          if (committedArm.containsKey('identityByCapture')) {
            expect(freshArm['identityByCapture'],
                committedArm['identityByCapture'],
                reason: '$base: identityByCapture under StepResponse.damp '
                    'must be byte-identical to the committed reference');
          }
          return;
        }

        // #121: every other stream's committed file must carry the full
        // per-arm schema, field for field — a missing OR drifted field
        // here IS the regression the issue exists to catch, not
        // something to skip.
        _expectArmEquivalent(
            base, 'agreementWeighted', freshArm, committedArm);
        _expectArmEquivalent(
            base,
            'legacy',
            fresh['legacy'] as Map<String, Object?>,
            committed['legacy'] as Map<String, Object?>);

        for (final armName in ['agreementSnap', 'agreementCoherent']) {
          expect(committed.keys, contains(armName),
              reason: '$base: committed .ab.json is missing the '
                  '$armName arm entirely (#121)');
        }
      });
    }
  });
}
