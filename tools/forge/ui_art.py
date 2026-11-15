#!/usr/bin/env python3
"""Procedural UI art: weathered leather panels, parchment tooltips, timber title
bars, inventory slot states and pixel cursors.  Output: game/assets/ui/*.png
All textures are pixel art meant for nearest filtering and 9-slice stretching."""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from noise import fbm2p, value2p  # noqa: E402
from materials import ramp, _c  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "game", "assets", "ui")


def grid(w, h):
    y, x = np.mgrid[0:h, 0:w].astype(float)
    return x, y


def periodic_noise(w, h, freq, seed, octaves=3):
    x, y = grid(w, h)
    return fbm2p(x / w, y / h, freq, 1, octaves, seed=seed)


def to_img(rgb, alpha=None):
    rgb = np.clip(np.round(rgb * 31) / 31, 0, 1)
    a = np.ones(rgb.shape[:2]) if alpha is None else alpha
    out = np.zeros(rgb.shape[:2] + (4,), np.uint8)
    out[..., :3] = (rgb * 255 + 0.5).astype(np.uint8)
    out[..., 3] = (a * 255).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def bevel(rgb, inset, light, dark, width=1):
    h, w = rgb.shape[:2]
    for k in range(width):
        i = inset + k
        rgb[i, i:w - i] = light
        rgb[i:h - i, i] = light
        rgb[h - 1 - i, i:w - i] = dark
        rgb[i:h - i, w - 1 - i] = dark


def border(rgb, inset, col):
    h, w = rgb.shape[:2]
    rgb[inset, inset:w - inset] = col
    rgb[h - 1 - inset, inset:w - inset] = col
    rgb[inset:h - inset, inset] = col
    rgb[inset:h - inset, w - 1 - inset] = col


def rivet(rgb, cx, cy, r=2.6):
    x, y = grid(rgb.shape[1], rgb.shape[0])
    d = np.hypot(x - cx, y - cy)
    m = d <= r
    shade = np.clip(0.5 + ((cx - x) + (cy - y)) / (2 * r) * 0.6, 0, 1)
    rgb[m] = ramp(shade[m], ["#4a3410", "#a0782c", "#f0d27a"])
    rgb[(d > r) & (d <= r + 1)] = rgb[(d > r) & (d <= r + 1)] * 0.5


def corner_plate(rgb, cx, cy, sx, sy, arm=11, w=4):
    """Worn brass L-bracket hugging a panel corner, inside the 9-slice margin.
    (cx, cy) is the corner pixel; sx, sy = +1/-1 point into the panel."""
    h_, w_ = rgb.shape[:2]
    x, y = grid(w_, h_)
    dx, dy = (x - cx) * sx, (y - cy) * sy
    m = (dx >= 0) & (dy >= 0) & (dx < arm) & (dy < arm) & ((dx < w) | (dy < w))
    m &= ~((dx > arm - 3) & (dy > w - 2) & (dx + dy > arm + 1))      # nicked tips
    m &= ~((dy > arm - 3) & (dx > w - 2) & (dx + dy > arm + 1))
    shade = np.clip(0.55 - (dx * sx + dy * sy) / (arm * 2.2) + (value2p(x / 3.0, y / 3.0, 64, 64, seed=41) - 0.5) * 0.5, 0, 1)
    rgb[m] = ramp(shade[m], ["#4e3812", "#8a6822", "#c09a3e", "#ecd27c"])
    # dark seat line where the plate meets the leather
    inner = (dx >= 0) & (dy >= 0) & (dx < arm + 1) & (dy < arm + 1) & ((dx < w + 1) | (dy < w + 1)) & ~m
    rgb[inner] = rgb[inner] * 0.5
    rivet(rgb, cx + sx * 2.5, cy + sy * 2.5, 1.4)


