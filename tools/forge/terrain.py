"""Ground tiles.

Every texture is a function of *world* ground coordinates that repeats every
PERIOD tiles, so the tile at (i mod P, j mod P) always meets its neighbours
seamlessly.  Overlay layers (dirt, water) use corner/vertex terrain: each tile
has 4 corner flags -> 15 masks.  Mask bits: top(i,j)=1, right(i+1,j)=2,
bottom(i+1,j+1)=4, left(i,j+1)=8.
"""
import numpy as np

from noise import fbm2p, value2p, cells2p, hash01
from materials import ramp, _c

PERIOD = 4
SS = 3


def _tile_coords(tile_w, a, b):
    """Supersampled world (u,v) for every subpixel of a tile image, plus inside mask."""
    W, H = tile_w, tile_w // 2
    jj, ii = np.mgrid[0:H * SS, 0:W * SS]
    sx = (ii + 0.5) / SS - W / 2.0
    sy = (jj + 0.5) / SS
    u = (sx * 2.0 / W + sy * 4.0 / W) * 0.5
    v = (sy * 4.0 / W - sx * 2.0 / W) * 0.5
    # pixel ownership uses the native pixel centre so neighbouring tiles never overlap
    pcx = (np.floor(ii / SS) + 0.5) - W / 2.0
    pcy = (np.floor(jj / SS) + 0.5)
    pu = (pcx * 2.0 / W + pcy * 4.0 / W) * 0.5
    pv = (pcy * 4.0 / W - pcx * 2.0 / W) * 0.5
    inside = (pu >= 0) & (pu < 1) & (pv >= 0) & (pv < 1)
    return u + a, v + b, inside


def grass_rgb(u, v):
    """Mottled meadow: broad light/dark drifts, clumps a hand-span across with
    dark roots between them, short blade flecks, scattered dry and bare
    patches and the odd tiny wildflower. No long vertical streaks."""
    P = PERIOD
    drift = fbm2p(u, v, 1, P, 3, seed=1)                  # broad colour drifts
    patch = fbm2p(u, v, 3, P, 2, seed=2)
    f1, f2, cid = cells2p(u, v, 9, P, seed=5)              # clumps
    g1, g2, gid = cells2p(u, v, 22, P, seed=6)             # blade tufts
    A, B = u + v, u - v
    fleck = value2p(A * 14, B * 34, P * 14, P * 34, seed=3)   # short upright blade flecks
    t = 0.46 + (drift - 0.5) * 0.26 + (patch - 0.5) * 0.42 + (cid - 0.5) * 0.3 \
        + (gid - 0.5) * 0.2 + (fleck - 0.5) * 0.34
    t = t - np.clip(0.14 - (f2 - f1), 0, 1) * 1.1           # dark roots between clumps
    t = t + np.clip(0.3 - g1, 0, 1) * 0.5                   # lit tuft tips
    c = ramp(np.clip(t, 0, 1), ["#243a12", "#33501a", "#446620", "#567a26", "#6a8c2e", "#809c38", "#9aae46"])
    # dry, yellowed drifts
    dry = np.clip((fbm2p(u, v, 2, P, 2, seed=7) - 0.6) * 5, 0, 1)[..., None]
    c = c * (1 - dry * 0.45) + c * np.array([1.22, 1.08, 0.62]) * dry * 0.45
    # bare earth showing through
    earth = np.clip((0.27 - fbm2p(u, v, 2, P, 3, seed=8)) * 7, 0, 1)[..., None]
    ec = ramp(fbm2p(u, v, 9, P, 2, seed=9), ["#4a3a22", "#6b5434", "#7e6540"])
    c = c * (1 - earth * 0.8) + ec * earth * 0.8
    # tiny wildflowers: a few cells of the finest grid get a petal dot
    w1, w2, wid = cells2p(u, v, 30, P, seed=10)
    dot = (w1 < 0.2) & (wid > 0.972) & (earth[..., 0] < 0.2)
    pet = np.where((wid > 0.99)[..., None], _c("#e8dcec"), np.where((wid > 0.981)[..., None], _c("#e6cf52"), _c("#c9a0d8")))
    c = np.where(dot[..., None], pet, c)
    return c


def dirt_rgb(u, v):
    """Trodden earth path: warm tan with fine grit, wheel-worn lighter middle
    tones, small stones with a dark rim."""
    P = PERIOD
    m = fbm2p(u, v, 2, P, 3, seed=11)
    grit = value2p(u * 40, v * 40, P * 40, P * 40, seed=13)
    grit2 = value2p(u * 90, v * 90, P * 90, P * 90, seed=14)
    f1, f2, cid = cells2p(u, v, 11, P, seed=12)
    c = ramp(np.clip(0.36 + (m - 0.5) * 0.7 + (grit - 0.5) * 0.3 + (grit2 - 0.5) * 0.22, 0, 1),
             ["#5a4128", "#735534", "#8a6a42", "#a08052", "#b39464", "#c2a676"])
    pebble = (f1 < 0.17) & (cid > 0.7)
    pc = ramp(cid, ["#6a6052", "#8a8070", "#a69c8a"])
    c = np.where(pebble[..., None], pc * (0.85 + 0.3 * (1 - f1[..., None] / 0.17) * 0.5), c)
    rim = (f1 >= 0.17) & (f1 < 0.25) & (cid > 0.7)
    c[rim] *= 0.66
    return c


