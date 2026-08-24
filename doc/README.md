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
| [`benchmarks/2026-08-batch-size.md`](benchmarks/2026-08-batch-size.md) | Wall time for `stabilize()` and `groupIntoParagraphs` at 100–2000 blocks (#97), measured by [`benchmark/stabilize_benchmark.dart`](../benchmark/stabilize_benchmark.dart). |
| [`media/`](media/) | The README demo GIF + its renderer. Regenerate: [`tool/replay/dump_frames.dart`](../tool/replay/dump_frames.dart) → [`media/render_demo_gif.py`](media/render_demo_gif.py); `test/demo_gif_provenance_test.dart` pins the engine half of the claim. |
| [`audit/2026-07-20-package-audit.md`](audit/2026-07-20-package-audit.md) | The v0.5.0 full package audit — the findings behind the 0.6.0 release; tests cite its § numbers. |

Replay tooling itself lives in [`tool/replay/`](../tool/replay/):
`dart tool/replay/replay.dart ab-report <capture.jsonl>` produces the
report JSONs the validation entries commit.

The published package archive ships only `replay/` (schema + validation)
— `audit/` and `media/` are repo-only (see `.pubignore`).
