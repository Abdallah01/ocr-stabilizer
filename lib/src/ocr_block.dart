// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

import 'types/geometry.dart' show Rect;

/// A recognized text element (word or character).
class OcrElement {
  /// Bounding box in image coordinates.
  final Rect boundingBox;

  /// Recognized text content.
  final String text;

  /// Creates a recognized text element.
  const OcrElement({required this.boundingBox, required this.text});
}

/// A recognized text line within a block.
class OcrLine {
  /// Bounding box in image coordinates.
  final Rect boundingBox;

  /// Recognized text content.
  final String text;

  /// Elements (words/characters) within this line.
  final List<OcrElement> elements;

  /// Creates a recognized text line.
  const OcrLine({
    required this.boundingBox,
    required this.text,
    required this.elements,
  });
}

/// A recognized text block (paragraph-level).
class OcrBlock {
  /// Bounding box in image coordinates.
  final Rect boundingBox;

  /// Recognized text content.
  final String text;

  /// Lines within this block.
  final List<OcrLine> lines;

  /// Native confidence from the engine (0.0–1.0), or `null` if unavailable.
  final double? confidence;

  /// Creates an [OcrBlock].
  ///
  /// [confidence] should be in [0.0, 1.0] or null. Out-of-range values
  /// are clamped to the valid range (engines may return unclamped values).
  /// NaN is treated as unavailable and stored as null — in IEEE-754,
  /// `nan.clamp(0.0, 1.0)` returns NaN, so clamping alone cannot contain it.
  OcrBlock({
    required this.boundingBox,
    required this.text,
    required this.lines,
    double? confidence,
  }) : confidence = (confidence == null || confidence.isNaN)
            ? null
            : confidence.clamp(0.0, 1.0);
}
