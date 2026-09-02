# Dynamic-reflow capture-corpus generator (issue #93).
#
# The rotation reflow captures in the scale sweep transform the whole page
# at once. This corpus synthesizes the OTHER reflow family — the layout
# shifting while the viewer does nothing:
#
#   pushdown  an image/ad finishes loading mid-page: every line below one
#             point moves down by a fixed offset; text identity unchanged.
#   rewrap    a web font swaps in: the same paragraphs re-wrap at a
#             different width, so line boxes AND line texts change while
#             the paragraph text does not.
#
# Same pipeline as the Tesseract matrix entry (../2026-08-tesseract-matrix/
# gen_corpus.py): render a synthetic CJK prose page (small common-hanzi
# vocabulary, no copyrighted text), crop the viewport per frame with mild
# photometric/geometric perturbation, run Tesseract 5 (chi_sim) per frame,
# serialize line-level blocks as capture schema v1 JSONL. The reflow is
# applied to the RENDERED PAGE from a given frame on, so the OCR noise on
# both sides of the event is real engine noise, not a synthetic shift of
# boxes.
#
# Usage:  python gen_corpus.py <tesseract.exe> <out-dir> [options]
#         python gen_corpus.py --help
#
# --gap-px, --gap-after-para, --reflow-at and --seed default to the values
# that produced the committed pushdown.jsonl / rewrap.jsonl — running with
# no options regenerates them identically (verified by diff at commit
# time; this script does not do that check itself). --gap-px accepts a
# NEGATIVE value: content moves UP instead of down (an ad slot collapsing
# once its content finishes loading, rather than a slab being inserted).
# --perturb-seed (#136) seeds the per-frame capture noise SEPARATELY from
# the corpus text: the same page under fresh noise, one REPETITION of a
# configuration. Absent, the noise draws from the corpus RNG exactly as
# before, so the committed streams still regenerate byte for byte (the
# files are written with LF line endings; git checks them out with CRLF
# on Windows, so compare after normalising, not with a raw byte diff).
# --zoom K (#135) switches the run to the ZOOM scenarios instead of
# pushdown / rewrap: the same page re-rendered at scale K about the page
# origin from --reflow-at on — `zoom-KKK` keeps the line texts (a pure
# zoom: every line's box scales, no line re-wraps) and `zoom-KKK-rewrap`
# re-wraps them at K x the characters per line (a font-size change on a
# fixed-width column). Both use a 20-character column so the zoomed
# lines still fit the 1080 px viewport; KKK = 100 x K, zero-padded.
import argparse
import io
import json
import random
import subprocess
import time

from PIL import Image, ImageDraw, ImageEnhance, ImageFont


def parse_args():
    p = argparse.ArgumentParser(
        description='Dynamic-reflow capture-corpus generator (issue #93).')
    p.add_argument('tesseract_exe')
    p.add_argument('out_dir')
    p.add_argument('--gap-px', type=int, default=300,
                    help='push-down offset in px. Positive = content moves '
                         'DOWN (an ad/image finishing load, drawn as a grey '
                         'slab). Negative = content moves UP (an ad slot '
                         'collapsing; no slab is drawn — there is nothing '
                         'left occupying the space). Default: 300.')
    p.add_argument('--gap-after-para', type=int, default=9,
                    help='0-based paragraph index the gap slot sits after. '
                         'Default: 9 (the tenth paragraph; with the '
                         'default seed its top is page y=1692).')
    p.add_argument('--reflow-at', type=int, default=7,
                    help='first capture (1-based) rendered AFTER the '
                         'reflow event. Default: 7.')
    p.add_argument('--seed', type=int, default=93,
                    help='RNG seed for corpus text and perturbation. '
                         'Default: 93.')
    p.add_argument('--zoom', type=float, default=None,
                    help='scale factor for the ZOOM scenarios (#135); '
                         'writes zoom-KKK.jsonl and zoom-KKK-rewrap.jsonl '
                         'instead of pushdown / rewrap. Default: none.')
    p.add_argument('--perturb-seed', type=int, default=None,
                    help='separate RNG seed for the per-frame capture '
                         'noise (shift / JPEG / brightness). Default: '
                         'none — the noise draws from the --seed RNG, '
                         'which is what produced the committed streams.')
    return p.parse_args()


