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
# residual, span.
# Table 2 — every NON-zoom stream in the repository (the 17 published
# streams and the 77 #136 variants): the peak |scale - 1| over its
# captures, and the residual, pairs and scale at that capture. These are
# the controls for a zoom reading: whatever rule names the zoom streams
# must name none of them.
# Table 3 — the reading rule's margins: the largest control deviation
# with a residual under R, for a few R, against the zoom streams' own
# (deviation, residual) at the event.
import json
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
VARIANT_CONFIGS = ['s93-r2', 's07-r1', 's07-r2', 's21-r1', 's21-r2',
                   's42-r1', 's42-r2']
VARIANT_STREAMS = ['pushdown-050', 'pushdown-150', 'pushdown-300',
                   'pushdown-600', 'pushup-300', 'pushdown-300-early',
                   'pushdown-300-late', 'rewrap', 'tess-stable-dwell',
                   'tess-jitter-dwell', 'tess-scroll']
RESIDUAL_CAPS = [5, 10, 20, 40]
PAIR_FLOORS = [3, 6]


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
                rows1.append([name, cap, '—', '—', '—', '—', '—', '—', census])
            else:
                rows1.append([name, cap, fmt(v['scale'], 3),
                              f"{fmt(v['dx'])} / {fmt(v['dy'])}", v['pairs'],
                              v['rejected'], fmt(v['residualPx']),
                              fmt(v['spanPx']), census])
        print(f'{name} done', file=sys.stderr, flush=True)

    # Table 2 — every non-zoom stream's peak |scale - 1| capture; and the
    # per-capture (deviation, residual) points Table 3 needs.
    points = []  # (label, cap, dev, residual, pairs)
    rows2 = []

    def add(label, base):
        d = report(base)
        s = d['summary']
        for cap, v in d['transformByCapture'].items():
            if v is not None:
                points.append((label, int(cap), abs(v['scale'] - 1),
                               v['residualPx'], v['pairs']))
        if s['peakScaleDeviation'] is None:
            rows2.append([label, '—', '—', '—', '—', '—'])
            return
        rows2.append([label, fmt(s['peakScale'], 3),
                      fmt(s['peakScaleDeviation'], 3),
                      fmt(s['residualAtPeakPx']), s['pairsAtPeak'],
                      s['peakScaleDeviationCapture']])

    for label, base in PUBLISHED.items():
        add(f's93-r1 / {label}' if label in VARIANT_STREAMS else label, base)
        print(f'{label} done', file=sys.stderr, flush=True)
    for cfg in VARIANT_CONFIGS:
        for name in VARIANT_STREAMS:
            add(f'{cfg} / {name}', f'{REFLOW}/variants/{cfg}/{name}')
        print(f'{cfg} done', file=sys.stderr, flush=True)

    # Table 3: for each residual cap R and pair floor P, the largest
    # control |scale - 1| over every CAPTURE whose residual is under R and
    # whose fit used at least P pairs (not only the peak capture) — the
    # floor a zoom reading must clear — and which capture set it.
    rows3 = []
    for R in RESIDUAL_CAPS:
        for P in PAIR_FLOORS:
            under = [p for p in points if p[3] < R and p[4] >= P]
            if not under:
                rows3.append([f'< {R} px', f'>= {P}', '—', '—', 0])
                continue
            worst = max(under, key=lambda p: p[2])
            rows3.append([f'< {R} px', f'>= {P}', fmt(worst[2], 3),
                          f'{worst[0]} (cap {worst[1]}, {worst[4]} pairs)',
                          len(under)])

    print(table('| stream | capture | scale | translation dx / dy | pairs | '
                'rejected | residual (px) | span (px) | merged / admitted |',
                rows1))
    print()
    print(table('| stream | peak scale | peak |scale - 1| | residual at peak (px) '
                '| pairs at peak | capture |', rows2))
    print()
    print(table('| residual under | pairs at least | largest control |scale - 1| '
                '| set by | control captures under both |', rows3))


if __name__ == '__main__':
    main()
