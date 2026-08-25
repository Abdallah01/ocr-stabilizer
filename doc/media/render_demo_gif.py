# Renders the README demo GIF from dump_frames.dart output: raw per-frame
# OCR boxes (left) vs the engine's stabilized boxes (right), with 3-frame
# ghost trails so per-frame scatter is visible. Same drawing rule on both
# panels — the comparison is honest by construction.
#
# Usage: python render_demo_gif.py <dump.json> <out.gif>
import json
import sys

from PIL import Image, ImageDraw, ImageFont

REGION = (40, 830, 1040, 1630)  # page-abs l,t,r,b window to show
SCALE = 0.5
TRAIL = 3
DUR_MS = 450
HDR = 34
RAW = (217, 83, 79)
STAB = (46, 139, 87)


def sc(rect):
    l, t, r, b = rect
    return [
        (l - REGION[0]) * SCALE, (t - REGION[1]) * SCALE,
        (r - REGION[0]) * SCALE, (b - REGION[1]) * SCALE,
    ]


def visible(rect):
    l, t, r, b = rect
    return r > REGION[0] and l < REGION[2] and b > REGION[1] and t < REGION[3]


def panel(frames, idx, key, color):
    w = int((REGION[2] - REGION[0]) * SCALE)
    h = int((REGION[3] - REGION[1]) * SCALE)
    im = Image.new('RGB', (w, h), (255, 255, 255))
    dr = ImageDraw.Draw(im, 'RGBA')
    for back in range(TRAIL, 0, -1):
        j = idx - back
        if j < 0:
            continue
        alpha = 90 - 22 * back  # older = fainter
        for blk in frames[j][key]:
            if visible(blk['rect']):
                dr.rectangle(sc(blk['rect']), outline=color + (alpha,), width=1)
    for blk in frames[idx][key]:
        if visible(blk['rect']):
            dr.rectangle(sc(blk['rect']), outline=color + (255,), width=2,
                         fill=color + (26,))
    return im


def main():
    global REGION, SCALE
    if len(sys.argv) not in (3, 5):
        print('usage: python render_demo_gif.py <dump.json> <out.gif> '
              '[<region l,t,r,b> <scale>]')
        raise SystemExit(64)
    if len(sys.argv) == 5:
        parts = sys.argv[3].split(',')
        if len(parts) != 4:
            print('region must be 4 comma-separated numbers: l,t,r,b')
            raise SystemExit(64)
        try:
            REGION = tuple(float(v) for v in parts)
            SCALE = float(sys.argv[4])
        except ValueError as e:
            print(f'bad region/scale value: {e}')
            raise SystemExit(64)
        if REGION[2] <= REGION[0] or REGION[3] <= REGION[1] or SCALE <= 0:
            print('region must have r>l and b>t; scale must be > 0')
            raise SystemExit(64)
    with open(sys.argv[1], encoding='utf-8') as f:
        dump = json.load(f)
    frames = dump['frames']
    try:
        font = ImageFont.truetype('arial.ttf', 15)
    except OSError:
        font = ImageFont.load_default()
    out = []
    for i in range(len(frames)):
        left = panel(frames, i, 'raw', RAW)
        # Prefer the engine's persistent tracked state for the stabilized
        # panel (falls back for dumps predating the 'tracked' field).
        skey = 'tracked' if 'tracked' in frames[i] else 'stable'
        right = panel(frames, i, skey, STAB)
        w = left.width + right.width + 30
        canvas = Image.new('RGB', (w, HDR + left.height + 10), (250, 250, 250))
        dr = ImageDraw.Draw(canvas)
        dr.text((10, 9), 'raw OCR boxes (every frame)', fill=RAW, font=font)
        dr.text((left.width + 40, 9), 'stabilized (ocr_stabilizer)',
                fill=STAB, font=font)
        dr.text((w - 130, 9), f'frame {i + 1}/{len(frames)}',
                fill=(120, 120, 120), font=font)
        canvas.paste(left, (10, HDR))
        canvas.paste(right, (left.width + 20, HDR))
        out.append(canvas)
    out[0].save(sys.argv[2], save_all=True, append_images=out[1:],
                duration=DUR_MS, loop=0, optimize=False, disposal=1)
    print(f'{len(out)} frames -> {sys.argv[2]}')


main()
