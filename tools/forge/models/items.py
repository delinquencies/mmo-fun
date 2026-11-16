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
LIGHTNING_BLADE = Material(lambda p, n: ramp(fbm3(p, 26, 2, 7) * 0.6 + value3(p[:, 0] * 90, p[:, 1] * 90, p[:, 2] * 90, 2) * 0.4,
                                             ["#5f7fb8", "#9fc4f2", "#d8ecff", "#ffffff"]),
                           emissive=lambda p, n: np.tile(_c("#2a6cff"), (p.shape[0], 1)) * 0.55)
RUNE_GUARD = Material(lambda p, n: ramp(fbm3(p, 24, 2, 9), ["#2a2440", "#4a3f78", "#7a6ab8"]), 0.1, 30.0)
BOW_WOOD = Material(lambda p, n: ramp(np.abs(np.sin(p[:, 2] * 60 + fbm3(p, 8, 2, 4) * 6)), ["#4a2c14", "#7a4e26", "#9c6a38"]), 0.15, 30.0)
STRING = Material(_c("#d8d0b8"))
FLETCH = Material(_c("#c84a2a"))
WEAPON_MATERIALS = [BLADE, GUARD, GRIP, LIGHTNING_BLADE, RUNE_GUARD, BOW_WOOD, STRING]
for _m in (BLADE, LIGHTNING_BLADE, STRING):
    _m.no_outline = True      # sprite renderer: blades and strings are too thin to outline


def add_sword(s, grip_center, bdir, up=(0, 0, 1), magic=False, blade_mat=None):
    """Arming sword (iron, or the enchanted lightning blade). grip_center = where the
    hand closes; bdir = blade direction."""
    bdir = np.asarray(bdir, float)
    bdir = bdir / np.linalg.norm(bdir)
    g = np.asarray(grip_center, float)
    perp = np.cross(bdir, np.asarray(up, float))
    if np.linalg.norm(perp) < 1e-6:
        perp = np.array([0.0, 1.0, 0.0])
    perp = perp / np.linalg.norm(perp)
    hilt = g + bdir * 0.07
    tip = hilt + bdir * 0.74
    bm = blade_mat or (LIGHTNING_BLADE if magic else BLADE)
    gm = RUNE_GUARD if magic else GUARD
    s.capsule(g - bdir * 0.09, g + bdir * 0.05, 0.02, GRIP)
    s.sphere(g - bdir * 0.11, 0.03, gm)
    s.capsule(hilt - perp * 0.1, hilt + perp * 0.1, 0.018, gm)
    # flat-ish blade: two thin capsules side by side reads wider than a rod
    side = perp * 0.012
    s.capsule(hilt + side, tip, 0.022, bm, rb=0.006)
    s.capsule(hilt - side, tip, 0.022, bm, rb=0.006)
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


def add_bow(s, grip, up_dir, fwd, drawn=0.0):
    """Short hunting bow held at `grip`; limbs along up_dir, belly facing fwd.
    drawn 0..1 pulls the string back. Returns the nocking point."""
    up_dir = np.asarray(up_dir, float) / np.linalg.norm(up_dir)
    fwd = np.asarray(fwd, float) / np.linalg.norm(fwd)
    g = np.asarray(grip, float)
    L = 0.5
    pts = []
    for k in range(-4, 5):
        t = k / 4.0
        bend = (1 - t * t) * 0.09 + drawn * 0.04 * (1 - t * t)
        pts.append(g + up_dir * t * L + fwd * bend)
    for a, b in zip(pts[:-1], pts[1:]):
        s.capsule(a, b, 0.018, BOW_WOOD, rb=0.016)
    nock = g - fwd * (0.04 + drawn * 0.32)
    s.capsule(pts[0], nock, 0.005, STRING)
    s.capsule(nock, pts[-1], 0.005, STRING)
    return nock


def bow_ground():
    s = Scene()
    add_bow(s, (0.0, 0.0, 0.04), (1.0, -0.2, 0.0), (0.0, 0.0, 1.0))
    return s


def bow_icon():
    s = Scene()
    add_bow(s, (0.0, 0.0, 0.0), (0.45, -0.45, 0.95), (0.5, 0.5, -0.2))
    return s


def lightning_ground():
    s = Scene()
    add_sword(s, (-0.3, 0.06, 0.035), (1.0, -0.18, 0.0), up=(0, 0, 1), magic=True)
    return s


def lightning_icon():
    s = Scene()
    add_sword(s, (0.0, 0.0, 0.0), (0.42, -0.42, 0.95), up=(1, 1, 0), magic=True)
    return s


PELT = Material(lambda p, n: ramp(value3(p[:, 0] * 50, p[:, 1] * 50, p[:, 2] * 50, 3) * 0.7 + fbm3(p, 8, 2, 1) * 0.3,
                                  ["#3a3632", "#5e5850", "#8a8276", "#a8a092"]), 0.5, 40.0)
BONE = Material(lambda p, n: ramp(fbm3(p, 14, 2, 2), ["#9a9078", "#c8bea2", "#e6dec6"]), 0.15, 30.0)
RUST = Material(lambda p, n: ramp(fbm3(p, 20, 2, 6), ["#4a2a18", "#7a4424", "#9a6a40"]), 0.25, 30.0)


def wolf_pelt():
    s = Scene()
    s.ellipsoid((0, 0, 0.03), (0.28, 0.18, 0.03), PELT, displace=(0.015, 18.0, 4))
    s.ellipsoid((0.22, 0.0, 0.05), (0.06, 0.05, 0.04), PELT, displace=(0.01, 20.0, 5))
    return s


def bone_shard():
    s = Scene()
    s.capsule((-0.14, 0, 0.03), (0.14, 0.03, 0.03), 0.022, BONE)
    for x in (-0.15, 0.15):
        s.sphere((x, 0.0 if x < 0 else 0.03, 0.035), 0.035, BONE)
    return s


def rusty_dagger():
    s = Scene()
    add_sword(s, (-0.15, 0.04, 0.03), (1.0, -0.18, 0.0), up=(0, 0, 1), blade_mat=RUST)
    return s


# item id -> model builder; ids match game/data/items.json
ITEM_MODELS = {
    "iron_sword": sword_ground,
    "gold_coins": gold_coins,
    "red_apple": red_apple,
    "healing_potion": healing_potion,
    "hunting_bow": bow_ground,
    "lightning_sword": lightning_ground,
    "wolf_pelt": wolf_pelt,
    "bone_shard": bone_shard,
    "rusty_dagger": rusty_dagger,
}


def sword_icon():
    """Inventory pose: classic diagonal, tip to the upper right, slightly thicker read."""
    s = Scene()
    add_sword(s, (0.0, 0.0, 0.0), (0.42, -0.42, 0.95), up=(1, 1, 0))
    return s


# optional icon-specific poses (default: the ground model)
ICON_MODELS = {"iron_sword": sword_icon, "hunting_bow": bow_icon, "lightning_sword": lightning_icon}
