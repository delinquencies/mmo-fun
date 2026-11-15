"""Trees, bushes, rocks, stumps, flowers and grass tufts."""
import numpy as np

from sdf import Scene, rot_axis_mat, rot_z_mat
from materials import Material, ramp, wood_grain, _c
from noise import fbm3, value3, hash01, cells3

# olive / moss / yellow-green, per the art bible (not a single saturated lime)
LEAF_COLS = ["#16290d", "#243d13", "#37551a", "#4f7022", "#6f8c2c", "#93a83a", "#b4c052"]
LEAF_COLS_WARM = ["#1a2a0c", "#2c4012", "#45591a", "#637322", "#86902e", "#a9a83c", "#c8c056"]
LEAF_COLS_COOL = ["#12280f", "#1e3d16", "#2e561e", "#447226", "#5f8c30", "#80a63e", "#a2bd52"]


def foliage_material(seed, cols=LEAF_COLS, bright=0.0, centre_z=None, span=1.0, leaf=9.0):
    """Leaf-cluster foliage. Each Voronoi cell is one spray of leaves: lit on
    its upper side, dark where it tucks under its neighbour, with a hard dark
    gap between sprays. `centre_z`/`span` add a crown-wide top-light gradient
    so the canopy reads as a layered mass, not a ball of noise."""
    def f(p, n):
        f1, f2, cid, dz = cells3(p, leaf, seed)
        edge = f2 - f1                                   # 0 at the gap between sprays
        up = np.clip(0.5 + dz * 0.9, 0, 1)                # upper half of each spray is lit
        macro = fbm3(p, 1.6, 2, seed)
        speck = value3(p[:, 0] * 58, p[:, 1] * 58, p[:, 2] * 58, seed + 4)
        t = 0.16 + up * 0.36 + (cid - 0.5) * 0.24 + (macro - 0.5) * 0.3 + (speck - 0.5) * 0.2 + bright
        t += np.clip(n[:, 2], -0.4, 1) * 0.14
        if centre_z is not None:
            t += np.clip((p[:, 2] - centre_z) / span, -1, 1) * 0.2
        t = np.where(edge < 0.12, t - 0.34, t)             # crisp dark seams
        return ramp(np.clip(t, 0, 1), cols)
    return Material(f, 0.5, 26.0, seed=seed)


BARK = wood_grain(["#241710", "#3f2a1b", "#5f4630", "#7d6044", "#96785a"], axis=2, seed=3, bump_s=0.35)