args = parse_args()
TESS, OUT = args.tesseract_exe, args.out_dir

W, MARGIN, FONT_PX, LINE_H, PARA_GAP = 1080, 60, 36, 56, 40
VIEW_H = 2200
SCROLL_Y = 800          # the dwell viewport for every frame
REFLOW_AT = args.reflow_at   # first capture rendered AFTER the reflow event
FRAMES = 12
WRAP_BEFORE, WRAP_AFTER = 26, 22   # chars per line: base font vs swapped-in
# (22 not 24: at 24 no paragraph crossed a line-count boundary, so boxes
# changed width but nothing moved — a font swap that costs a wrapped line
# per long paragraph is the case worth measuring.)
GAP_PX = args.gap_px         # push-down offset (the "ad" that finishes
                              # loading) — negative moves content UP instead
GAP_AFTER_PARA = args.gap_after_para   # the ad slot sits after this
                                        # paragraph; with the default seed
                                        # and offset its top is page y=1692
                                        # — the exact value goes into each
                                        # stream's meta note

rng = random.Random(args.seed)  # deterministic corpus

# ── Synthetic prose: common-hanzi vocabulary composed into sentences ──
NOUNS = '山水风云天地花树鸟石桥船灯窗门书剑马城河月星火'
VERBS = ['看见', '走过', '想起', '听到', '带着', '穿过', '望向', '记得']
TAILS = ['的时候', '之后', '而已', '罢了', '的样子', '的地方']
CONN = ['然后', '于是', '但是', '因为', '所以', '后来']


def sentence():
    n1, n2 = rng.choice(NOUNS), rng.choice(NOUNS)
    return (rng.choice(CONN) + '他' + rng.choice(VERBS) + '了那座' + n1
            + '边的' + n2 + rng.choice(TAILS))


def paragraph():
    n = rng.randint(2, 4)
    return '，'.join(sentence() for _ in range(n)) + '。'


def wrap(text, width):
    return [text[i:i + width] for i in range(0, len(text), width)]


PARAS = [paragraph() for _ in range(44)]
# The perturbation RNG: the corpus RNG itself by default (its state after
# the 44 paragraphs is exactly where the committed streams' noise began),
# or an independent stream under --perturb-seed (#136).
prng = rng if args.perturb_seed is None else random.Random(args.perturb_seed)
# Seed provenance is appended to each stream's meta note ONLY for a
# non-default configuration: the committed default streams predate the
# field and must keep regenerating byte for byte. The stamp names exactly
# the flags that regenerate the stream: `seed S` alone means the noise
# continued the page RNG (no --perturb-seed was passed).
PROVENANCE = ('' if args.seed == 93 and args.perturb_seed is None else
              f'; seed {args.seed}'
              + ('' if args.perturb_seed is None
                 else f' perturb-seed {args.perturb_seed}'))
FONT = ImageFont.truetype(r'C:\Windows\Fonts\msyh.ttc', FONT_PX)


