# Tesseract capture-corpus generator for the cross-engine validation matrix
# (issue #94).
#
# Renders a synthetic CJK prose page (composed from a small common-hanzi
# vocabulary — no copyrighted text), crops per-frame viewports with
# controlled photometric/geometric perturbation, runs Tesseract 5 (chi_sim,
# tessdata_fast) per frame, and serializes line-level blocks as capture
# schema v1 JSONL (doc/replay/capture_schema.md) for tool/replay ab-report.
#
# Perturbation exists because Tesseract is deterministic on identical
# pixels: real consumer captures pass through screenshot compression and
# subpixel rendering variation, so each frame gets a small shift + JPEG
# roundtrip + brightness scale. The shift is applied to the IMAGE only;
# block rects are lifted back to clean page-absolute coordinates by adding
# the frame's true scrollY, so the residual box jitter is exactly the
# engine-shaped noise under test.
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

W, MARGIN, FONT_PX, LINE_H, PARA_GAP, WRAP = 1080, 60, 36, 56, 40, 26
VIEW_H = 2200

rng = random.Random(94)  # deterministic corpus

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


# ── Render the long page ──
paras = [paragraph() for _ in range(44)]
lines = []  # (y, text)
y = MARGIN
for p in paras:
    for ln in wrap(p, WRAP):
        lines.append((y, ln))
        y += LINE_H
    y += PARA_GAP
PAGE_H = y + MARGIN

font = ImageFont.truetype(r'C:\Windows\Fonts\msyh.ttc', FONT_PX)
page = Image.new('L', (W, PAGE_H), 255)
draw = ImageDraw.Draw(page)
for ly, ln in lines:
    draw.text((MARGIN, ly), ln, font=font, fill=0)


def perturb(img, shift_max, jpeg_q, bright_max):
    dx = rng.uniform(-shift_max, shift_max)
    dy = rng.uniform(-shift_max, shift_max)
    img = img.transform(img.size, Image.AFFINE, (1, 0, dx, 0, 1, dy),
                        resample=Image.BILINEAR, fillcolor=255)
    img = ImageEnhance.Brightness(img).enhance(
        1 + rng.uniform(-bright_max, bright_max))
    buf = io.BytesIO()
    img.convert('RGB').save(buf, 'JPEG', quality=jpeg_q)
    return Image.open(buf).convert('L'), dx, dy


def ocr_lines(img):
    """Tesseract TSV -> ([(l,t,r,b,text,conf01)], raw_line_count).

    raw_line_count is the number of aggregated line boxes BEFORE the
    sub-noise (<2 chars) filter — schema v1's `raw` field wants the
    pre-filter count.
    """
    buf = io.BytesIO()
    img.save(buf, 'PNG')
    # No --tessdata-dir override: the `tsv` output config ships in the
    # install's tessdata/configs and an override dir hides it (frames then
    # read as 0 blocks). chi_sim.traineddata is installed alongside it.
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


def scenario(name, frames, shift_max, jpeg_q, bright_max):
    """frames: list of scrollY. Writes <name>.jsonl in schema v1."""
    path = f'{OUT}/{name}.jsonl'
    # Arbitrary fixed epoch: the stream is synthetic and deterministic,
    # so ts is a sequencing field, not a capture date (schema only needs
    # monotonic timestamps).
    ts = 1756000000000
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(json.dumps({
            't': 'meta', 'v': 1, 'ts': ts,
            'note': f'synthetic tesseract corpus (#94): {name}; '
                    f'shift<={shift_max}px jpeg={jpeg_q} bright±{bright_max}'
        }) + '\n')
        for cap, sy in enumerate(frames, 1):
            crop = page.crop((0, sy, W, min(sy + VIEW_H, PAGE_H)))
            img, _, _ = perturb(crop, shift_max, jpeg_q, bright_max)
            found, raw_count = ocr_lines(img)
            blocks = []
            for (l, t, r, b, text, tconf) in found:
                blocks.append({
                    'rect': [float(l), float(t + sy),
                             float(r), float(b + sy)],
                    'otext': text,
                    'pconf': 0.5,
                    'tconf': round(tconf, 3),
                    'sc': [float(sy), 0.0, -1],
                })
            f.write(json.dumps({
                't': 'obs', 'ts': ts + cap * 700, 'cap': cap,
                'raw': raw_count, 'blocks': blocks,
            }, ensure_ascii=False) + '\n')
            print(f'{name} cap {cap}: {len(blocks)} blocks', flush=True)
    return path


t0 = time.time()
scenario('stable-dwell', [800] * 12, 0.3, 90, 0.02)
scenario('ocr-jitter-dwell', [800] * 12, 1.5, 70, 0.06)
scenario('scroll', list(range(0, 5600, 400)), 0.3, 90, 0.02)
print(f'done in {time.time() - t0:.1f}s; page {W}x{PAGE_H}, '
      f'{len(lines)} rendered lines')
