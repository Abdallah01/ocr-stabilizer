# Seed-variance suite driver (#136).
#
# Regenerates the whole Tesseract half of the dynamic-reflow corpus — the
# seven step streams, the `rewrap` control and the three tesseract-matrix
# controls — for ONE (seed, perturb-seed) configuration, into
# <out_root>/<label>/, named the way the EXPERIMENT.md tables cite them:
#
#   pushdown-050 pushdown-150 pushdown-300 pushdown-600 pushup-300
#   pushdown-300-early pushdown-300-late rewrap
#   tess-stable-dwell tess-jitter-dwell tess-scroll
#
# The two generators run with their own defaults except for the knobs a
# stream varies. Each step run also writes a rewrap.jsonl, and --reflow-at
# governs BOTH scenarios of a run, so only the runs at the default
# reflow-at (7) produce the committed rewrap shape; the gap knobs never
# touch the RNG, so those five rewraps are byte-identical — the driver
# keeps the first and CHECKS the other four against it rather than
# assuming. The early / late runs' rewraps (reflow at 3 / 10) are
# discarded.
#
# The step streams and the controls share the page: both generators build
# the same paragraphs from the same seed (same vocabulary, same draw
# order), so a configuration's controls are "the same page, no reflow".
#
# Usage:
#   python gen_seed_suite.py <tesseract.exe> <out_root> --seed S [--perturb-seed P] [--label NAME]
#
# label defaults to sSS-r1 (no perturb-seed) / sSS-r2 (perturb-seed given).
import argparse
import filecmp
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent            # .../2026-08-dynamic-reflow/variants
REFLOW_GEN = HERE.parent / 'gen_corpus.py'
MATRIX_GEN = HERE.parent.parent / '2026-08-tesseract-matrix' / 'gen_corpus.py'
DEFAULT_REFLOW_AT = 7

# (stream name, --gap-px, --reflow-at) — the seven committed step configs.
STEPS = [
    ('pushdown-050', 50, 7),
    ('pushdown-150', 150, 7),
    ('pushdown-300', 300, 7),
    ('pushdown-600', 600, 7),
    ('pushup-300', -300, 7),
    ('pushdown-300-early', 300, 3),
    ('pushdown-300-late', 300, 10),
]
CONTROLS = {
    'stable-dwell': 'tess-stable-dwell',
    'ocr-jitter-dwell': 'tess-jitter-dwell',
    'scroll': 'tess-scroll',
}


def parse_args():
    p = argparse.ArgumentParser(description='Seed-variance suite driver (#136).')
    p.add_argument('tesseract_exe')
    p.add_argument('out_root')
    p.add_argument('--seed', type=int, required=True)
    p.add_argument('--perturb-seed', type=int, default=None)
    p.add_argument('--label', default=None)
    return p.parse_args()


def run(gen, tess, out_dir, extra):
    cmd = [sys.executable, str(gen), tess, str(out_dir)] + extra
    r = subprocess.run(cmd, capture_output=True, text=True, encoding='utf-8')
    if r.returncode != 0:
        sys.stderr.write(r.stdout + r.stderr)
        raise SystemExit(f'generator failed: {" ".join(cmd)}')
    return r.stdout


def main():
    a = parse_args()
    label = a.label or f's{a.seed:02d}-r{1 if a.perturb_seed is None else 2}'
    dest = Path(a.out_root) / label
    dest.mkdir(parents=True, exist_ok=True)
    seed_args = ['--seed', str(a.seed)]
    if a.perturb_seed is not None:
        seed_args += ['--perturb-seed', str(a.perturb_seed)]
    t0 = time.time()
    rewrap_ref = None
    with tempfile.TemporaryDirectory() as tmp:
        for name, gap, at in STEPS:
            out = Path(tmp) / name
            out.mkdir()
            run(REFLOW_GEN, a.tesseract_exe, out,
                ['--gap-px', str(gap), '--reflow-at', str(at)] + seed_args)
            shutil.move(out / 'pushdown.jsonl', dest / f'{name}.jsonl')
            if at != DEFAULT_REFLOW_AT:
                pass  # a rewrap at another reflow-at: not the committed shape
            elif rewrap_ref is None:
                rewrap_ref = dest / 'rewrap.jsonl'
                shutil.move(out / 'rewrap.jsonl', rewrap_ref)
            elif not filecmp.cmp(out / 'rewrap.jsonl', rewrap_ref, shallow=False):
                raise SystemExit(f'{label}: rewrap.jsonl from {name} differs from '
                                 f'the first run — the gap knobs consumed the RNG?')
            print(f'{label}: {name} done ({time.time() - t0:.0f}s)', flush=True)
        out = Path(tmp) / 'matrix'
        out.mkdir()
        run(MATRIX_GEN, a.tesseract_exe, out, seed_args)
        for src, dst in CONTROLS.items():
            shutil.move(out / f'{src}.jsonl', dest / f'{dst}.jsonl')
        print(f'{label}: controls done ({time.time() - t0:.0f}s)', flush=True)
    streams = sorted(p.stem for p in dest.glob('*.jsonl'))
    expected = sorted([s[0] for s in STEPS] + ['rewrap'] + list(CONTROLS.values()))
    if streams != expected:
        raise SystemExit(f'{label}: streams {streams} != expected {expected}')
    print(f'{label}: {len(streams)} streams in {dest}')


if __name__ == '__main__':
    main()