def render(wrap_chars, gap_after_para=None, gap_px=0, scale=1.0):
    """Render the page. Returns (image, lines[(y, text)], gap_top or None).

    scale (#135): the whole page geometry — font, line height, margins,
    paragraph gap — times `scale`, about the page origin; the image stays
    W wide (the viewport), so a zoomed line wider than W is clipped. 1.0
    is the committed geometry, computed in integers exactly as before.
    """
    if scale == 1.0:
        font, margin, line_h, para_gap = FONT, MARGIN, LINE_H, PARA_GAP
    else:
        font = ImageFont.truetype(r'C:\Windows\Fonts\msyh.ttc',
                                  round(FONT_PX * scale))
        margin, line_h, para_gap = (round(MARGIN * scale),
                                    round(LINE_H * scale),
                                    round(PARA_GAP * scale))
    lines, y, gap_top = [], margin, None
    for i, p in enumerate(PARAS):
        for ln in wrap(p, wrap_chars):
            lines.append((y, ln))
            y += line_h
        y += para_gap
        if gap_after_para is not None and i == gap_after_para:
            gap_top = y
            y += gap_px
    page_h = y + margin
    page = Image.new('L', (W, page_h), 255)
    draw = ImageDraw.Draw(page)
    for ly, ln in lines:
        draw.text((margin, ly), ln, font=font, fill=0)
    if gap_top is not None and gap_px > 0:
        # A flat mid-grey slab with a border: what a loaded image ad looks
        # like to an OCR engine — no glyphs, so it yields no blocks. Only
        # drawn when content is moving DOWN (something new occupies the
        # slot). A negative gap_px models an ad slot COLLAPSING — content
        # moves up into space that is now simply gone, so there is nothing
        # to draw.
        draw.rectangle((MARGIN, gap_top + 20, W - MARGIN, gap_top + gap_px - 20),
                       fill=200, outline=120, width=3)
    return page, lines, gap_top


def perturb(img, shift_max, jpeg_q, bright_max):
    dx = prng.uniform(-shift_max, shift_max)
    dy = prng.uniform(-shift_max, shift_max)
    img = img.transform(img.size, Image.AFFINE, (1, 0, dx, 0, 1, dy),
                        resample=Image.BILINEAR, fillcolor=255)
    img = ImageEnhance.Brightness(img).enhance(
        1 + prng.uniform(-bright_max, bright_max))
    buf = io.BytesIO()
    img.convert('RGB').save(buf, 'JPEG', quality=jpeg_q)
    return Image.open(buf).convert('L')


def ocr_lines(img):
    """Tesseract TSV -> ([(l,t,r,b,text,conf01)], raw_line_count)."""
    buf = io.BytesIO()
    img.save(buf, 'PNG')
    r = subprocess.run(
        [TESS, 'stdin', 'stdout', '-l', 'chi_sim', '--psm', '6', 'tsv'],
        input=buf.getvalue(), capture_output=True, check=True)
    rows = r.stdout.decode('utf-8', 'replace').splitlines()[1:]
    lines = {}
    for row in rows:
        f = row.split('\t')
        if len(f) < 12 or f[0] != '5':  # word level only
            continue
        text = f[11].strip()
        conf = float(f[10])
        if not text or conf < 0:
            continue
        key = (f[1], f[2], f[3], f[4])  # page,block,par,line
        left, top, w, h = int(f[6]), int(f[7]), int(f[8]), int(f[9])
        e = lines.setdefault(key, [10**9, 10**9, 0, 0, [], []])
        e[0], e[1] = min(e[0], left), min(e[1], top)
        e[2], e[3] = max(e[2], left + w), max(e[3], top + h)
        e[4].append(text)
        e[5].append(conf)
    out = []
    for (l, t, rr, b, words, confs) in lines.values():
        text = ''.join(words)
        if len(text) < 2:
            continue  # sub-noise fragments
        conf01 = max(0.30, min(0.99, (sum(confs) / len(confs)) / 100.0))
        out.append((l, t, rr, b, text, conf01))
    return out, len(lines)


