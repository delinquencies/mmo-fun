"""Trees, bushes, rocks, stumps, flowers and grass tufts."""
import numpy as np

from sdf import Scene, rot_axis_mat, rot_z_mat
from materials import Material, ramp, wood_grain, _c
from noise import fbm3, value3, hash01

LEAF_COLS = ["#1c3510", "#2f5118", "#466c20", "#64892a", "#8ba63a", "#a9bd4c"]


def foliage_material(seed, cols=LEAF_COLS, bright=0.0):
    def f(p, n):
        macro = fbm3(p, 2.2, 2, seed)
        leaf = value3(p[:, 0] * 30, p[:, 1] * 30, p[:, 2] * 30, seed + 9)
        leaf2 = value3(p[:, 0] * 64, p[:, 1] * 64, p[:, 2] * 64, seed + 4)
        spot = np.clip((leaf - 0.52) * 5.0, 0, 1)  # crisp individual leaf highlights
        t = 0.24 + (macro - 0.5) * 0.7 + spot * 0.42 + (leaf2 - 0.5) * 0.3 + bright
        t = t + np.clip(n[:, 2], 0, 1) * 0.16
        return ramp(np.clip(t, 0, 1), cols)
    return Material(f, 0.6, 28.0, seed=seed)


BARK = wood_grain(["#2b1d12", "#4a3322", "#6b4d34", "#80664a"], axis=2, seed=3, bump_s=0.3)


