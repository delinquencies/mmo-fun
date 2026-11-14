"""Small homestead props: fences, barrel, crate, signpost, lamp post, log pile, trough."""
import numpy as np

from sdf import Scene, rot_axis_mat, rot_z_mat
from materials import Material, ramp, wood_grain, _c
from noise import fbm3, value3, hash01

FENCE_WOOD = wood_grain(["#3a2717", "#59402a", "#76583b", "#8a6c4c"], axis=2, seed=12, bump_s=0.2)
RAIL_WOOD_X = wood_grain(["#3a2717", "#59402a", "#76583b", "#8a6c4c"], axis=0, seed=13, bump_s=0.2)
RAIL_WOOD_Y = wood_grain(["#3a2717", "#59402a", "#76583b", "#8a6c4c"], axis=1, seed=14, bump_s=0.2)
IRON = Material(lambda p, n: ramp(fbm3(p, 12, 2, 3), ["#1e1e22", "#33343a", "#4a4b52"]), 0.2, 30.0)


def fence(axis="x", seed=1, post_at_end=True):
    """One tile-long fence segment from local (0,0) to (1,0) [axis x] or (0,1) [axis y],
    anchored at the segment midpoint."""
    rng = np.random.default_rng(seed)
    s = Scene()
    d = np.array([1.0, 0, 0]) if axis == "x" else np.array([0, 1.0, 0])
    a, b = -0.5 * d, 0.5 * d
    ends = [a, b] if post_at_end else [a]
    for e in ends:
        lean = rng.normal(0, 0.02, 2)
        s.box((0, 0, 0), (0.055, 0.055, 0.5), FENCE_WOOD, round_=0.012,
              T=e + np.array([0, 0, 0.5]), R=rot_axis_mat((lean[0], lean[1], 0.001), 0.04))
        s.box(e + np.array([0, 0, 1.0]), (0.065, 0.065, 0.025), FENCE_WOOD, round_=0.01)
    rm = RAIL_WOOD_X if axis == "x" else RAIL_WOOD_Y
    for z in (0.42, 0.8):
        sag = rng.uniform(-0.02, 0.02)
        s.box(np.array([0, 0, z + sag]), np.abs(d) * 0.5 + np.array([0.035, 0.035, 0.045]) * (1 - np.abs(d)),
              rm, round_=0.012)
    return s


def barrel():
    s = Scene()

    def staves(p, n):
        ang = np.arctan2(p[:, 1], p[:, 0])
        st = np.floor(ang / (2 * np.pi) * 16)
        f = ang / (2 * np.pi) * 16 - st
        w = wood_grain(["#4b301a", "#6b4626", "#84593a"], axis=2, seed=4).albedo(p, n)
        w = w * (0.85 + 0.3 * hash01(st, seed=3))[:, None]
        w = np.where((np.minimum(f, 1 - f) < 0.07)[:, None], w * 0.5, w)
        top = n[:, 2] > 0.8
        w[top] = ramp(np.abs(np.sin(p[top, 0] * 40)), ["#5a3b22", "#7a5634"])
        return w
    sm = Material(staves, 0.1, 30)
    for i in range(6):
        z0, z1 = i * 0.13, (i + 1) * 0.13
        zm = (z0 + z1) / 2 - 0.39
        r = 0.27 + 0.05 * (1 - (zm / 0.39) ** 2)
        s.cyl((0, 0), r, z0, z1 + 0.001, sm)
    for z in (0.12, 0.66):
        zm = z - 0.39
        r = 0.27 + 0.05 * (1 - (zm / 0.39) ** 2)
        s.cyl((0, 0), r + 0.012, z - 0.025, z + 0.025, IRON)
    return s


