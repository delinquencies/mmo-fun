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


def _blades(u, v, seed, f_long=3, f_short=26):
    # streaks aligned with screen-vertical (world (1,1)) so grass reads as upright blades
    P = PERIOD
    A = (u + v)
    B = (u - v)
    return value2p(A * f_long, B * f_short, P * f_long, P * f_short * 2, seed=seed)


def grass_rgb(u, v):
    P = PERIOD
    m1 = fbm2p(u, v, 1, P, 3, seed=1)
    m2 = fbm2p(u, v, 4, P, 2, seed=2)
    bl = _blades(u, v, 3)
    bl2 = _blades(u, v, 4, 5, 40)
    t = 0.12 + (m1 - 0.5) * 0.9 + (m2 - 0.5) * 0.45 + (bl - 0.5) * 0.55 + (bl2 - 0.5) * 0.4
    c = ramp(np.clip(t + 0.25, 0, 1), ["#1f3910", "#2f5216", "#40691d", "#557f26", "#6e9530", "#8eaa3c"])
    # dark gaps between clumps
    gap = (bl2 < 0.22)
    c[gap] *= 0.7
    # occasional bare earth
    earth = np.clip((0.3 - fbm2p(u, v, 2, P, 2, seed=8)) * 6, 0, 1)
    ec = ramp(fbm2p(u, v, 8, P, 2, seed=9), ["#4a3a22", "#6b5434"])
    c = c * (1 - earth[..., None] * 0.7) + ec * earth[..., None] * 0.7
    return c


def dirt_rgb(u, v):
    P = PERIOD
    m = fbm2p(u, v, 3, P, 3, seed=11)
    f1, f2, cid = cells2p(u, v, 7, P, seed=12)
    c = ramp(np.clip(0.2 + (m - 0.5) * 1.1 + value2p(u * 32, v * 32, P * 32, P * 32, seed=13) * 0.35, 0, 1),
             ["#4c3622", "#654a2e", "#7d5e3b", "#94744b", "#a8875a"])
    pebble = (f1 < 0.2) & (cid > 0.78)
    pc = ramp(cid, ["#5e5242", "#7a6c58", "#8e806a"])
    c = np.where(pebble[..., None], pc, c)
    rim = (f1 >= 0.2) & (f1 < 0.27) & (cid > 0.78)
    c[rim] *= 0.62
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
        rgb = dirt_rgb(u, v)
        rim = (f > 0.5) & (f < 0.56)
        rgb[rim] *= 0.72
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