def leather_panel(size=64):
    """Tooled leather: warm hide, pressed inner line, waxed stitching and brass
    corner plates. 9-slice margin 14 px (unchanged)."""
    n = periodic_noise(size, size, 4, 3)
    grain = periodic_noise(size, size, 32, 4, 2)
    pores = periodic_noise(size, size, 64, 5, 1)
    rgb = ramp(np.clip(n * 0.85 + grain * 0.35 + (pores - 0.5) * 0.25 - 0.08, 0, 1),
               ["#2e1b0e", "#432a15", "#59381d", "#6a4526", "#77502e"])
    x, y = grid(size, size)
    crease = (np.abs(np.sin((x * 0.7 + y * 0.3) * 0.5 + n * 6)) < 0.06)
    rgb[crease] *= 0.8
    # darker toward the frame so the middle reads as slightly padded
    edge = np.minimum(np.minimum(x, size - 1 - x), np.minimum(y, size - 1 - y))
    rgb *= (0.78 + 0.22 * np.clip(edge / 9.0, 0, 1))[..., None]
    border(rgb, 0, _c("#120a05"))
    bevel(rgb, 1, _c("#8a6238"), _c("#1e1208"))
    border(rgb, 2, _c("#2a1a0c"))
    # tooled line: a pressed groove with a lit lower edge
    border(rgb, 4, _c("#1c1008"))
    for i in range(5, size - 5):
        rgb[5, i] = rgb[5, i] * 0.6 + _c("#9a7244") * 0.4 if i % 1 == 0 else rgb[5, i]
        rgb[i, 5] = rgb[i, 5] * 0.6 + _c("#9a7244") * 0.4
    # stitching
    for i in range(8, size - 8):
        if (i // 2) % 2 == 0:
            for (a, b) in ((i, 8), (i, size - 9), (8, i), (size - 9, i)):
                rgb[b, a] = _c("#d2b077")
                if b + 1 < size and a + 1 < size:
                    rgb[b + 1, a] = rgb[b + 1, a] * 0.6
    for cx, cy, sx, sy in ((1, 1, 1, 1), (size - 2, 1, -1, 1), (1, size - 2, 1, -1), (size - 2, size - 2, -1, -1)):
        corner_plate(rgb, cx, cy, sx, sy)
    return to_img(rgb)


def parchment(size=48):
    n = periodic_noise(size, size, 3, 9)
    fine = periodic_noise(size, size, 24, 10, 2)
    rgb = ramp(np.clip(n * 0.8 + fine * 0.3, 0, 1), ["#b89c6a", "#cdb68a", "#dccaa2", "#e8dab8"])
    x, y = grid(size, size)
    edge = np.minimum(np.minimum(x, size - 1 - x), np.minimum(y, size - 1 - y))
    burn = np.clip(1 - edge / 5.0, 0, 1) * (0.6 + 0.4 * fine)
    rgb = rgb * (1 - burn[..., None] * 0.45) + _c("#5a3a18")[None, None, :] * burn[..., None] * 0.45
    border(rgb, 0, _c("#3a2410"))
    return to_img(rgb)


def timber_bar(w=64, h=20):
    """Carved timber rail: long grain, a chiselled groove with a gilt inlay
    line, brass end caps. 9-slice margin 7 px (unchanged)."""
    x, y = grid(w, h)
    g = value2p(x / w * 2, y / h * 12, 2, 12, seed=5)
    n = periodic_noise(w, h, 6, 6)
    rgb = ramp(np.clip(g * 0.6 + n * 0.5, 0, 1), ["#2a1a0e", "#4a301a", "#684428", "#825a36", "#946a42"])
    rgb *= (1.08 - 0.22 * (y / h))[..., None]             # rounded: lit top, shaded belly
    border(rgb, 0, _c("#120a05"))
    bevel(rgb, 1, _c("#a47a4c"), _c("#1a1006"))
    rgb[3, 8:w - 8] = rgb[3, 8:w - 8] * 0.55               # chiselled groove
    rgb[4, 8:w - 8] = _c("#c9a24e")                        # gilt inlay
    rgb[h - 4, 8:w - 8] = rgb[h - 4, 8:w - 8] * 0.6
    for x0 in (2, w - 7):                                  # brass end caps
        cap = ramp(np.clip(0.75 - y[2:h - 2, x0:x0 + 5] / h * 0.7, 0, 1), ["#4e3812", "#8a6822", "#c09a3e", "#ecd27c"])
        rgb[2:h - 2, x0:x0 + 5] = cap
        rgb[2:h - 2, x0 + (5 if x0 < w / 2 else -1)] *= 0.5
    return to_img(rgb)


def slot(state, size=44):
    n = periodic_noise(size, size, 5, 21)
    cloth = periodic_noise(size, size, 22, 22, 2)
    inner = ramp(np.clip(n * 0.6 + cloth * 0.4, 0, 1), ["#120c08", "#1c140c", "#261a10"])
    rgb = inner.copy()
    # timber frame
    frame = ramp(np.clip(periodic_noise(size, size, 9, 23) * 1.1, 0, 1), ["#3a2414", "#5a3a20", "#6e4a2a"])
    x, y = grid(size, size)
    fm = (x < 4) | (y < 4) | (x >= size - 4) | (y >= size - 4)
    rgb[fm] = frame[fm]
    border(rgb, 0, _c("#0e0804"))
    bevel(rgb, 1, _c("#8a6440"), _c("#24160a"))
    # recess shadow
    rgb[4:6, 4:size - 4] *= 0.55
    rgb[4:size - 4, 4:6] *= 0.55
    rgb[size - 5, 4:size - 4] = _c("#3a2a1a")
    rgb[4:size - 4, size - 5] = _c("#3a2a1a")
    if state == "hover":
        border(rgb, 4, _c("#b08a48"))
    elif state == "selected":
        border(rgb, 4, _c("#f0c860"))
        border(rgb, 5, _c("#a07a30"))
    elif state == "pressed":
        rgb[6:size - 4, 6:size - 4] *= 0.75
        border(rgb, 4, _c("#6a5028"))
    elif state == "disabled":
        hatch = ((x + y) % 6 == 0) & ~fm
        rgb[hatch] = _c("#3a2e24")
        rgb *= 0.7
    elif state == "drop_ok":
        border(rgb, 4, _c("#9ad05a"))
        border(rgb, 5, _c("#4a7a2a"))
    elif state == "drop_bad":
        border(rgb, 4, _c("#e0503a"))
        border(rgb, 5, _c("#7a2418"))
    return to_img(rgb)


def close_button(state, size=16):
    rgb = np.tile(_c("#3e3a36"), (size, size, 1)).astype(float)
    n = periodic_noise(size, size, 6, 31)
    rgb = rgb * (0.85 + 0.3 * n[..., None])
    border(rgb, 0, _c("#0e0a08"))
    if state == "pressed":
        bevel(rgb, 1, _c("#1e1a16"), _c("#6a645c"))
    else:
        bevel(rgb, 1, _c("#8a8278"), _c("#1e1a16"))
    col = _c("#e0c890") if state == "hover" else _c("#c0b090")
    off = 1 if state == "pressed" else 0
    for i in range(4, size - 4):
        for j in (i, size - 1 - i):
            rgb[i + off, j + off] = col
            rgb[i + off, min(j + 1, size - 2) + off - (1 if j == size - 1 - i else 0)] = col
    return to_img(rgb)


PAL = {"k": "#1a1008", "g": "#c9a35a", "h": "#f4dc9e", "s": "#8a6a34", "r": "#c8281c", "w": "#f0e0c0",
       "d": "#6a6a6a", "l": "#a8a8a8"}

CURSORS = {
    "default": ("""
k...............
kk..............
khk.............
khgk............
khggk...........
khgggk..........
khggggk.........
khgggggk........
khggggggk.......
khgggggggk......
khggggkkkkk.....
khggkgk.........
khgk.kgk........
kgk..kgk........
kk....kgk.......
.......kk.......""", (0, 0)),
    "use": ("""
.....kk.........
....khgk........
....khgk........
....khgk........
....khgkkk......
....khgkhgkkk...
..kkkhgkhgkhgk..
.khgkhggggkhgk..
.khggggggggggk..
..kggggggggggk..
..kgggggggggsk..
...kgggggggssk..
...kggggggssk...
....kgggggssk...
....kssssssk....
....kkkkkkkk....""", (5, 0)),
    "far": ("""
.....kk.........
....kldk........
....kldk........
....kldk........
....kldkkk......
....kldkldkkk...
..kkkldkldkldk..
.kldkldddkldk...
.kldddddddddk...
..kdddddddddk...
..kddddddddk....
...kdddddddk....
...kddddddk.....
....kdddddk.....
....kkkkkkk.....
................""", (5, 0)),
    "grab": ("""
................
................
................
....kk.kk.kk....
...khgkhgkhgk...
..kkhggggggggk..
.khgkggggggggk..
.khgggggggggsk..
..kggggggggssk..
..kgggggggsssk..
...kgggggssssk..
...kggggsssk....
....kssssssk....
....kkkkkkk.....
................
................""", (8, 8)),
}


def ascii_cursor(art, scale=2):
    rows = [r for r in art.strip("\n").split("\n")]
    h, w = len(rows), max(len(r) for r in rows)
    out = np.zeros((h, w, 4), np.uint8)
    for j, r in enumerate(rows):
        for i, ch in enumerate(r):
            if ch in PAL:
                c = (_c(PAL[ch]) * 255).astype(np.uint8)
                out[j, i, :3] = c
                out[j, i, 3] = 255
    return Image.fromarray(out, "RGBA").resize((w * scale, h * scale), Image.NEAREST)


def denied_cursor(scale=2):
    n = 16
    out = np.zeros((n, n, 4), np.uint8)
    x, y = grid(n, n)
    d = np.hypot(x - 7.5, y - 7.5)
    ring = (d >= 4.6) & (d <= 6.6)
    slash = (np.abs((x - 7.5) - (y - 7.5)) <= 1.0) & (d <= 6.0)
    outline = ((d > 6.6) & (d <= 7.6)) | ((d >= 3.6) & (d < 4.6) & ~slash)
    out[outline] = (26, 16, 8, 255)
    out[ring | slash] = (200, 40, 28, 255)
    return Image.fromarray(out, "RGBA").resize((n * scale, n * scale), Image.NEAREST)


def main():
    os.makedirs(OUT, exist_ok=True)
    leather_panel().save(os.path.join(OUT, "panel_leather.png"))
    parchment().save(os.path.join(OUT, "panel_parchment.png"))
    timber_bar().save(os.path.join(OUT, "titlebar.png"))
    for st in ("normal", "hover", "selected", "pressed", "disabled", "drop_ok", "drop_bad"):
        slot(st).save(os.path.join(OUT, f"slot_{st}.png"))
    for st in ("normal", "hover", "pressed"):
        close_button(st).save(os.path.join(OUT, f"close_{st}.png"))
    for name, (art, hot) in CURSORS.items():
        ascii_cursor(art).save(os.path.join(OUT, f"cursor_{name}.png"))
    denied_cursor().save(os.path.join(OUT, "cursor_denied.png"))
    print("wrote UI art to", OUT)


if __name__ == "__main__":
    main()
