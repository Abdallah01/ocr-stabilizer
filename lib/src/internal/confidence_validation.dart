// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: BSD-3-Clause

/// Throw [ArgumentError] if [raw] is not a finite double in `[0.0, 1.0]`.
///
/// Centralises the confidence-range predicate used at every state-owning
/// boundary that holds a Confidence-typed field — `DefaultTrackedBlock`
/// ctor, `StabilizationEngine._assertValidConfidence` (called by both
/// `stabilize` and `merge` entry guards), `MergeResult` ctor, and the
/// `PositionConfidence.from` / `TextConfidence.from` validated factories.
/// Future tightening (banning subnormals, changing the upper bound,
/// etc.) happens here instead of five call sites.
///
/// **Throws rather than asserts**: asserts strip in release, and
/// production-critical invariants on state-owning types must hold in
/// release builds too. The MergeResult ctor + engine entry guard +
/// DefaultTrackedBlock ctor are storage / state-owning boundaries where
/// silently admitting NaN or out-of-range values could corrupt drift
/// correction or quality scoring downstream.
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
