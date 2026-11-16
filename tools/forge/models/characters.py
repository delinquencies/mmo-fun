"""Posable characters built from SDF limbs.

Models are built facing local +x (right hand on -y) and rotated by yaw for the
eight facings.  Height ~1.8 world units incl. hair: ~70 px at the 64-px tile set and
~105 px at the 96-px tile set -- identical proportions in both.
"""
import numpy as np

from sdf import Scene
from models.items import add_sword, add_bow
from materials import Material, ramp, wood_grain, _c
from noise import fbm3, value3, hash01

# facing order shared with the Godot runtime (screen-relative names)
DIRECTIONS = ["S", "SW", "W", "NW", "N", "NE", "E", "SE"]
DIR_YAW = {d: np.radians(45.0 + 45.0 * i) for i, d in enumerate(DIRECTIONS)}


def _cloth(cols, freq=14.0, seed=0, b=0.18):
    def f(p, n):
        t = fbm3(p, freq, 2, seed) * 0.8 + value3(p[:, 0] * 70, p[:, 1] * 70, p[:, 2] * 70, seed) * 0.25
        return ramp(np.clip(t - 0.05, 0, 1), cols)
    return Material(f, b, freq * 2, seed=seed)


# Art pass 1: values are keyed for readability on green ground. Each piece of
# gear sits in its own value/hue band (cream linen, khaki-olive tunic, tan
# leather, umber trousers, russet cloak) so the figure separates into parts at
# 72 px instead of merging into one dark olive shape.
SKIN = _cloth(["#8a5636", "#b07a50", "#cf9a6a"], 8, 1, 0.05)
HAIR = Material(lambda p, n: ramp(value3(p[:, 0] * 46, p[:, 1] * 46, p[:, 2] * 46, 4) * 0.75 + fbm3(p, 9, 2, 2) * 0.3
                                  + np.clip(n[:, 2], 0, 1) * 0.22,
                                  ["#0c0706", "#170e0a", "#261810", "#3a2618", "#553a26"]), 0.7, 36.0, seed=3)
TUNIC = _cloth(["#5a6230", "#7c8742", "#9aa456"], 12, 5)
SHIRT = _cloth(["#b9a983", "#d6c9a4", "#ece2c4"], 12, 15, 0.12)
LEATHER = _cloth(["#6a4222", "#96642f", "#bb8748"], 16, 6, 0.2)
PANTS = _cloth(["#3e2c1e", "#57402c", "#6e543a"], 12, 7)
BOOTS = _cloth(["#2c1c10", "#4a301c", "#624428"], 12, 8)
BOOT_CUFF = _cloth(["#7a5630", "#a47a48", "#c29a62"], 14, 18, 0.15)
CLOAK = _cloth(["#4e2a1c", "#74402a", "#955a3a"], 9, 9, 0.25)
CLOAK_TRIM = _cloth(["#a8843c", "#d0ac58", "#ecd080"], 14, 19, 0.1)
BRASS = Material(lambda p, n: ramp(fbm3(p, 30, 2, 1), ["#6a4a18", "#b08a3a", "#e0c070"]), 0.1, 30)
STEEL = Material(lambda p, n: ramp(fbm3(p, 20, 2, 2), ["#9fb4d0", "#d6e4f4", "#ffffff"]),
                 emissive=lambda p, n: np.tile(_c("#3c6cff"), (p.shape[0], 1)) * 0.45)
EYE = Material(_c("#140c08"))


def _rot_pitch(v, a):
    """rotate vector in the x-z plane (forward pitch about y)."""
    x, z = v[0], v[2]
    return np.array([x * np.cos(a) + z * np.sin(a), v[1], -x * np.sin(a) + z * np.cos(a)])


BANDIT = {   # dull greys and a rust hood: reads as "not the player" at a glance
    "cloth": _cloth(["#463c34", "#63564a", "#7e6e5e"], 12, 21),
    "leather": _cloth(["#2c2018", "#493626", "#644c36"], 16, 22, 0.2),
    "pants": _cloth(["#34302a", "#4e483e", "#655d50"], 12, 23),
    "hood": _cloth(["#5a2618", "#863a24", "#a85030"], 10, 24, 0.25),
    "skin": _cloth(["#8a6448", "#a67a58", "#bc8e68"], 8, 25, 0.05),
}


# --- humanoids built with the character kit (tools/forge/charkit.py) ----------
import charkit
from charkit import P

_EYE = P("#140c08", "#140c08", "#140c08", detail=True)
_BRASS = P("#4a3410", "#86621e", "#be9434", "#e6c35a", "#fbe89a", spec=1.0, gloss=14.0, detail=True)

