// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT
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
// The `agreementSnap`/`agreementCoherent` arms must be present AND
// carry that same schema, compared the same way. Applies to all 17
// streams — the two dynamic-reflow originals were regenerated to the
// full schema on 2026-08-30 (#125) and the lenient branch they took is
// gone.
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

/// The arms `abReport()` emits UNCONDITIONALLY, in its own order — the set
/// every committed file must carry and match. The optional arms
/// (`agreementCoherentFloor`, `agreementCoherentReanchor`) appear only
/// when their tunable is set and are never committed. #127 pins this list
/// against a live report: promoting an optional arm to a default, or
/// adding a new one, without listing it here goes red instead of leaving
/// that arm compared against nothing on all 17 committed files.
const _defaultArms = [
  'legacy',
  'agreementWeighted',
  'agreementSnap',
  'agreementCoherent',
];

/// #121: the WHOLE per-arm schema — every key `_arm()` returns in
/// `tool/replay/src/ab_report.dart`, in that function's own order. Each
/// one is checked for equality against a fresh replay, not just for
/// presence, so "the regeneration was purely additive" is enforced
/// rather than declared. #127: this list is no longer kept in sync by
/// hand — the schema-sync group at the bottom builds a real arm through
/// `abReport()` and asserts its keys ARE this list, so a field added to
/// `_arm()` and not here goes red instead of silently un-pinning that
/// field on all 17 committed references.
///
/// #125: `pushdown`/`rewrap` (dynamic-reflow's original two streams) were
/// regenerated from their committed `.jsonl` on 2026-08-30 and carry this
/// full schema too, so the pre-#121 lenient (`containsKey`-guarded) branch
/// they used to take is gone — every committed report is held to the same
/// unconditional full-schema equality.
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

        // #121 (+ #125 for pushdown/rewrap): every committed file must
        // carry the full per-arm schema on EVERY default arm, field for
        // field — a missing OR drifted field here IS the regression the
        // issue exists to catch, not something to skip. Presence alone
        // was vacuous coverage for the two #116 candidate arms: every
        // number inside a regenerated `agreementSnap`/`agreementCoherent`
        // arm could drift with the key still there. They are not
        // duplicates of `agreementWeighted` either: a `snap` re-anchor or
        // a `coherentShift` batch vote moves `meanTopLagByCapture` and
        // `displacementByObsN` where `damp` leaves them, so these are the
        // only assertions in the suite pinning those numerics on the
        // committed corpus. Iterating `_defaultArms` (pinned to the live
        // report by #127 below) rather than a list written here keeps a
        // newly promoted default arm from slipping past this loop.
        for (final armName in _defaultArms) {
          expect(committed.keys, contains(armName),
              reason: '$base: committed .ab.json is missing the '
                  '$armName arm entirely (#121)');
          _expectArmEquivalent(
              base,
              armName,
              fresh[armName] as Map<String, Object?>,
              committed[armName] as Map<String, Object?>);
        }
      });
    }
  });

  group('#127 schema sync: _armFields mirrors _arm()', () {
    test(
        'every arm abReport() emits carries EXACTLY the _armFields keys, in '
        '_arm()\'s own order — a field added there and not here would '
        'silently un-pin it on all 17 committed references', () {
      final stream = CaptureStream.parse(
          File('${_streams.first}.jsonl').readAsLinesSync());
      final fresh = abReport(stream);
      final arms = fresh.entries
          .where((e) =>
              e.value is Map && (e.value as Map).containsKey('mergeCount'))
          .toList();
      // Exact, ordered equality — not `containsAll`, which is a superset
      // matcher: a fifth default arm would pass it, get its schema checked
      // below, and never be compared against any committed file.
      expect(arms.map((e) => e.key).toList(), _defaultArms,
          reason: 'the default (unconditional) arms abReport() emits must '
              'be exactly _defaultArms, in order — an arm promoted to or '
              'added as a default and not listed there is compared against '
              'nothing on all 17 committed references (#127)');
      for (final arm in arms) {
        expect((arm.value as Map<String, Object?>).keys.toList(), _armFields,
            reason: '${arm.key}: _armFields is a hand-written mirror of '
                '_arm() — the two have drifted (#127)');
      }
    });
  });
}
