// SPDX-FileCopyrightText: 2026 ocr-stabilizer authors
// SPDX-License-Identifier: MIT

// The #119 lever flags of `replay.dart`, parsed strictly.
//
// PR #129 review CONF2: the CLI used to match `--coherent-floor=<number>`
// with a value regex, so a malformed value (`--coherent-floor=abc`, a
// missing `=`) simply never matched — the run went ahead with the lever
// OFF and printed a baseline-looking report. Here a flag that is present
// but unusable is an ERROR, and a flag is recognised wherever it sits in
// argv.

typedef LeverArgs = ({
  double? coherentFloorPx,
  int? coherentReanchorMinBlocks,
  bool coherentAdoptAgreeing,
  String? error,
});

const _kFloorFlag = '--coherent-floor';
const _kReanchorFlag = '--coherent-reanchor';
const _kAdoptFlag = '--coherent-adopt';

LeverArgs _error(String message) => (
      coherentFloorPx: null,
      coherentReanchorMinBlocks: null,
      coherentAdoptAgreeing: false,
      error: message,
    );

/// Parses `--coherent-floor=<px>`, `--coherent-reanchor=<count>` and the
/// bare `--coherent-adopt` (#119 item 2; it takes no value) out of [args].
/// Absent flags yield `null` / `false`; a present-but-malformed flag yields
/// a non-null [LeverArgs.error] naming the offending argument.
LeverArgs parseLeverArgs(Iterable<String> args) {
  double? floor;
  int? reanchor;
  var adopt = false;
  for (final a in args) {
    if (a.startsWith(_kFloorFlag)) {
      final raw = a.startsWith('$_kFloorFlag=')
          ? a.substring(_kFloorFlag.length + 1)
          : null;
      final v = raw == null ? null : double.tryParse(raw);
      if (v == null || !v.isFinite || v <= 0) {
        return _error('$_kFloorFlag must be a finite number > 0, e.g. '
            '$_kFloorFlag=390 (got: $a)');
      }
      floor = v;
    } else if (a.startsWith(_kReanchorFlag)) {
      final raw = a.startsWith('$_kReanchorFlag=')
          ? a.substring(_kReanchorFlag.length + 1)
          : null;
      final v = raw == null ? null : int.tryParse(raw);
      if (v == null || v < 1) {
        return _error('$_kReanchorFlag must be an integer >= 1, e.g. '
            '$_kReanchorFlag=2 (got: $a)');
      }
      reanchor = v;
    } else if (a.startsWith(_kAdoptFlag)) {
      if (a != _kAdoptFlag) {
        return _error('$_kAdoptFlag takes no value (got: $a)');
      }
      adopt = true;
    }
  }
  return (
    coherentFloorPx: floor,
    coherentReanchorMinBlocks: reanchor,
    coherentAdoptAgreeing: adopt,
    error: null,
  );
}
