# Seed-variance report (#136): derives the tables of the "Variance across
# seeds and repetitions" section of ../EXPERIMENT.md by replaying every
# configuration's committed streams through tool/replay — the same replays
# test/replay/experiment_doc_variance_tables_test.dart pins, so the tables
# this prints and the ones the test accepts are one and the same.
#
# Usage (from the package root; needs the Dart SDK on PATH):
#   python doc/replay/validation/2026-08-dynamic-reflow/variants/variance_report.py > tables.md
#
# Per configuration and stream: one `ab-report --coherent-floor=390
# --coherent-adopt` replay (the damp / coherent / floor / adopt arms). Per
# control and for pushdown-600: a bisection over integer floors in
# [FLOOR_LO, FLOOR_HI] for the largest floor at which the floor arm still
# fires — the stream's largest floor-qualified displacement at 1 px
# resolution (a mover qualifies at floor F iff its displacement >= F, so
# "fires at F and not at F+1" brackets the displacement). The bisection
# ASSUMES monotonicity — a stream that fires at F fires at every floor
# below F. The engine does not guarantee it: lowering the floor only adds
# qualified movers, but the floor path direction-checks the whole
# qualified set before clustering, so an added mover travelling against
# the slab vetoes the plan. What the report states, and the pin test
# checks, is the bracket (fires at F and at FLOOR_LO, not at F+1) — and
# for "< FLOOR_LO", silence at five floors across the range; on this
# corpus those probes found no reversal.
import json
import statistics
import subprocess
import sys
from decimal import ROUND_HALF_UP, Decimal
from pathlib import Path

ROOT = Path(__file__).resolve().parents[5]
V = 'doc/replay/validation'
REFLOW = f'{V}/2026-08-dynamic-reflow'
MATRIX = f'{V}/2026-08-tesseract-matrix'

CONTROLS = ['rewrap', 'tess-stable-dwell', 'tess-jitter-dwell', 'tess-scroll']
STEPS = ['pushdown-050', 'pushdown-150', 'pushdown-300', 'pushdown-600',
         'pushup-300', 'pushdown-300-early', 'pushdown-300-late']
MOVE_CAP = {'pushdown-300-early': 3, 'pushdown-300-late': 10}
SLAB = 'pushdown-600'
SHIPPED_FLOOR = 390
FLOOR_LO, FLOOR_HI = 200, 700

# (label, seed, perturb-seed); None = no --perturb-seed, the noise continued
# the page RNG. s93-r1 is the published corpus itself.
CONFIGS = [
    ('s93-r1', 93, None), ('s93-r2', 93, 1093),
    ('s07-r1', 7, None), ('s07-r2', 7, 1007),
    ('s21-r1', 21, None), ('s21-r2', 21, 1021),
    ('s42-r1', 42, None), ('s42-r2', 42, 1042),
]

# The published corpus, by the names the tables use.
BASELINE = {
    'rewrap': f'{REFLOW}/rewrap',
    'pushdown-300': f'{REFLOW}/pushdown',
    'tess-stable-dwell': f'{MATRIX}/stable-dwell',
    'tess-jitter-dwell': f'{MATRIX}/ocr-jitter-dwell',
    'tess-scroll': f'{MATRIX}/scroll',
}


def base_of(label, name):
    if label == 's93-r1':
        return BASELINE.get(name, f'{REFLOW}/variants/{name}')
    return f'{REFLOW}/variants/{label}/{name}'


_cache = {}


def replay(base, *flags):
    key = (base, flags)
    if key not in _cache:
        cmd = ['dart', 'tool/replay/replay.dart', 'ab-report', f'{base}.jsonl',
               *flags]
        r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True,
                           encoding='utf-8', shell=sys.platform == 'win32')
        if r.returncode != 0:
            raise SystemExit(f'replay failed ({r.returncode}): {" ".join(cmd)}\n'
                             f'{r.stderr}')
        _cache[key] = json.loads(r.stdout)
    return _cache[key]


def full(base):
    return replay(base, f'--coherent-floor={SHIPPED_FLOOR}', '--coherent-adopt')


def events(arm):
    return sum(arm['stepEventsByCapture'].values())


def lag(arm, cap):
    return arm['meanTopLagByCapture'].get(str(cap))


def fmt(v, decimals=1):
    """Render like Dart's toStringAsFixed: the exact binary value, ties up."""
    if v is None:
        return 'n/a'
    q = Decimal(1).scaleb(-decimals)
    return str(Decimal(v).quantize(q, rounding=ROUND_HALF_UP))


def fmt_stat(v):
    return str(int(v)) if float(v).is_integer() else fmt(v)


def triple(arm, move):
    return ' / '.join(fmt(lag(arm, move + o)) for o in (0, 3, 5))


def arm_cell(arm, move):
    return f'{triple(arm, move)} ({events(arm)})'


def passes(arm, damp, move):
    """The #116 step rule: lag at most half of damp's at the move, +3 and
    +5 — over the captures the stream still has."""
    for o in (0, 3, 5):
        d, v = lag(damp, move + o), lag(arm, move + o)
        if d is None:
            continue
        if v is None or v > d / 2:
            return False
    return True


def fires(base, floor):
    return events(replay(base, f'--coherent-floor={floor}')
                  ['agreementCoherentFloor']) > 0


