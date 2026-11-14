#!/usr/bin/env python3
"""Readability lineup: player facings + key props for each asset set,
at native 1x and nearest-neighbour 2x, over a grass swatch.
Output: docs/images/readability_<set>.png"""
import json
import os

from PIL import Image

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GEN = os.path.join(ROOT, "game", "assets", "generated")
BG = (64, 98, 36, 255)


def lineup(set_id):
    d = os.path.join(GEN, set_id)
    m = json.load(open(os.path.join(d, "manifest.json")))
    a = m["animations"]["player"]
    fw, fh = a["frame_size"]
    walk = Image.open(os.path.join(d, a["anims"]["walk"]["file"])).convert("RGBA")
    frames = [walk.crop((2 * fw, k * fh, 3 * fw, (k + 1) * fh)) for k in range(8)]
    props = [Image.open(os.path.join(d, m["sprites"][n]["file"])).convert("RGBA")
             for n in ("barrel", "crate", "fence_x", "signpost", "bush_berry", "rock_medium", "flowers_purple")]
    sh = m["animations"]["sheep"]
    sheep = Image.open(os.path.join(d, sh["anims"]["stand"]["file"])).convert("RGBA").crop(
        (0, 1 * sh["frame_size"][1], sh["frame_size"][0], 2 * sh["frame_size"][1]))
    items = frames + [sheep] + props
    rows = []
    for scale in (1, 2):
        imgs = [i.resize((i.width * scale, i.height * scale), Image.NEAREST) for i in items]
        h = max(i.height for i in imgs)
        w = sum(i.width for i in imgs) - 30 * scale * len(imgs)
        row = Image.new("RGBA", (w + 30 * scale + 20, h + 10), BG)
        x = 10
        for i in imgs:
            row.alpha_composite(i, (x, h + 5 - i.height))
            x += i.width - 30 * scale
        rows.append(row)
    W = max(r.width for r in rows)
    out = Image.new("RGBA", (W, sum(r.height for r in rows)), BG)
    y = 0
    for r in rows:
        out.alpha_composite(r, (0, y))
        y += r.height
    path = os.path.join(ROOT, "docs", "images", f"readability_{set_id}.png")
    out.convert("RGB").save(path)
    print("wrote", path)


if __name__ == "__main__":
    for s in ("t64", "t96"):
        lineup(s)
