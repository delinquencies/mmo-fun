"""Portable items: shared by the in-world ground sprites, inventory icons and
(for weapons) the character's equipped-weapon overlay."""
import numpy as np

from sdf import Scene, rot_axis_mat
from materials import Material, ramp, _c
from noise import fbm3, value3

BLADE = Material(lambda p, n: ramp(fbm3(p, 26, 2, 2) * 0.7 + value3(p[:, 0] * 80, p[:, 1] * 80, p[:, 2] * 80, 1) * 0.3,
                                   ["#6c727a", "#a7afb8", "#d6dde4", "#f2f5f7"]), 0.05, 40.0)
GUARD = Material(lambda p, n: ramp(fbm3(p, 20, 2, 5), ["#24242a", "#3e3f46", "#5d5f68"]), 0.15, 30.0)
GRIP = Material(lambda p, n: ramp(np.abs(np.sin(p[:, 0] * 90 + p[:, 1] * 90 + p[:, 2] * 140)),
                                  ["#2a180c", "#4a2c16", "#6a4224"]), 0.2, 40.0)
WEAPON_MATERIALS = [BLADE, GUARD, GRIP]


def add_sword(s, grip_center, bdir, up=(0, 0, 1)):
    """Iron arming sword. grip_center = where the hand closes; bdir = blade direction."""
    bdir = np.asarray(bdir, float)
    bdir = bdir / np.linalg.norm(bdir)
    g = np.asarray(grip_center, float)
    perp = np.cross(bdir, np.asarray(up, float))
    if np.linalg.norm(perp) < 1e-6:
        perp = np.array([0.0, 1.0, 0.0])
    perp = perp / np.linalg.norm(perp)
    hilt = g + bdir * 0.07
    tip = hilt + bdir * 0.74
    s.capsule(g - bdir * 0.09, g + bdir * 0.05, 0.02, GRIP)
    s.sphere(g - bdir * 0.11, 0.03, GUARD)
    s.capsule(hilt - perp * 0.1, hilt + perp * 0.1, 0.018, GUARD)
    # flat-ish blade: two thin capsules side by side reads wider than a rod
    side = perp * 0.012
    s.capsule(hilt + side, tip, 0.022, BLADE, rb=0.006)
    s.capsule(hilt - side, tip, 0.022, BLADE, rb=0.006)
    return hilt, tip


def sword_ground():
    s = Scene()
    add_sword(s, (-0.3, 0.06, 0.035), (1.0, -0.18, 0.0), up=(0, 0, 1))
    return s


COIN = Material(lambda p, n: ramp(value3(p[:, 0] * 70, p[:, 1] * 70, p[:, 2] * 70, 3) * 0.6 + np.clip(n[:, 2], 0, 1) * 0.4,
                                  ["#6e4c10", "#b88a28", "#e8bd48", "#fff0a0"]))


def gold_coins():
    s = Scene()
    rng = np.random.default_rng(11)
    pts = [(0, 0, 0)] + [(rng.uniform(-0.12, 0.12), rng.uniform(-0.12, 0.12), 0) for _ in range(6)]
    for i, (x, y, _) in enumerate(pts):
        for k in range(3 if i == 0 else rng.integers(1, 3)):
            z = 0.012 + k * 0.022
            s.cyl((x + rng.uniform(-0.01, 0.01), y), 0.055, z - 0.01, z + 0.01, COIN, round_=0.004)
    return s


APPLE_SKIN = Material(lambda p, n: ramp(fbm3(p, 14, 2, 4) * 0.6 + np.clip(p[:, 2] * 3, 0, 1) * 0.4,
                                        ["#5a0c08", "#9a1a10", "#c8321c", "#e08a3a"]))
STEM = Material(_c("#3a2614"))
LEAF = Material(lambda p, n: ramp(fbm3(p, 30, 2, 2), ["#2c5014", "#4a7a20"]))


def red_apple():
    s = Scene()
    s.ellipsoid((0, 0, 0.1), (0.1, 0.1, 0.092), APPLE_SKIN)
    s.capsule((0, 0, 0.17), (0.01, 0.0, 0.23), 0.008, STEM)
    s.ellipsoid((0.04, 0.0, 0.215), (0.04, 0.02, 0.008), LEAF)
    return s


GLASS = Material(lambda p, n: ramp(np.clip(p[:, 2] * 2.6, 0, 1), ["#3a0610", "#8a1020", "#d02a3a"]),
                 emissive=lambda p, n: np.tile(_c("#401018"), (p.shape[0], 1)))
CORK = Material(_c("#8a6a42"))
GLASS_NECK = Material(_c("#9fb8b0"))


def healing_potion():
    s = Scene()
    s.sphere((0, 0, 0.1), 0.1, GLASS)
    s.cyl((0, 0), 0.035, 0.17, 0.27, GLASS_NECK)
    s.cyl((0, 0), 0.04, 0.26, 0.31, CORK, round_=0.01)
    return s


# item id -> model builder; ids match game/data/items.json
ITEM_MODELS = {
    "iron_sword": sword_ground,
    "gold_coins": gold_coins,
    "red_apple": red_apple,
    "healing_potion": healing_potion,
}


def sword_icon():
    """Inventory pose: classic diagonal, tip to the upper right, slightly thicker read."""
    s = Scene()
    add_sword(s, (0.0, 0.0, 0.0), (0.42, -0.42, 0.95), up=(1, 1, 0))
    return s


# optional icon-specific poses (default: the ground model)
ICON_MODELS = {"iron_sword": sword_icon}
