"""Deterministic, vectorised value noise (numpy).

All functions take float arrays and return float arrays in [0, 1].
Periodic variants wrap their lattice so textures tile seamlessly.
"""
import numpy as np

_M1 = np.uint32(0x7FEB352D)
_M2 = np.uint32(0x846CA68B)


def _mix(h):
    h = h ^ (h >> np.uint32(16))
    h = h * _M1
    h = h ^ (h >> np.uint32(15))
    h = h * _M2
    h = h ^ (h >> np.uint32(16))
    return h


def hash_u32(*ints, seed=0):
    h = np.uint32((seed * 0x9E3779B1) & 0xFFFFFFFF)
    for i, v in enumerate(ints):
        v = np.asarray(v).astype(np.int64).astype(np.uint32)
        h = _mix(h ^ (v + np.uint32((0x632BE5AB * (i + 1)) & 0xFFFFFFFF)))
    return h


def hash01(*ints, seed=0):
    return hash_u32(*ints, seed=seed).astype(np.float64) / 4294967296.0


def _smooth(t):
    return t * t * (3.0 - 2.0 * t)


def value3(x, y, z, seed=0):
    xi, yi, zi = np.floor(x), np.floor(y), np.floor(z)
    fx, fy, fz = _smooth(x - xi), _smooth(y - yi), _smooth(z - zi)
    xi, yi, zi = xi.astype(np.int64), yi.astype(np.int64), zi.astype(np.int64)

    def h(a, b, c):
        return hash01(xi + a, yi + b, zi + c, seed=seed)

    x00 = h(0, 0, 0) + (h(1, 0, 0) - h(0, 0, 0)) * fx
    x10 = h(0, 1, 0) + (h(1, 1, 0) - h(0, 1, 0)) * fx
    x01 = h(0, 0, 1) + (h(1, 0, 1) - h(0, 0, 1)) * fx
    x11 = h(0, 1, 1) + (h(1, 1, 1) - h(0, 1, 1)) * fx
    y0 = x00 + (x10 - x00) * fy
    y1 = x01 + (x11 - x01) * fy
    return y0 + (y1 - y0) * fz


def fbm3(p, freq=1.0, octaves=3, seed=0, gain=0.5):
    """p: (N,3) array."""
    total = np.zeros(p.shape[0])
    amp, norm, f = 1.0, 0.0, freq
    for o in range(octaves):
        total += amp * value3(p[:, 0] * f, p[:, 1] * f, p[:, 2] * f, seed=seed + o * 17)
        norm += amp
        amp *= gain
        f *= 2.03
    return total / norm


def value2p(x, y, px, py, seed=0):
    """2D value noise whose lattice wraps with integer periods (px, py)."""
    xi, yi = np.floor(x), np.floor(y)
    fx, fy = _smooth(x - xi), _smooth(y - yi)
    xi, yi = xi.astype(np.int64), yi.astype(np.int64)

    def h(a, b):
        return hash01(np.mod(xi + a, px), np.mod(yi + b, py), seed=seed)

    a = h(0, 0) + (h(1, 0) - h(0, 0)) * fx
    b = h(0, 1) + (h(1, 1) - h(0, 1)) * fx
    return a + (b - a) * fy


def fbm2p(x, y, freq, period, octaves=3, seed=0, gain=0.5):
    """Periodic fbm. x, y in world units; `period` in world units (int);
    `freq` must be an integer so the lattice wraps."""
    total = np.zeros_like(x, dtype=np.float64)
    amp, norm, f = 1.0, 0.0, int(freq)
    for o in range(octaves):
        p = period * f
        total += amp * value2p(x * f, y * f, p, p, seed=seed + o * 31)
        norm += amp
        amp *= gain
        f *= 2
    return total / norm


def cells2p(x, y, freq, period, seed=0):
    """Periodic jittered-grid Voronoi. Returns (F1, F2, cell_id_hash01)."""
    p = int(period * freq)
    gx, gy = x * freq, y * freq
    xi, yi = np.floor(gx).astype(np.int64), np.floor(gy).astype(np.int64)
    f1 = np.full(x.shape, 9.0)
    f2 = np.full(x.shape, 9.0)
    cid = np.zeros(x.shape)
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            cx, cy = np.mod(xi + dx, p), np.mod(yi + dy, p)
            jx = hash01(cx, cy, seed=seed)
            jy = hash01(cx, cy, seed=seed + 1)
            px_ = xi + dx + 0.15 + 0.7 * jx
            py_ = yi + dy + 0.15 + 0.7 * jy
            d = np.hypot(gx - px_, gy - py_)
            closer = d < f1
            f2 = np.where(closer, f1, np.minimum(f2, d))
            cid = np.where(closer, hash01(cx, cy, seed=seed + 2), cid)
            f1 = np.where(closer, d, f1)
    return f1, f2, cid


def cells3(p, freq, seed=0):
    """Jittered-grid 3D Voronoi. p: (N,3). Returns (F1, F2, cell_hash01, dz)
    where dz is the height of the sample above its cell centre (in cells)."""
    g = p * freq
    gi = np.floor(g).astype(np.int64)
    n = p.shape[0]
    f1 = np.full(n, 9.0)
    f2 = np.full(n, 9.0)
    cid = np.zeros(n)
    dz = np.zeros(n)
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for dzc in (-1, 0, 1):
                cx, cy, cz = gi[:, 0] + dx, gi[:, 1] + dy, gi[:, 2] + dzc
                px_ = cx + 0.15 + 0.7 * hash01(cx, cy, cz, seed=seed)
                py_ = cy + 0.15 + 0.7 * hash01(cx, cy, cz, seed=seed + 1)
                pz_ = cz + 0.15 + 0.7 * hash01(cx, cy, cz, seed=seed + 2)
                d = np.sqrt((g[:, 0] - px_) ** 2 + (g[:, 1] - py_) ** 2 + (g[:, 2] - pz_) ** 2)
                closer = d < f1
                f2 = np.where(closer, f1, np.minimum(f2, d))
                cid = np.where(closer, hash01(cx, cy, cz, seed=seed + 3), cid)
                dz = np.where(closer, g[:, 2] - pz_, dz)
                f1 = np.where(closer, d, f1)
    return f1, f2, cid, dz