def tree(seed=1, height=3.6, spread=1.3, trunk_r=0.15, clusters=46, cols=LEAF_COLS):
    """Broadleaf tree: a stout trunk that forks into visible limbs, carrying
    separate foliage masses (not one sphere-cloud)."""
    rng = np.random.default_rng(seed)
    s = Scene()
    trunk_r = trunk_r * 1.35
    lean = rng.normal(0, 0.07, 2)
    fork = np.array([lean[0], lean[1], height * 0.42])
    s.capsule((0, 0, -0.05), fork, trunk_r * 1.15, BARK, rb=trunk_r * 0.72, displace=(0.02, 7.0, seed))
    for a in rng.uniform(0, 2 * np.pi, 5):   # root flare
        e = np.array([np.cos(a) * trunk_r * 2.6, np.sin(a) * trunk_r * 2.6, 0.0])
        s.capsule((0, 0, 0.3), e, trunk_r * 0.6, BARK, rb=0.04)
    crown_z = height * 0.68
    masses = max(6, clusters // 6)
    pts = []
    a0 = rng.uniform(0, 2 * np.pi)
    for m in range(masses):
        if m < 2:      # crown
            ang = a0 + m * np.pi + rng.uniform(-0.4, 0.4)
            rr = spread * 0.22 * m
            c = np.array([lean[0] * 2 + np.cos(ang) * rr, lean[1] * 2 + np.sin(ang) * rr, height - spread * 0.5])
            mr = spread * rng.uniform(0.46, 0.54)
        else:          # skirt of boughs, wider than the crown and lower
            ang = a0 + (m - 2) * 2 * np.pi / (masses - 2) + rng.uniform(-0.3, 0.3)
            rr = spread * rng.uniform(0.62, 0.85)
            c = np.array([lean[0] * 2 + np.cos(ang) * rr, lean[1] * 2 + np.sin(ang) * rr,
                          crown_z + rng.uniform(-0.3, 0.12) * spread])
            mr = spread * rng.uniform(0.32, 0.46)
        s.capsule(fork, fork + (c - fork) * 0.85, trunk_r * 0.45, BARK, rb=0.03, displace=(0.01, 9.0, seed + m))
        pts.append((c, np.array([mr, mr, mr * 0.72])))
        for k in range(5):   # sprays that break the outline into leafy lobes
            d = rng.normal(0, 1, 3)
            d[2] = d[2] * 0.45
            d /= np.linalg.norm(d)
            sr = mr * rng.uniform(0.34, 0.52)
            pts.append((c + d * np.array([mr, mr, mr * 0.72]) * 0.95, np.array([sr, sr, sr * 0.75])))
    palettes = [cols, LEAF_COLS_WARM if cols is LEAF_COLS else cols, LEAF_COLS_COOL if cols is LEAF_COLS else cols]
    mats = [foliage_material(seed * 100 + k, palettes[k], bright=(k - 1) * 0.03, centre_z=crown_z, span=height - crown_z + 0.4,
                             leaf=6.5)
            for k in range(3)]
    for i, (c, rad) in enumerate(pts):
        s.ellipsoid(c, rad, mats[(i // 6) % 3], displace=(0.11, 6.5, seed * 31 + i))
    return s


def bush(seed=2, r=0.42, dots=None, dot_r=0.035, cols=LEAF_COLS):
    rng = np.random.default_rng(seed)
    s = Scene()
    mats = [foliage_material(seed + k, cols, 0.06, centre_z=r * 0.7, span=r, leaf=13.0) for k in range(2)]
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
        f1, f2, cid, dz = cells3(p, 5.5, seed)
        t = 0.3 + cid * 0.35 + (fbm3(p, 5.0, 2, seed) - 0.5) * 0.5 \
            + (value3(p[:, 0] * 34, p[:, 1] * 34, p[:, 2] * 34, seed) - 0.5) * 0.22 + np.clip(n[:, 2], 0, 1) * 0.18
        c = ramp(np.clip(t, 0, 1), ["#46464a", "#63646a", "#828389", "#a0a1a6", "#bcbcc0"])
        c = np.where(((f2 - f1) < 0.07)[:, None], c * 0.5, c)          # cracks between facets
        warm = hash01(np.floor(cid * 16), seed=seed) > 0.55
        c = c * np.where(warm[:, None], np.array([1.05, 0.99, 0.91]), np.array([0.96, 0.99, 1.04]))
        moss = np.clip((fbm3(p, 5, 2, seed + 4) - 0.6) * 5, 0, 1) * np.clip(n[:, 2], 0, 1)
        return c * (1 - moss[:, None] * 0.8) + _c("#5f7230")[None, :] * moss[:, None] * 0.8
    return Material(f, 0.35, 14.0, seed=seed)


def rock_pile(seed=3, n=4, size=0.45):
    rng = np.random.default_rng(seed)
    s = Scene()
    for i in range(n):
        a = rng.uniform(0, 2 * np.pi)
        d = rng.uniform(size * 0.4, size * 0.9) if i else 0
        r = np.array([rng.uniform(0.6, 1.0), rng.uniform(0.6, 1.0), rng.uniform(0.5, 0.85)]) * size * (1.0 if i == 0 else rng.uniform(0.45, 0.75))
        c = np.array([np.cos(a) * d, np.sin(a) * d, r[2] * 0.45])
        R = rot_axis_mat(rng.normal(0, 1, 3), rng.uniform(0.2, 0.6)) @ rot_z_mat(rng.uniform(0, np.pi))
        s.box((0, 0, 0), r * 0.85, rock_material(seed + i), round_=min(r) * 0.22,
              displace=(0.035, 5.0, seed + i * 3), T=c, R=R)
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
