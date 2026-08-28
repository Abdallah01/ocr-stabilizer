# PaddleOCR capture-corpus generator for the cross-engine validation matrix
# (issue #94/#108 follow-on). Renders the IDENTICAL synthetic CJK page the
# Tesseract entry uses (same seed 94, same perturbation schedule), swaps the
# engine for PaddleOCR PP-OCRv6 (lang='ch', detection at line granularity),
# and serializes capture schema v1 JSONL.
#
# Usage: paddle-venv/Scripts/python gen_corpus.py <out-dir>
import io
import json
import random
import sys
import time

import numpy as np
from PIL import Image, ImageDraw, ImageEnhance, ImageFont

OUT = sys.argv[1]

W, MARGIN, FONT_PX, LINE_H, PARA_GAP, WRAP = 1080, 60, 36, 56, 40, 26
VIEW_H = 2200

rng = random.Random(94)  # SAME corpus as the Tesseract entry

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


paras = [paragraph() for _ in range(44)]
lines = []
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

import os  # noqa: E402
# paddlepaddle 3.x on Windows CPU hits an unimplemented PIR/oneDNN op
# (ConvertPirAttribute2RuntimeAttribute) unless oneDNN is disabled before
# the predictor is built.
os.environ.setdefault('FLAGS_use_mkldnn', '0')
from paddleocr import PaddleOCR  # noqa: E402  (import after render: slow)
ocr = PaddleOCR(lang='ch', use_doc_orientation_classify=False,
                use_doc_unwarping=False, use_textline_orientation=False,
                enable_mkldnn=False)


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
    """PaddleOCR -> ([(l,t,r,b,text,conf01)], raw_line_count)."""
    arr = np.asarray(img.convert('RGB'))
    res = ocr.predict(arr)
    out, raw = [], 0
    for page_res in res:
        texts = page_res['rec_texts']
        scores = page_res['rec_scores']
        polys = page_res['rec_polys']
        raw += len(texts)
        for text, score, poly in zip(texts, scores, polys):
            text = text.strip()
            if len(text) < 2:
                continue  # sub-noise fragments (same rule as Tesseract)
            xs = [float(p[0]) for p in poly]
            ys = [float(p[1]) for p in poly]
            conf01 = max(0.30, min(0.99, float(score)))
            out.append((min(xs), min(ys), max(xs), max(ys), text, conf01))
    return out, raw


def scenario(name, frames, shift_max, jpeg_q, bright_max):
    path = f'{OUT}/{name}.jsonl'
    ts = 1756000000000  # arbitrary deterministic epoch (sequencing only)
    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(json.dumps({
            't': 'meta', 'v': 1, 'ts': ts, 'vp': [W, VIEW_H],
            'note': f'synthetic paddleocr corpus (#94): {name}; '
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