ADVENTURER = charkit.CharacterSpec(
    name="adventurer",
    skin=P("#5a3220", "#86523a", "#ae7650", "#cc9568", "#e4b488"),
    hair=P("#060404", "#0f0907", "#1a100b", "#281912", "#3a261a"),
    tunic=P("#2e3818", "#4c5a26", "#6f7e38", "#90a04e", "#b0bf6a"),
    sleeve=P("#74684c", "#a69a78", "#cdc19e", "#e6dcbe", "#f6f0da"),
    leather=P("#3c200e", "#673a1a", "#935c2a", "#b98242", "#d8a862", spec=0.6, gloss=10.0),
    trousers=P("#20150c", "#38261a", "#513a28", "#6a4e36", "#836448"),
    boots=P("#170e08", "#2c1b10", "#43291a", "#5b3c28", "#735036"),
    cuff=P("#4a2e14", "#7a5226", "#a67a40", "#c69e5c", "#e0be7e"),
    cloak=P("#2c120c", "#502616", "#763c24", "#995636", "#b9734c"),
    cloak_trim=P("#5a4214", "#96722a", "#c8a044", "#e8c868", "#fbe89a"),
    metal=_BRASS, eye=_EYE)

BANDIT_SPEC = charkit.CharacterSpec(
    name="bandit",
    skin=P("#5c4030", "#866048", "#a87c5c", "#c09672", "#d6b08c"),
    hood=P("#3a140c", "#622416", "#8c3a22", "#b05232", "#cc7048"),
    tunic=P("#2a241e", "#463c34", "#63564a", "#7e6e5e", "#988876"),
    sleeve=P("#2a241e", "#463c34", "#63564a", "#7e6e5e", "#988876"),
    leather=P("#1c140e", "#33251a", "#4c3828", "#664e38", "#80644a"),
    trousers=P("#1c1a16", "#34302a", "#4e483e", "#655d50", "#7c7466"),
    boots=P("#120c08", "#241810", "#38261a", "#4c3626", "#604632"),
    cuff=P("#120c08", "#241810", "#38261a", "#4c3626", "#604632"),
    metal=_BRASS, eye=_EYE)

SPECS = {"adventurer": ADVENTURER, "bandit": BANDIT_SPEC}


def adventurer_pose(phase=0.0, walk=1.0, breathe=0.0, weapon="iron_sword", swing=-1.0, outfit="adventurer", run=0.0):
    """Build one frame of a kit humanoid. Kept as the forge's entry point:
    phase (radians) drives walk or run; breathe drives idle; swing in [0, 1]
    plays the attack (sword swing, or a bow shot when a bow is held)."""
    t = (phase / (2 * np.pi)) % 1.0
    if swing >= 0.0:
        pose = charkit.clip_shoot(swing) if weapon == "hunting_bow" else charkit.clip_attack(swing)
    elif run > 0.0:
        pose = charkit.clip_run(t)
    elif walk >= 0.5:
        pose = charkit.clip_walk(t)
    else:
        # idle: `breathe` (player) or a slow `phase` (creatures) drives the clip
        pose = charkit.clip_idle(np.arcsin(np.clip(breathe, -1, 1)) / (2 * np.pi) if walk == 0.0 else t)
        if weapon == "hunting_bow":
            pose.arm, pose.elbow = (0.36, 0.24), (0.05, 0.33)
    return charkit.build(SPECS[outfit], pose, weapon, add_sword, add_bow)


WOOL = Material(lambda p, n: ramp(value3(p[:, 0] * 45, p[:, 1] * 45, p[:, 2] * 45, 2) * 0.7 + fbm3(p, 8, 2, 1) * 0.4,
                                  ["#9c968a", "#c9c3b4", "#e6e1d4", "#f4f0e6"]), 0.6, 35.0, seed=2)
SHEEP_DARK = _cloth(["#1c1714", "#2e2620", "#423830"], 14, 3, 0.1)


def sheep_pose(graze=0.0, step=0.0):
    s = Scene()
    s.ellipsoid((0, 0, 0.5), (0.36, 0.22, 0.2), WOOL, displace=(0.035, 16.0, 7))
    s.sphere((-0.24, 0, 0.52), 0.18, WOOL, displace=(0.03, 16.0, 8))
    s.sphere((0.2, 0, 0.55), 0.17, WOOL, displace=(0.03, 16.0, 9))
    for x in (-0.2, 0.2):
        for y in (-0.11, 0.11):
            sw = step * (1 if (x > 0) == (y > 0) else -1) * 0.06
            s.capsule((x, y, 0.38), (x + sw, y, 0.02), 0.035, SHEEP_DARK, rb=0.028)
    hz = 0.6 - 0.38 * graze
    hx = 0.43 + 0.08 * graze
    s.capsule((0.3, 0, 0.55), (hx, 0, hz), 0.07, WOOL)
    s.ellipsoid((hx + 0.05, 0, hz - 0.02), (0.11, 0.07, 0.075), SHEEP_DARK)
    for y in (-1, 1):
        s.ellipsoid((hx - 0.01, y * 0.08, hz + 0.03), (0.03, 0.06, 0.02), SHEEP_DARK)
    return s