def largest_firing_floor(base):
    """The largest integer floor in [FLOOR_LO, FLOOR_HI] at which the floor
    arm fires; None below FLOOR_LO; FLOOR_HI when it still fires there."""
    if not fires(base, FLOOR_LO):
        return None
    if fires(base, FLOOR_HI):
        return FLOOR_HI
    lo, hi = FLOOR_LO, FLOOR_HI  # fires at lo, not at hi
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if fires(base, mid):
            lo = mid
        else:
            hi = mid
    return lo


def floor_cell(f):
    if f is None:
        return f'< {FLOOR_LO}'
    if f == FLOOR_HI:
        return f'>= {FLOOR_HI}'
    return str(f)


def table(header, rows):
    out = [header, '|' + '|'.join(['---'] * (header.count('|') - 1)) + '|']
    out += ['| ' + ' | '.join(str(c) for c in r) + ' |' for r in rows]
    return '\n'.join(out)


def main():
    # `--only s93-r1,s07-r1` restricts the run (a partial table while a
    # suite is still generating, or the published seed alone as a check
    # that the script reproduces the #119 numbers).
    only = None
    if len(sys.argv) > 2 and sys.argv[1] == '--only':
        only = set(sys.argv[2].split(','))
    configs = [c for c in CONFIGS if only is None or c[0] in only]
    ceilings, bounds, control_rows, step_rows, window_rows = {}, {}, [], [], []
    passing = {arm: {} for arm in ('coherent', 'adopt', 'floor')}
    false_events = {}
    for label, _, _ in configs:
        per_control = []
        false_events[label] = 0
        for name in CONTROLS:
            base = base_of(label, name)
            rep = full(base)
            f = largest_firing_floor(base)
            per_control.append(f)
            floor_events = events(rep['agreementCoherentFloor'])
            false_events[label] += floor_events
            control_rows.append([label, name, events(rep['agreementCoherent']),
                                 floor_events, events(rep['agreementCoherentAdopt']),
                                 floor_cell(f)])
            print(f'{label} {name}: floor bound {f}', file=sys.stderr, flush=True)
        ints = [f for f in per_control if f is not None]
        ceilings[label] = max(ints) if ints else None
        for arm_name in passing:
            passing[arm_name][label] = 0
        for name in STEPS:
            base = base_of(label, name)
            rep = full(base)
            move = MOVE_CAP.get(name, 7)
            damp = rep['agreementWeighted']
            arms = {'coherent': rep['agreementCoherent'],
                    'adopt': rep['agreementCoherentAdopt'],
                    'floor': rep['agreementCoherentFloor']}
            verdicts = []
            for arm_name, arm in arms.items():
                ok = passes(arm, damp, move)
                passing[arm_name][label] += ok
                verdicts.append('PASS' if ok else 'FAIL')
            step_rows.append([label, name, move, triple(damp, move),
                              arm_cell(arms['coherent'], move),
                              arm_cell(arms['adopt'], move),
                              arm_cell(arms['floor'], move),
                              ' / '.join(verdicts)])
            print(f'{label} {name}: {verdicts}', file=sys.stderr, flush=True)
        slab = base_of(label, SLAB)
        u = largest_firing_floor(slab)
        bounds[label] = u
        L = ceilings[label]
        if u is None or (L is not None and L >= u):
            window = 'empty'
        else:
            window = f'({floor_cell(L)}, {u}]'
        inside = (u is not None and SHIPPED_FLOOR <= u
                  and (L is None or L < SHIPPED_FLOOR))
        rep = full(slab)
        move = MOVE_CAP.get(SLAB, 7)
        window_rows.append([
            label, floor_cell(L), 'none' if u is None else floor_cell(u), window,
            'yes' if inside else 'no',
            f"{fmt(lag(rep['agreementCoherent'], move))} → "
            f"{fmt(lag(rep['agreementCoherentFloor'], move))}"])

    def stat_row(name, values):
        vals = [v for v in values if v is not None]
        if not vals:
            return [name, '—', '—', '—', 0]
        return [name, fmt_stat(min(vals)), fmt_stat(statistics.median(vals)),
                fmt_stat(max(vals)), len(vals)]

    labels = [c[0] for c in configs]
    widths = [bounds[l] - ceilings[l]
              if bounds[l] is not None and ceilings[l] is not None
              and ceilings[l] < bounds[l] else None for l in labels]
    summary = [
        stat_row('control ceiling (px)', [ceilings[l] for l in labels]),
        stat_row('slab bound (px)', [bounds[l] for l in labels]),
        stat_row('window width (px)', widths),
        stat_row('steps passing: coherent (of 7)', [passing['coherent'][l] for l in labels]),
        stat_row('steps passing: adopt (of 7)', [passing['adopt'][l] for l in labels]),
        stat_row('steps passing: floor 390 (of 7)', [passing['floor'][l] for l in labels]),
        stat_row('control false events at floor 390 (4 controls)', [false_events[l] for l in labels]),
    ]

    print(table('| config | control | coherent stepEvents | floor 390 stepEvents '
                '| adopt stepEvents | largest firing floor (px) |', control_rows))
    print()
    print(table('| config | stream | move cap | damp lag move/+3/+5 | coherent lag '
                'move/+3/+5 (stepEvents) | adopt lag move/+3/+5 (stepEvents) | '
                'floor 390 lag move/+3/+5 (stepEvents) | step rule: coherent / '
                'adopt / floor |', step_rows))
    print()
    print(table('| config | control ceiling (px) | slab bound (px) | floor window '
                '| 390 inside | pushdown-600 lag at move: coherent → floor 390 |',
                window_rows))
    print()
    print(table('| quantity | min | median | max | n |', summary))


if __name__ == '__main__':
    main()
