# doc/ — map

Two kinds of numbers live under this tree. **Quality numbers** (how much
boxes move, how informative confidence is) live in dated validation
entries under `replay/validation/`. **Speed numbers** (wall time per
call) live in `benchmarks/`. Everything else is schema, tooling, media,
or provenance.

| Path | What it is |
|---|---|
| [`replay/capture_schema.md`](replay/capture_schema.md) | The JSONL capture schema (v1) every corpus below uses. |
| [`replay/validation/2026-07-scale-sweep/`](replay/validation/2026-07-scale-sweep/) | **ML Kit.** Provenance for the 3× jitter allowance: displacement + confidence per allowance scale, both position models. Report JSONs only — the underlying capture streams contain third-party page text and are not distributable. |
| [`replay/validation/2026-07-perblock-scale/`](replay/validation/2026-07-perblock-scale/) | **ML Kit.** The 1.1.0 per-block agreement scale: six-scenario before/after. Report JSONs only, same reason. |
| [`replay/validation/2026-08-tesseract-matrix/`](replay/validation/2026-08-tesseract-matrix/) | **Tesseract 5.** First cross-engine entry (#94): synthetic CJK corpus, so the full capture streams ARE committed and every number regenerates end-to-end. |
| [`replay/validation/2026-08-mlkit-on-device/`](replay/validation/2026-08-mlkit-on-device/) | **ML Kit, on-device (#108).** Real Galaxy S25 captures over a synthetic page — the first ML Kit entry with COMMITTED streams (the README hero GIF renders from its dwell stream). |
| [`replay/validation/2026-08-paddleocr-matrix/`](replay/validation/2026-08-paddleocr-matrix/) | **PaddleOCR (PP-OCRv6).** Third matrix engine (#94): the SAME rendered page and perturbation schedule as the Tesseract entry, engine swapped — fully regenerable. |
| [`replay/validation/2026-08-dynamic-reflow/`](replay/validation/2026-08-dynamic-reflow/) | **Tesseract 5, dynamic reflow (#93).** Two synthesized non-rotation reflows — an image slab pushing every line below it down 300 px, and a font swap re-wrapping every line — with the regime each lands in stated (push-down: identity kept, position lags, #116; re-wrap: identity reset), a unit-of-identity addendum (the same streams replayed as lines and as pre-grouped paragraphs — grouping before tracking imports its own instability into identity), and pinned by a test. Fully regenerable. |
| [`benchmarks/2026-08-batch-size.md`](benchmarks/2026-08-batch-size.md) | Wall time for `stabilize()` and `groupIntoParagraphs` at 100–2000 blocks (#97), measured by [`benchmark/stabilize_benchmark.dart`](../benchmark/stabilize_benchmark.dart). |
| [media/](https://github.com/Abdallah01/ocr-stabilizer/tree/main/doc/media) (repo-only) | The README demo GIF + its renderer. Regenerate: [`tool/replay/dump_frames.dart`](../tool/replay/dump_frames.dart) → [media/render_demo_gif.py](https://github.com/Abdallah01/ocr-stabilizer/blob/main/doc/media/render_demo_gif.py); `test/demo_gif_provenance_test.dart` pins the engine half of the claim. |
| [audit/2026-07-20-package-audit.md](https://github.com/Abdallah01/ocr-stabilizer/blob/main/doc/audit/2026-07-20-package-audit.md) (repo-only) | The v0.5.0 full package audit — the findings behind the 0.6.0 release; tests cite its § numbers. |

Replay tooling itself lives in [`tool/replay/`](../tool/replay/):
`dart tool/replay/replay.dart ab-report <capture.jsonl>` produces the
report JSONs the validation entries commit.

The published package archive ships `replay/` (schema + validation),
`benchmarks/`, and this index — `audit/` and `media/` are repo-only (see
`.pubignore`), which is why their rows above link to GitHub.