def tree(seed=1, height=3.6, spread=1.3, trunk_r=0.15, clusters=46, cols=LEAF_COLS):
    rng = np.random.default_rng(seed)
    s = Scene()
    lean = rng.normal(0, 0.06, 2)
    top = np.array([lean[0], lean[1], height * 0.55])
    s.capsule((0, 0, -0.05), top, trunk_r, BARK, rb=trunk_r * 0.6, displace=(0.012, 9.0, seed))
    for a in rng.uniform(0, 2 * np.pi, 4):
        e = np.array([np.cos(a) * trunk_r * 2.4, np.sin(a) * trunk_r * 2.4, 0.0])
        s.capsule((0, 0, 0.2), e, trunk_r * 0.55, BARK, rb=0.035)
    canopy_c = np.array([lean[0] * 2, lean[1] * 2, height * 0.7])
    pts = []
    for i in range(clusters):
        ang = rng.uniform(0, 2 * np.pi)
        r = spread * np.sqrt(rng.uniform(0.02, 1.0))
        dome = 1 - (r / spread) ** 2
        z = canopy_c[2] + (height - canopy_c[2]) * dome * rng.uniform(0.35, 1.0) - rng.uniform(0.0, 0.5) * (r / spread)
        c = np.array([canopy_c[0] + np.cos(ang) * r, canopy_c[1] + np.sin(ang) * r, z])
        rad = rng.uniform(0.22, 0.36) * (1.15 - 0.3 * r / spread) * (spread / 1.25) ** 0.6
        pts.append((c, rad))
    for k in range(5):  # dense core so the crown never shows holes
        a = k * 2 * np.pi / 5 + rng.uniform(0, 0.5)
        c = canopy_c + np.array([np.cos(a) * spread * 0.35, np.sin(a) * spread * 0.35, (height - canopy_c[2]) * 0.55])
        pts.append((c, 0.42 * (spread / 1.3) ** 0.6))
    for c, rad in pts[: max(4, clusters // 4)]:
        b = top + (c - top) * 0.75
        s.capsule(top, b, trunk_r * 0.45, BARK, rb=0.03)
    mats = [foliage_material(seed * 100 + k, cols, bright=(k - 1) * 0.05) for k in range(3)]
    for i, (c, rad) in enumerate(pts):
        s.sphere(c, rad, mats[i % 3], displace=(0.085, 11.0, seed * 31 + i))
    return s


def bush(seed=2, r=0.42, dots=None, dot_r=0.035, cols=LEAF_COLS):
    rng = np.random.default_rng(seed)
    s = Scene()
    mats = [foliage_material(seed + k, cols, 0.05) for k in range(2)]
    for i in range(7):
        a = rng.uniform(0, 2 * np.pi)
        d = rng.uniform(0, r * 0.55)
        c = np.array([np.cos(a) * d, np.sin(a) * d, r * rng.uniform(0.55, 0.95)])
        rr = r * rng.uniform(0.45, 0.65)
        s.sphere(c, rr, mats[i % 2], displace=(0.05, 11.0, seed + i))
    if dots:
        col = _c(dots)
        mat = Material(lambda p, n: np.tile(col, (p.shape[0], 1)) *
                       (0.8 + 0.4 * hash01(np.floor(p[:, 0] * 40), np.floor(p[:, 1] * 40), np.floor(p[:, 2] * 40)))[:, None])
        for i in range(30):
            a = rng.uniform(0, 2 * np.pi)
            el = rng.uniform(-0.1, 1.2)
            c = np.array([np.cos(a) * np.cos(el) * r * 0.98, np.sin(a) * np.cos(el) * r * 0.98,
                          r * 0.72 + np.sin(el) * r * 0.75])
            s.sphere(c, dot_r, mat)
    return s


def rock_material(seed):
    def f(p, n):
        t = fbm3(p, 4.0, 3, seed) * 1.3 - 0.15 + (value3(p[:, 0] * 30, p[:, 1] * 30, p[:, 2] * 30, seed) - 0.5) * 0.35
        c = ramp(np.clip(t, 0, 1), ["#3e3c39", "#5b5853", "#77736b", "#938d82"])
        moss = np.clip((fbm3(p, 6, 2, seed + 4) - 0.55) * 4, 0, 1) * np.clip(n[:, 2], 0, 1)
        return c * (1 - moss[:, None]) + _c("#5c6e2a")[None, :] * moss[:, None]
    return Material(f, 0.3, 16.0, seed=seed)


def rock_pile(seed=3, n=4, size=0.45):
    rng = np.random.default_rng(seed)
    s = Scene()
    for i in range(n):
        a = rng.uniform(0, 2 * np.pi)
        d = rng.uniform(size * 0.4, size * 0.9) if i else 0
        r = np.array([rng.uniform(0.6, 1.0), rng.uniform(0.6, 1.0), rng.uniform(0.5, 0.85)]) * size * (1.0 if i == 0 else rng.uniform(0.45, 0.75))
        c = np.array([np.cos(a) * d, np.sin(a) * d, r[2] * 0.45])
        R = rot_axis_mat(rng.normal(0, 1, 3), rng.uniform(0.2, 0.6)) @ rot_z_mat(rng.uniform(0, np.pi))
        s.box((0, 0, 0), r * 0.85, rock_material(seed + i), round_=min(r) * 0.35,
              displace=(0.03, 6.0, seed + i * 3), T=c, R=R)
    return s


def stump(seed=4):
    s = Scene()

    def f(p, n):
        rings = ramp(0.5 + 0.5 * np.sin(np.hypot(p[:, 0], p[:, 1]) * 90.0) * 0.6, ["#8a6a45", "#b8935f"])
        side = ramp(fbm3(p, 8, 2, 3), ["#3a281a", "#5a3f29", "#6f5236"])
        return np.where((n[:, 2] > 0.7)[:, None], rings, side)
    s.cyl((0, 0), 0.24, 0.0, 0.32, Material(f, 0.15, 20.0), round_=0.02, displace=(0.012, 14.0, seed))
    rng = np.random.default_rng(seed)
    for a in rng.uniform(0, 2 * np.pi, 3):
        s.capsule((0, 0, 0.1), (np.cos(a) * 0.38, np.sin(a) * 0.38, 0.0), 0.08, BARK, rb=0.03)
    return s


def flower_clump(seed=5, petal="#f2e04a", n=11, r=0.24):
    rng = np.random.default_rng(seed)
    s = Scene()
    leaves = foliage_material(seed, ["#203d12", "#36591c", "#527a27", "#7a9a35"], 0.05)
    s.ellipsoid((0, 0, 0.06), (r * 0.95, r * 0.95, 0.13), leaves, displace=(0.035, 16.0, seed))
    for k in range(4):
        a = k * np.pi / 2 + 0.4
        s.ellipsoid((np.cos(a) * r * 0.45, np.sin(a) * r * 0.45, 0.12), (0.09, 0.09, 0.08), leaves, displace=(0.03, 20.0, seed + k))
    pc = _c(petal)
    pm = Material(lambda p, n: np.tile(pc, (p.shape[0], 1)) * (0.9 + 0.2 * value3(p[:, 0] * 80, p[:, 1] * 80, p[:, 2] * 80, seed)[:, None]))
    for i in range(n):
        a = rng.uniform(0, 2 * np.pi)
        d = rng.uniform(0, r * 0.8)
        c = np.array([np.cos(a) * d, np.sin(a) * d, rng.uniform(0.17, 0.26)])
        s.capsule((c[0], c[1], 0.02), c, 0.012, leaves)
        s.ellipsoid(c, (0.05, 0.05, 0.025), pm)
    return s


def grass_tuft(seed=6, h=0.22):
    rng = np.random.default_rng(seed)
    s = Scene()
    m = foliage_material(seed, ["#2a4a14", "#3f6a1e", "#5f8a2a", "#86a83a"], 0.1)
    for i in range(9):
        a = rng.uniform(0, 2 * np.pi)
        b = np.array([np.cos(a) * 0.05, np.sin(a) * 0.05, 0.0])
        t = b * 2.5 + np.array([0, 0, h * rng.uniform(0.6, 1.1)])
        s.capsule(b, t, 0.022, m, rb=0.004)
    return s
