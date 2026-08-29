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
# Usage:  python gen_corpus.py <tesseract.exe> <out-dir>
import io
import json
import random
import subprocess
import sys
import time

from PIL import Image, ImageDraw, ImageEnhance, ImageFont

TESS, OUT = sys.argv[1], sys.argv[2]

W, MARGIN, FONT_PX, LINE_H, PARA_GAP = 1080, 60, 36, 56, 40
VIEW_H = 2200
SCROLL_Y = 800          # the dwell viewport for every frame
REFLOW_AT = 7           # first capture rendered AFTER the reflow event
FRAMES = 12
WRAP_BEFORE, WRAP_AFTER = 26, 22   # chars per line: base font vs swapped-in
# (22 not 24: at 24 no paragraph crossed a line-count boundary, so boxes
# changed width but nothing moved — a font swap that costs a wrapped line
# per long paragraph is the case worth measuring.)
GAP_PX = 300            # push-down offset (the "ad" that finishes loading)
GAP_AFTER_PARA = 9      # the ad slot sits after this paragraph (page y≈1400)

rng = random.Random(93)  # deterministic corpus

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
FONT = ImageFont.truetype(r'C:\Windows\Fonts\msyh.ttc', FONT_PX)


def render(wrap_chars, gap_after_para=None, gap_px=0):
    """Render the page. Returns (image, lines[(y, text)], gap_top or None)."""
    lines, y, gap_top = [], MARGIN, None
    for i, p in enumerate(PARAS):
        for ln in wrap(p, wrap_chars):
            lines.append((y, ln))
            y += LINE_H
        y += PARA_GAP
        if gap_after_para is not None and i == gap_after_para:
            gap_top = y
            y += gap_px
    page_h = y + MARGIN
    page = Image.new('L', (W, page_h), 255)
    draw = ImageDraw.Draw(page)
    for ly, ln in lines:
        draw.text((MARGIN, ly), ln, font=FONT, fill=0)
    if gap_top is not None:
        # A flat mid-grey slab with a border: what a loaded image ad looks
        # like to an OCR engine — no glyphs, so it yields no blocks.
        draw.rectangle((MARGIN, gap_top + 20, W - MARGIN, gap_top + gap_px - 20),
                       fill=200, outline=120, width=3)
    return page, lines, gap_top


def perturb(img, shift_max, jpeg_q, bright_max):
    dx = rng.uniform(-shift_max, shift_max)
    dy = rng.uniform(-shift_max, shift_max)
    img = img.transform(img.size, Image.AFFINE, (1, 0, dx, 0, 1, dy),
                        resample=Image.BILINEAR, fillcolor=255)
    img = ImageEnhance.Brightness(img).enhance(
        1 + rng.uniform(-bright_max, bright_max))
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
                    f'{SCROLL_Y}; shift<=0.3px jpeg=90 bright±0.02',
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
base = render(WRAP_BEFORE)
pushed = render(WRAP_BEFORE, gap_after_para=GAP_AFTER_PARA, gap_px=GAP_PX)
rewrapped = render(WRAP_AFTER)
print(f'page: base {base[0].height}px, pushed {pushed[0].height}px '
      f'(gap top y={pushed[2]}), rewrapped {rewrapped[0].height}px; '
      f'lines {len(base[1])}/{len(pushed[1])}/{len(rewrapped[1])}')
scenario('pushdown', base, pushed,
         f'{GAP_PX}px slab inserted after paragraph {GAP_AFTER_PARA + 1} '
         f'(page y={pushed[2]}): every line below moves +{GAP_PX}px, text unchanged')
scenario('rewrap', base, rewrapped,
         f'wrap {WRAP_BEFORE}->{WRAP_AFTER} chars/line: same paragraphs, '
         f'new line boxes and line texts')
print(f'done in {time.time() - t0:.1f}s')