def water_rgb(u, v):
    P = PERIOD
    m = fbm2p(u, v, 2, P, 3, seed=21)
    rip = value2p((u + v) * 12, (u - v) * 2, P * 12, P * 2 * 2, seed=22)
    t = 0.45 + (m - 0.5) * 0.8 + (rip - 0.5) * 0.6
    c = ramp(np.clip(t, 0, 1), ["#0f2c4a", "#16406a", "#1e5486", "#2c6aa0", "#4a8cbc"])
    glint = rip > 0.82
    c[glint] = c[glint] * 0.5 + _c("#9cc8e6") * 0.5
    return c


def _edge_field(u, v, mask, a, b, amp, seed):
    lu, lv = u - a, v - b
    ct, cr, cb, cl = [(mask >> k) & 1 for k in range(4)]
    # bilinear over corners: (0,0)=top, (1,0)=right, (1,1)=bottom, (0,1)=left
    f = (ct * (1 - lu) * (1 - lv) + cr * lu * (1 - lv) + cb * lu * lv + cl * (1 - lu) * lv)
    n = fbm2p(u, v, 3, PERIOD, 3, seed=seed) - 0.5
    return f + n * amp


def _down(arr):
    H, W = arr.shape[0] // SS, arr.shape[1] // SS
    return arr.reshape(H, SS, W, SS, *arr.shape[2:]).mean(axis=(1, 3))


def _finish(rgb, alpha):
    rgb = np.clip(np.round(rgb * 31) / 31, 0, 1)
    out = np.zeros(rgb.shape[:2] + (4,), np.uint8)
    out[..., :3] = (rgb * 255 + 0.5).astype(np.uint8)
    out[..., 3] = np.where(alpha, 255, 0)
    out[~alpha, :3] = 0
    return out


def base_tile(tile_w, a, b, fn):
    u, v, inside = _tile_coords(tile_w, a, b)
    rgb = _down(fn(u, v))
    alpha = _down(inside.astype(float)) > 0.5
    return _finish(rgb, alpha)


def overlay_tile(tile_w, a, b, mask, kind):
    u, v, inside = _tile_coords(tile_w, a, b)
    if kind == "dirt":
        f = _edge_field(u, v, mask, a, b, 0.42, 31)
        # ragged, tufted edge: grass blades bite into the path
        f = f + (value2p((u + v) * 16, (u - v) * 30, PERIOD * 16, PERIOD * 30, seed=33) - 0.5) * 0.09
        rgb = dirt_rgb(u, v)
        rim = (f > 0.5) & (f < 0.58)
        rgb[rim] *= 0.7
        cov = (f > 0.5).astype(float)
    else:
        f = _edge_field(u, v, mask, a, b, 0.36, 41)
        rgb = water_rgb(u, v)
        bank = (f > 0.48) & (f < 0.6)
        mud = ramp(fbm2p(u, v, 9, PERIOD, 2, seed=44)[bank], ["#2e2416", "#4a3a24", "#5e4c30"])
        rgb[bank] = mud
        foam = (f >= 0.6) & (f < 0.635)
        rgb[foam] = rgb[foam] * 0.5 + _c("#a8c8d8") * 0.5
        cov = (f > 0.48).astype(float)
    cov = cov * inside
    c = _down(cov)
    rgb = _down(rgb * cov[..., None]) / np.maximum(c[..., None], 1e-6)
    return _finish(rgb, c > 0.5)


def build_atlases(tile_w):
    """Returns dict name -> RGBA atlas.
    grass: PxP grid (col=a, row=b).  dirt/water: rows = mask 1..15, cols = a + b*P."""
    P = PERIOD
    W, H = tile_w, tile_w // 2
    out = {}
    g = np.zeros((H * P, W * P, 4), np.uint8)
    for b in range(P):
        for a in range(P):
            g[b * H:(b + 1) * H, a * W:(a + 1) * W] = base_tile(tile_w, a, b, grass_rgb)
    out["grass"] = g
    for kind in ("dirt", "water"):
        at = np.zeros((H * 15, W * P * P, 4), np.uint8)
        for m in range(1, 16):
            for b in range(P):
                for a in range(P):
                    col = a + b * P
                    at[(m - 1) * H:m * H, col * W:(col + 1) * W] = overlay_tile(tile_w, a, b, m, kind)
        out[kind] = at
    return out