def crate():
    s = Scene()

    def planks(p, n):
        w = wood_grain(["#6d4a28", "#8c6438", "#a67c4a"], axis=0 if abs(np.mean(n[:, 1])) > 0.5 else 1, seed=6).albedo(p, n)
        gap = np.abs(np.mod(p[:, 2], 0.18) - 0.09) > 0.082
        return np.where(gap[:, None], w * 0.5, w)
    s.box((0, 0, 0.3), (0.3, 0.3, 0.3), Material(planks, 0.1, 30), round_=0.01)
    fm = wood_grain(["#4a301a", "#644226", "#7c5634"], axis=2, seed=7)
    for x in (-0.29, 0.29):
        for y in (-0.29, 0.29):
            s.box((x, y, 0.3), (0.035, 0.035, 0.31), fm, round_=0.008)
    for side in (-1, 1):
        s.box((0, 0, 0), (0.29, 0.02, 0.035), fm, T=(0, side * 0.305, 0.3), R=rot_axis_mat((0, 1, 0), np.pi / 4))
        s.box((0, 0, 0), (0.02, 0.29, 0.035), fm, T=(side * 0.305, 0, 0.3), R=rot_axis_mat((1, 0, 0), np.pi / 4))
    return s


def signpost():
    s = Scene()
    s.box((0, 0, 0.8), (0.06, 0.06, 0.8), FENCE_WOOD, round_=0.015)
    board = wood_grain(["#5a3d22", "#7a5634", "#93704a"], axis=0, seed=15)
    for z, yaw in ((1.38, -0.2), (1.12, np.pi / 2 + 0.15)):
        R = rot_z_mat(yaw)
        s.box((0, 0, 0), (0.32, 0.03, 0.08), board, round_=0.01, T=R @ np.array([0.25, 0.08, 0]) + np.array([0, 0, z]), R=R)
    return s


def lamppost():
    s = Scene()
    s.cyl((0, 0), 0.12, 0.0, 0.12, IRON, round_=0.02)
    s.cyl((0, 0), 0.04, 0.1, 1.85, IRON)
    s.cyl((0, 0), 0.14, 1.85, 1.9, IRON)
    for a in np.linspace(0, 2 * np.pi, 6, endpoint=False):
        s.capsule((np.cos(a) * 0.12, np.sin(a) * 0.12, 1.88), (np.cos(a) * 0.14, np.sin(a) * 0.14, 2.12), 0.015, IRON)
    coal = Material(_c("#3a1a0c"), emissive=lambda p, n: np.tile(_c("#ff7a1a"), (p.shape[0], 1)) * (0.3 + 0.7 * value3(p[:, 0] * 40, p[:, 1] * 40, p[:, 2] * 40, 2))[:, None])
    s.sphere((0, 0, 1.92), 0.1, coal)
    return s, {"flame": (0.0, 0.0, 2.02)}


def log_pile():
    s = Scene()
    end = Material(lambda p, n: np.where((np.abs(n[:, 0]) > 0.7)[:, None],
                                         ramp(0.5 + 0.5 * np.sin(np.hypot(p[:, 1] - np.round(p[:, 1] * 5.6) / 5.6, p[:, 2] - np.round(p[:, 2] * 5.6) / 5.6) * 120), ["#9a7448", "#c49a62"]),
                                         ramp(fbm3(p, 10, 2, 5), ["#2e2014", "#4a3422", "#5e4530"])), 0.15, 30)
    rows = [(0.09, [-0.27, -0.09, 0.09, 0.27]), (0.245, [-0.18, 0.0, 0.18]), (0.4, [-0.09, 0.09])]
    for z, ys in rows:
        for y in ys:
            s.cyl_axis((-0.42, y, z), (0.42, y + 0.01, z), 0.085, end)
    return s


def trough():
    s = Scene()
    w = wood_grain(["#4a301a", "#644226", "#7c5634"], axis=0, seed=17)
    s.box((0, 0, 0.12), (0.5, 0.2, 0.04), w, round_=0.01)
    for y in (-0.18, 0.18):
        s.box((0, y, 0.24), (0.5, 0.025, 0.14), w, round_=0.01)
    for x in (-0.48, 0.48):
        s.box((x, 0, 0.24), (0.025, 0.2, 0.14), w, round_=0.01)
    water = Material(_c("#2f5f86"), emissive=lambda p, n: np.tile(_c("#0a2030"), (p.shape[0], 1)) * value3(p[:, 0] * 30, p[:, 1] * 30, p[:, 2], 1)[:, None])
    s.box((0, 0, 0.33), (0.44, 0.14, 0.02), water)
    for x in (-0.45, 0.45):
        s.box((x, 0, 0.08), (0.04, 0.18, 0.08), w)
    return s
