// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

/// Throw [ArgumentError] if [raw] is not a finite double in `[0.0, 1.0]`.
///
/// Used by every state-owning boundary that owns a Confidence-typed
/// field — `DefaultTrackedBlock` ctor, `StabilizationEngine.stabilize` /
/// `StabilizationEngine.merge` entry guards, `MergeResult` ctor — so the
/// predicate and message template live in one place. Future tightening
/// (banning subnormals, changing the upper bound, etc.) happens here
/// instead of three call sites.
///
/// **Throws rather than asserts** per project policy
/// (`feedback_assert_vs_throw_in_storage`): asserts strip in release,
/// and production-critical invariants on state-owning types must hold
/// in release builds too.
///
/// [field] is the parameter name passed to [ArgumentError.value]
/// (e.g. `'positionConfidence'`).
///
/// [prefix] is prepended to the human-readable message when present:
/// - `'fresh'` → `'fresh: must be a finite double in [0.0, 1.0]'`
/// - `'observation at index 3'` → `'observation at index 3: must be ...'`
/// - `null` → `'must be a finite double in [0.0, 1.0]'`
void assertConfidenceRange(String field, double raw, {String? prefix}) {
  if (!raw.isFinite || raw < 0.0 || raw > 1.0) {
    final ctx = prefix != null ? '$prefix: ' : '';
    throw ArgumentError.value(
      raw,
      field,
      '${ctx}must be a finite double in [0.0, 1.0]',
    );
  }
}
