# Zoom-corpus report (#135): the tables of ../2026-09-zoom/EXPERIMENT.md,
# derived by replaying every committed stream through
# `dart tool/replay/replay.dart transform-report` (the shipping
# configuration; see tool/replay/src/transform_report.dart).
#
# Usage (from the package root; needs the Dart SDK on PATH):
#   python doc/replay/validation/2026-09-zoom/zoom_report.py > tables.md
#
# Table 1 — the four zoom streams, per capture around the event (captures
# 5-9; the zoom renders from capture 7): scale, translation, pairs,
# rejected, residual, span, gap share, identity census.
# Table 2 — every NON-zoom stream in the repository (the 17 published
# streams and the #136 variants found on disk): the peak |scale - 1| over
# its captures, and the residual, pairs and gap share at that capture.
# These are the controls for a zoom reading: whatever rule names the zoom
# streams must name none of them.
# Table 3 — the reading rule's margins: for each residual cap, pair floor
# and gap-share cap, the largest control deviation over every capture
# under all three, which capture set it, and how many captures qualified.
# "deviation" is |scale - 1| throughout (the column names avoid the bars,
# which a Markdown table would read as cell separators).
import json
import re
import subprocess
import sys
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
V = 'doc/replay/validation'
ZOOM = f'{V}/2026-09-zoom'
REFLOW = f'{V}/2026-08-dynamic-reflow'

ZOOM_STREAMS = ['zoom-125', 'zoom-125-rewrap', 'zoom-080', 'zoom-080-rewrap']
ZOOM_CAPS = [5, 6, 7, 8, 9]

PUBLISHED = {
    'pushdown-300': f'{REFLOW}/pushdown',
    'rewrap': f'{REFLOW}/rewrap',
    **{n: f'{REFLOW}/variants/{n}' for n in [
        'pushdown-050', 'pushdown-150', 'pushdown-600', 'pushup-300',
        'pushdown-300-early', 'pushdown-300-late']},
    'tess-stable-dwell': f'{V}/2026-08-tesseract-matrix/stable-dwell',
    'tess-jitter-dwell': f'{V}/2026-08-tesseract-matrix/ocr-jitter-dwell',
    'tess-scroll': f'{V}/2026-08-tesseract-matrix/scroll',
    'paddle-stable-dwell': f'{V}/2026-08-paddleocr-matrix/stable-dwell',
    'paddle-jitter-dwell': f'{V}/2026-08-paddleocr-matrix/ocr-jitter-dwell',
    'paddle-scroll': f'{V}/2026-08-paddleocr-matrix/scroll',
    'mlkit-dwell': f'{V}/2026-08-mlkit-on-device/dwell',
    'mlkit-dwell-bk': f'{V}/2026-08-mlkit-on-device/dwell-bk',
    'mlkit-scroll': f'{V}/2026-08-mlkit-on-device/scroll',
}
# The #136 configurations: every `sNN-rN` directory under variants/ (the
# pin test enumerates the same directories, so a new configuration lands
# in the peak table or fails the test).
VARIANT_CONFIGS = sorted(
    p.name for p in (ROOT / REFLOW / 'variants').iterdir()
    if p.is_dir() and re.fullmatch(r's\d+-r\d+', p.name))
VARIANT_STREAMS = ['pushdown-050', 'pushdown-150', 'pushdown-300',
                   'pushdown-600', 'pushup-300', 'pushdown-300-early',
                   'pushdown-300-late', 'rewrap', 'tess-stable-dwell',
                   'tess-jitter-dwell', 'tess-scroll']
# The margins table's axes. None = no bound on that axis ('any').
RESIDUAL_CAPS = [5, 10, 20, 40, None]
PAIR_FLOORS = [3, 6]
GAP_CAPS = [0.5, None]


def report(base):
    cmd = ['dart', 'tool/replay/replay.dart', 'transform-report', f'{base}.jsonl']
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                       encoding='utf-8', shell=sys.platform == 'win32')
    if r.returncode != 0:
        raise SystemExit(f'replay failed ({r.returncode}): {" ".join(cmd)}\n{r.stderr}')
    return json.loads(r.stdout)


