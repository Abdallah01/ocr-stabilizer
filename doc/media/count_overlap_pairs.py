# Counts overlapping pairs of TRACKED boxes in a dump_frames.dart output —
# the number the ML Kit validation entry and the CHANGELOG cite for the
# demo GIF ("overlapping tracked-box pairs across the 14 frames").
#
# Rule: for each of the first N frames of the dump, every unordered pair
# of boxes in that frame's `tracked` list whose rectangles intersect with
# positive area counts once. No crop, no ghost trails, no text check.
# Each pair is also classified by shape and by which member is fresh this
# frame (present in the frame's `stable` list) so the two families the
# entry describes can be re-derived.
#
# Usage: python doc/media/count_overlap_pairs.py dump.json [frames=14]
import io
import json
import sys


def inter(a, b):
    w = min(a[2], b[2]) - max(a[0], b[0])
    h = min(a[3], b[3]) - max(a[1], b[1])
    return w * h if w > 0 and h > 0 else 0.0


def area(r):
    return (r[2] - r[0]) * (r[3] - r[1])


def key(b):
    return (tuple(round(x, 2) for x in b["rect"]), b["text"])


def main():
    dump = json.load(io.open(sys.argv[1], encoding="utf-8"))
    nframes = int(sys.argv[2]) if len(sys.argv) > 2 else 14
    frames = dump["frames"][:nframes]
    total = 0
    per_frame = []
    kinds = {}
    for f in frames:
        stable = {key(b) for b in f["stable"]}
        t = f["tracked"]
        n = 0
        for i in range(len(t)):
            for j in range(i + 1, len(t)):
                a, b = t[i], t[j]
                x = inter(a["rect"], b["rect"])
                if x <= 0:
                    continue
                n += 1
                sa, sb = area(a["rect"]), area(b["rect"])
                small, big = (a, b) if sa <= sb else (b, a)
                cover_small = x / min(sa, sb)
                cover_big = x / max(sa, sb)
                if cover_small >= 0.9 and cover_big < 0.5:
                    shape = "small-inside-large"
                elif cover_small >= 0.5 and cover_big >= 0.5:
                    shape = "near-duplicate"
                else:
                    shape = "partial"
                who = ("fresh" if key(small) in stable else "retained") + "-small/" + (
                    "fresh" if key(big) in stable else "retained") + "-big"
                same = "same-text" if a["text"] == b["text"] else "diff-text"
                kinds[f"{shape} | {who} | {same}"] = kinds.get(
                    f"{shape} | {who} | {same}", 0) + 1
        per_frame.append(n)
        total += n
    print(f"source: {dump.get('source')}  viewport: {dump.get('viewport')}  "
          f"retention: {dump.get('retention')}")
    print(f"overlapping tracked-box pairs over the first {len(frames)} frames: {total}")
    print(f"per frame: {per_frame}")
    for k, v in sorted(kinds.items(), key=lambda kv: -kv[1]):
        print(f"  {v:3d}  {k}")


if __name__ == "__main__":
    main()