# ---------------------------------------------------------------------------
# creatures
# ---------------------------------------------------------------------------
FUR = Material(lambda p, n: ramp(value3(p[:, 0] * 48, p[:, 1] * 48, p[:, 2] * 48, 3) * 0.55 + fbm3(p, 7, 2, 1) * 0.3
                                 + np.clip(p[:, 2] - 0.35, 0, 1) * 0.6,
                                 ["#2a2622", "#4a443c", "#6e665a", "#9a9282", "#bdb5a2"]), 0.55, 38.0, seed=4)
FUR_DARK = _cloth(["#141210", "#24201c", "#38322a"], 14, 6, 0.2)
EYE_GLOW = Material(_c("#2a1a08"), emissive=lambda p, n: np.tile(_c("#c89a2a"), (p.shape[0], 1)) * 0.6)


def wolf_pose(phase=0.0, walk=1.0, bite=-1.0):
    """Grey wolf facing +x. ~1.15 long, 0.62 at the shoulder."""
    s = Scene()
    sw = np.sin(phase) * walk
    bob = 0.025 * abs(np.cos(phase)) * walk
    lunge = 0.0 if bite < 0 else (np.sin(min(1.0, bite / 0.6) * np.pi) * 0.22)
    body_z = 0.5 + bob
    s.ellipsoid((0.0 + lunge * 0.4, 0, body_z), (0.38, 0.16, 0.16), FUR, displace=(0.025, 14.0, 3))
    s.ellipsoid((0.26 + lunge * 0.5, 0, body_z + 0.04), (0.18, 0.17, 0.19), FUR, displace=(0.03, 14.0, 4))
    neck = np.array([0.38 + lunge, 0, body_z + 0.12 - lunge * 0.3])
    head = neck + np.array([0.14, 0, 0.02 - lunge * 0.2])
    s.capsule((0.24 + lunge * 0.5, 0, body_z + 0.06), neck, 0.12, FUR, displace=(0.02, 16.0, 5))
    s.ellipsoid(head, (0.13, 0.1, 0.1), FUR, displace=(0.015, 18.0, 6))
    jaw = 0.04 if bite >= 0 and 0.3 < bite < 0.8 else 0.0
    s.capsule(head + np.array([0.06, 0, -0.02]), head + np.array([0.2, 0, -0.04 - jaw]), 0.045, FUR, rb=0.03)
    s.capsule(head + np.array([0.06, 0, -0.06]), head + np.array([0.18, 0, -0.08 - jaw * 2]), 0.03, FUR_DARK, rb=0.02)
    s.sphere(head + np.array([0.21, 0, -0.035 - jaw]), 0.022, FUR_DARK)
    for y in (-1, 1):
        s.capsule(head + np.array([-0.04, y * 0.055, 0.07]), head + np.array([-0.06, y * 0.07, 0.17]), 0.03, FUR_DARK, rb=0.008)
        s.sphere(head + np.array([0.08, y * 0.05, 0.03]), 0.016, EYE_GLOW)
    for x, y in ((0.26, 1), (0.26, -1), (-0.24, 1), (-0.24, -1)):
        ph = sw * (1 if (x > 0) == (y > 0) else -1)
        hip = np.array([x + lunge * 0.4, y * 0.09, body_z - 0.06])
        knee = hip + np.array([ph * 0.14, 0, -0.22])
        foot = knee + np.array([ph * 0.05 - (0.04 if x < 0 else -0.02), 0, -0.22])
        foot[2] = max(foot[2], 0.03)
        s.capsule(hip, knee, 0.055, FUR, rb=0.04)
        s.capsule(knee, foot, 0.035, FUR_DARK, rb=0.03)
    wag = 0.08 * np.sin(phase * 2)
    s.capsule((-0.36, 0, body_z + 0.04), (-0.62, wag, body_z - 0.12), 0.06, FUR, rb=0.035, displace=(0.025, 16.0, 9))
    return s, {"head": head + np.array([0, 0, 0.25])}


