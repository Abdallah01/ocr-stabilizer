// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

/// The committed replay corpus: every `.jsonl` under
/// `doc/replay/validation/` that carries a committed `.ab.json`
/// counterpart, excluding the `.grouped` pregroup variants (those replay
/// through an extra pregroup stage the reports do not reproduce on their
/// own). Paths are relative to the package root, without extension —
/// `<path>.jsonl` is the stream, `<path>.ab.json` the A/B reference and
/// `<path>.diff.json` the #150 differential reference.
///
/// One list, two consumers: `test/replay/ab_report_committed_equivalence_test.dart`
/// (the A/B numbers) and `test/replay/differential_committed_test.dart`
/// (the per-capture engine digest). Adding a stream here without both
/// committed files goes red in both tests.
const List<String> kCommittedStreams = [
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

/// The streams the #150 differential harness digests: every A/B stream
/// plus the committed streams that have no `.ab.json` (the 2.6.0 zoom
/// corpus, replayed live by `experiment_doc_zoom_tables_test.dart`). A
/// dedup mutant survived the 17 A/B streams and died only on the zoom
/// streams (PR #164), so the harness covers both sets.
const List<String> kDifferentialStreams = [
  ...kCommittedStreams,
  'doc/replay/validation/2026-09-zoom/zoom-080',
  'doc/replay/validation/2026-09-zoom/zoom-080-rewrap',
  'doc/replay/validation/2026-09-zoom/zoom-125',
  'doc/replay/validation/2026-09-zoom/zoom-125-rewrap',
];