def scenario(name, before, after, note):
    """before/after: (page_image, lines, gap_top). Frames 1..REFLOW_AT-1 use
    `before`, frames REFLOW_AT..FRAMES use `after`. Dwell at SCROLL_Y."""
    path = f'{OUT}/{name}.jsonl'
    ts = 1756100000000  # sequencing only — the stream is synthetic
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(json.dumps({
            't': 'meta', 'v': 1, 'ts': ts, 'vp': [W, VIEW_H],
            'note': f'synthetic dynamic-reflow corpus (#93): {name}; {note}; '
                    f'reflow rendered from cap {REFLOW_AT}; dwell scrollY '
                    f'{SCROLL_Y}; shift<=0.3px jpeg=90 bright±0.02'
                    + PROVENANCE,
        }) + '\n')
        for cap in range(1, FRAMES + 1):
            page = (before if cap < REFLOW_AT else after)[0]
            crop = page.crop((0, SCROLL_Y, W, min(SCROLL_Y + VIEW_H, page.height)))
            img = perturb(crop, 0.3, 90, 0.02)
            found, raw_count = ocr_lines(img)
            blocks = []
            for (l, t, r, b, text, tconf) in found:
                blocks.append({
                    'rect': [float(l), float(t + SCROLL_Y),
                             float(r), float(b + SCROLL_Y)],
                    'otext': text,
                    'pconf': 0.5,
                    'tconf': round(tconf, 3),
                    'sc': [float(SCROLL_Y), 0.0, -1],
                })
            f.write(json.dumps({
                't': 'obs', 'ts': ts + cap * 700, 'cap': cap,
                'raw': raw_count, 'blocks': blocks,
            }, ensure_ascii=False) + '\n')
            print(f'{name} cap {cap}: {len(blocks)} blocks', flush=True)
    return path


t0 = time.time()
if args.zoom is not None:
    # #135 zoom corpus: a 20-character column (so 1.25x still fits the
    # viewport), re-rendered at `zoom` about the page origin from the
    # reflow capture on. Pure = same texts, scaled boxes; rewrap = the
    # same paragraphs at zoom x the characters per line.
    WRAP_ZOOM = 20
    k = args.zoom
    tag = f'zoom-{round(k * 100):03d}'
    zoom_base = render(WRAP_ZOOM)
    zoomed = render(WRAP_ZOOM, scale=k)
    wrap_after = max(4, round(WRAP_ZOOM / k))
    zoomed_rewrap = render(wrap_after, scale=k)
    print(f'page: base {zoom_base[0].height}px, zoomed {zoomed[0].height}px, '
          f'zoomed+rewrap {zoomed_rewrap[0].height}px; lines '
          f'{len(zoom_base[1])}/{len(zoomed[1])}/{len(zoomed_rewrap[1])}')
    scenario(tag, zoom_base, zoomed,
             f'pure zoom x{k} about the page origin: every box scales, '
             f'line texts unchanged ({WRAP_ZOOM} chars/line)')
    scenario(f'{tag}-rewrap', zoom_base, zoomed_rewrap,
             f'zoom x{k} with rewrap {WRAP_ZOOM}->{wrap_after} chars/line: '
             f'same paragraphs, new line boxes and line texts')
    print(f'done in {time.time() - t0:.1f}s')
    raise SystemExit(0)
base = render(WRAP_BEFORE)
pushed = render(WRAP_BEFORE, gap_after_para=GAP_AFTER_PARA, gap_px=GAP_PX)
rewrapped = render(WRAP_AFTER)
print(f'page: base {base[0].height}px, pushed {pushed[0].height}px '
      f'(gap top y={pushed[2]}), rewrapped {rewrapped[0].height}px; '
      f'lines {len(base[1])}/{len(pushed[1])}/{len(rewrapped[1])}')
if GAP_PX >= 0:
    _pushdown_note = (
        f'{GAP_PX}px slab inserted after paragraph {GAP_AFTER_PARA + 1} '
        f'(page y={pushed[2]}): every line below moves +{GAP_PX}px, text unchanged')
else:
    _pushdown_note = (
        f'{-GAP_PX}px ad slot collapsing after paragraph {GAP_AFTER_PARA + 1} '
        f'(page y={pushed[2]}): every line below moves {GAP_PX}px, text unchanged')
scenario('pushdown', base, pushed, _pushdown_note)
scenario('rewrap', base, rewrapped,
         f'wrap {WRAP_BEFORE}->{WRAP_AFTER} chars/line: same paragraphs, '
         f'new line boxes and line texts')
print(f'done in {time.time() - t0:.1f}s')