BONE_M = Material(lambda p, n: ramp(fbm3(p, 14, 2, 2) * 0.7 + value3(p[:, 0] * 60, p[:, 1] * 60, p[:, 2] * 60, 1) * 0.3,
                                    ["#7a705a", "#b0a68a", "#d8d0b6", "#ece6d2"]), 0.2, 30.0)
SOCKET = Material(_c("#0a0806"), emissive=lambda p, n: np.tile(_c("#3a6aa0"), (p.shape[0], 1)) * 0.35)
RUSTY = Material(lambda p, n: ramp(fbm3(p, 20, 2, 6), ["#3a2418", "#6a4028", "#8a6040"]), 0.25, 30.0)
SHIELD_WOOD = _cloth(["#3a2414", "#5a3820", "#6e4a2a"], 10, 31, 0.15)


def skeleton_pose(phase=0.0, walk=1.0, swing=-1.0):
    """Skeleton warrior facing +x, same height class as the player."""
    s = Scene()
    sw = np.sin(phase) * walk
    hip_z = 0.86 - 0.02 * abs(np.cos(phase)) * walk     # same build as the living humanoids
    for side, ang in ((1, 0.4 * sw), (-1, -0.4 * sw)):
        hip = np.array([0, side * 0.1, hip_z])
        knee = hip + _rot_pitch(np.array([0, 0, -0.425]), -ang)
        ankle = knee + _rot_pitch(np.array([0, 0, -0.4]), -ang + 0.25 * max(0, -np.cos(phase)) * walk)
        ankle[2] = max(ankle[2], 0.05)
        s.capsule(hip, knee, 0.04, BONE_M, rb=0.03)
        s.capsule(knee, ankle, 0.034, BONE_M, rb=0.026)
        s.sphere(knee, 0.048, BONE_M)
        s.capsule(ankle, ankle + np.array([0.12, 0, -0.02]), 0.03, BONE_M, rb=0.02)
    s.ellipsoid((0, 0, hip_z + 0.03), (0.08, 0.14, 0.06), BONE_M)
    chest = np.array([0.02, 0, hip_z + 0.42])
    s.capsule((0, 0, hip_z), chest, 0.036, BONE_M)
    for k in range(4):
        z = hip_z + 0.22 + k * 0.065
        r = 0.135 - abs(k - 1.5) * 0.015
        s.torus_z((0.02, 0, z), r, 0.019, BONE_M)
    head = chest + np.array([0.03, 0, 0.3])
    s.ellipsoid(head, (0.105, 0.095, 0.11), BONE_M)
    s.ellipsoid(head + np.array([0.06, 0, -0.08]), (0.07, 0.075, 0.04), BONE_M)
    for y in (-1, 1):
        s.sphere(head + np.array([0.09, y * 0.045, 0.0]), 0.03, SOCKET)
    for side in (1, -1):
        sh = chest + np.array([0, side * 0.215, 0.08])
        s.sphere(sh, 0.055, BONE_M)
        s.capsule(chest + np.array([0, 0, 0.08]), sh, 0.026, BONE_M)   # collar bone
        if side == -1 and swing >= 0:
            if swing < 0.5:
                k = swing / 0.5
                rp, el = -0.2 - 1.8 * k, -0.6 + 1.8 * k
            elif swing < 0.72:
                k = (swing - 0.5) / 0.22
                rp, el = -2.0 + 2.9 * k, 1.2 - 1.8 * k
            else:
                rp, el = 0.9, -0.6
        else:
            rp, el = (0.15 * sw if side == -1 else -0.35 * sw), -0.6
        elbow = sh + _rot_pitch(np.array([0, side * 0.06, -0.29]), -rp)
        hand = elbow + _rot_pitch(np.array([0, 0, -0.27]), -rp - 0.3)
        s.capsule(sh, elbow, 0.032, BONE_M, rb=0.026)
        s.capsule(elbow, hand, 0.028, BONE_M, rb=0.022)
        s.sphere(hand, 0.034, BONE_M)
        if side == -1:
            bdir = np.array([np.cos(el), -0.15, np.sin(el)])
            add_sword(s, hand, bdir / np.linalg.norm(bdir), blade_mat=RUSTY)
        else:
            s.cyl_axis(hand + np.array([0.03, 0.04, 0]), hand + np.array([0.07, 0.07, 0]), 0.2, SHIELD_WOOD)
    return s, {"head": head + np.array([0, 0, 0.2])}


def fall_transform(death):
    """Rotation + drop for a death animation (falls backwards, -x)."""
    from sdf import rot_axis_mat
    return rot_axis_mat((0, 1, 0), -death * 1.45)
