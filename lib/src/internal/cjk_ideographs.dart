// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// ============================================================================
// SHARED CJK IDEOGRAPH PREDICATE (internal)
// ============================================================================
// Single source of truth for "is this rune a CJK Unified Ideograph".
//
// Before 0.5.1 the package carried two divergent definitions: the confidence
// heuristic included CJK Extension B while the dedup utilities did not, so
// text consisting only of Extension-B ideographs (valid in personal names)
// produced an empty significant-char list and could never text-dedup.
// ============================================================================

/// Whether [rune] is a CJK Unified Ideograph.
///
/// Covers:
/// - CJK Unified Ideographs (U+4E00–U+9FFF)
/// - CJK Extension A (U+3400–U+4DBF)
/// - CJK Compatibility Ideographs (U+F900–U+FAFF)
/// - CJK Extension B (U+20000–U+2A6DF)
bool isCjkIdeographRune(int rune) =>
    (rune >= 0x4e00 && rune <= 0x9fff) ||
    (rune >= 0x3400 && rune <= 0x4dbf) ||
    (rune >= 0xf900 && rune <= 0xfaff) ||
    (rune >= 0x20000 && rune <= 0x2a6df);
