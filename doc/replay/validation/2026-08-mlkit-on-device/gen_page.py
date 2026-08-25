# Synthetic CJK page for the ML Kit on-device capture (ocr-stabilizer #108).
# Same common-hanzi synthesis as the Tesseract corpus generator (no
# copyrighted text); deterministic (seed 95). Emits page.html.
import random
import sys

rng = random.Random(95)
NOUNS = '山水风云天地花树鸟石桥船灯窗门书剑马城河月星火'
VERBS = ['看见', '走过', '想起', '听到', '带着', '穿过', '望向', '记得']
TAILS = ['的时候', '之后', '而已', '罢了', '的样子', '的地方']
CONN = ['然后', '于是', '但是', '因为', '所以', '后来']


def sentence():
    n1, n2 = rng.choice(NOUNS), rng.choice(NOUNS)
    return (rng.choice(CONN) + '他' + rng.choice(VERBS) + '了那座' + n1
            + '边的' + n2 + rng.choice(TAILS))


def paragraph():
    return '，'.join(sentence() for _ in range(rng.randint(2, 4))) + '。'


paras = ''.join(f'<p>{paragraph()}</p>\n' for _ in range(40))
html = f"""<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>synthetic corpus page</title>
<style>
 body {{ font-family: sans-serif; font-size: 20px; line-height: 1.7;
        margin: 16px; color: #111; background: #fff; }}
 p {{ margin: 0 0 18px 0; }}
</style></head><body>
{paras}</body></html>
"""
with open(sys.argv[1] if len(sys.argv) > 1 else 'page.html', 'w',
          encoding='utf-8', newline='\n') as f:
    f.write(html)
print('page.html written,', len(paras), 'chars of paragraphs')