def fmt(v, decimals=1):
    if v is None:
        return '—'
    q = Decimal(1).scaleb(-decimals)
    return str(Decimal(v).quantize(q, rounding=ROUND_HALF_UP))


def table(header, rows):
    out = [header, '|' + '|'.join(['---'] * (header.count('|') - 1)) + '|']
    out += ['| ' + ' | '.join(str(c) for c in r) + ' |' for r in rows]
    return '\n'.join(out)


def res_cell(cap):
    return 'any' if cap is None else f'< {cap} px'


def gap_cell(cap):
    return 'any' if cap is None else f'<= {cap}'


def main():
    # Table 1.
    rows1 = []
    for name in ZOOM_STREAMS:
        d = report(f'{ZOOM}/{name}')
        for cap in ZOOM_CAPS:
            v = d['transformByCapture'].get(str(cap))
            t = d['identityByCapture'][str(cap)]
            census = f"{t['merged']} / {t['admitted']}"
            if v is None:
                rows1.append([name, cap] + ['—'] * 7 + [census])
            else:
                rows1.append([name, cap, fmt(v['scale'], 3),
                              f"{fmt(v['dx'])} / {fmt(v['dy'])}", v['pairs'],
                              v['rejected'], fmt(v['residualPx']),
                              fmt(v['spanPx']), fmt(v['gapShare'], 2), census])
        print(f'{name} done', file=sys.stderr, flush=True)

    # Table 2 — every non-zoom stream's peak-deviation capture; and the
    # per-capture (deviation, residual, pairs, gap share) points Table 3
    # needs.
    points = []  # (label, cap, dev, residual, pairs, gap)
    rows2 = []

    def add(label, base):
        d = report(base)
        s = d['summary']
        for cap, v in d['transformByCapture'].items():
            if v is not None:
                points.append((label, int(cap), abs(v['scale'] - 1),
                               v['residualPx'], v['pairs'], v['gapShare']))
        if s['peakScaleDeviation'] is None:
            rows2.append([label] + ['—'] * 6)
            return
        rows2.append([label, fmt(s['peakScale'], 3),
                      fmt(s['peakScaleDeviation'], 3),
                      fmt(s['residualAtPeakPx']), s['pairsAtPeak'],
                      fmt(s['gapShareAtPeak'], 2),
                      s['peakScaleDeviationCapture']])

    for label, base in PUBLISHED.items():
        add(f's93-r1 / {label}' if label in VARIANT_STREAMS else label, base)
        print(f'{label} done', file=sys.stderr, flush=True)
    for cfg in VARIANT_CONFIGS:
        for name in VARIANT_STREAMS:
            add(f'{cfg} / {name}', f'{REFLOW}/variants/{cfg}/{name}')
        print(f'{cfg} done', file=sys.stderr, flush=True)

    # Table 3: for each residual cap R, pair floor P and gap-share cap G,
    # the largest control deviation over every CAPTURE whose residual is
    # under R, whose fit used at least P pairs and whose gap share is at
    # most G (not only the peak capture) — the floor a zoom reading must
    # clear — which capture set it, and the population.
    rows3 = []
    for R in RESIDUAL_CAPS:
        for P in PAIR_FLOORS:
            for G in GAP_CAPS:
                under = [p for p in points
                         if (R is None or p[3] < R) and p[4] >= P
                         and (G is None or p[5] <= G)]
                if not under:
                    rows3.append([res_cell(R), f'>= {P}', gap_cell(G), '—', '—', 0])
                    continue
                worst = max(under, key=lambda p: p[2])
                rows3.append([res_cell(R), f'>= {P}', gap_cell(G),
                              fmt(worst[2], 3),
                              f'{worst[0]} (cap {worst[1]}, {worst[4]} pairs)',
                              len(under)])

    print(table('| stream | capture | scale | translation dx / dy | pairs | '
                'rejected | residual (px) | span (px) | gap share | '
                'merged / admitted |', rows1))
    print()
    print(table('| stream | peak scale | peak deviation | residual at peak (px) '
                '| pairs at peak | gap share at peak | capture |', rows2))
    print()
    print(table('| residual under | pairs at least | gap share at most | '
                'largest control deviation | set by | '
                'control captures under all three |', rows3))


if __name__ == '__main__':
    main()
