// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'tracked_block.dart';

/// Callback that determines if a block's contextual neighborhood has changed
/// enough to require re-processing (e.g., re-translation).
///
/// Designed for use during SAR merge: when a re-observed block has the same
/// text but potentially different surrounding context, this callback
/// determines whether to fire a translation-invalidated event.
///
/// **Default behavior:** If no [ContextualInvalidationCheck] is provided,
/// the engine skips contextual invalidation entirely (no-op).
///
/// **LLM use case:** Compare a context hash between fresh and existing blocks —
/// different hashes mean the surrounding text changed, so the LLM would
/// produce different output. Cast to your concrete type to access app-specific
/// fields:
///
/// ```dart
/// // Example: group signature comparison (app-specific field)
/// bool llmContextChanged(TrackedBlock fresh, TrackedBlock existing) {
///   if (fresh is MyBlock && existing is MyBlock) {
///     return fresh.groupSignature != existing.groupSignature;
///   }
///   return false;
/// }
/// ```
typedef ContextualInvalidationCheck = bool Function(
    TrackedBlock fresh, TrackedBlock existing);
