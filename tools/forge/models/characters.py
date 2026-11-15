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


def adventurer_pose(phase=0.0, walk=1.0, breathe=0.0, weapon="iron_sword", swing=-1.0, outfit="adventurer"):
    """Return (Scene, anchors) for a walk phase in radians. walk=0 -> idle."""
    s = Scene()
    sw = np.sin(phase) * walk
    bandit = outfit == "bandit"
    TUNIC_, LEATHER_, PANTS_, SKIN_ = (BANDIT["cloth"], BANDIT["leather"], BANDIT["pants"], BANDIT["skin"]) if bandit \
        else (TUNIC, LEATHER, PANTS, SKIN)
    bob = -0.03 * np.cos(2 * phase) * walk + 0.008 * breathe
    hip_z = 0.79 + bob
    anchors = {}

    def leg(side, ang, lift):
        hip = np.array([0.0, side * 0.1, hip_z])
        thigh = _rot_pitch(np.array([0, 0, -0.39]), -ang)
        knee = hip + thigh
        shin = _rot_pitch(np.array([0, 0, -0.375]), -ang + lift)
        ankle = knee + shin
        if ankle[2] < 0.07:
            ankle[2] = 0.07
        toe = ankle + np.array([0.16, 0, -0.04])
        toe[2] = max(toe[2], 0.035)
        s.capsule(hip, knee, 0.085, PANTS_, rb=0.07)
        s.capsule(knee, ankle, 0.075, BOOTS, rb=0.065)
        s.capsule(knee + np.array([0.0, 0, 0.02]), knee + np.array([0.02, 0, -0.06]), 0.088, BOOTS if bandit else BOOT_CUFF)
        s.capsule(ankle, toe, 0.06, BOOTS, rb=0.05)

    lift_l = 0.7 * max(0.0, -np.cos(phase)) * walk
    lift_r = 0.7 * max(0.0, np.cos(phase)) * walk
    leg(+1, 0.45 * sw, lift_l)
    leg(-1, -0.45 * sw, lift_r)

    # torso
    pelvis = np.array([0.0, 0, hip_z + 0.05])
    chest = np.array([0.02, 0, hip_z + 0.43])
    s.ellipsoid(pelvis + np.array([0, 0, 0.04]), (0.13, 0.17, 0.13), TUNIC_)
    s.ellipsoid(chest, (0.14, 0.2, 0.2), TUNIC_)
    s.capsule(pelvis, chest, 0.15, TUNIC_)
    # tunic skirt flare
    s.cyl((0.0, 0.0), 0.19, hip_z - 0.18, hip_z + 0.05, TUNIC_, round_=0.05)
    # belt with buckle and pouch
    s.cyl((0.0, 0.0), 0.175, hip_z + 0.04, hip_z + 0.1, LEATHER_, round_=0.02)
    s.box((0.17, 0.0, hip_z + 0.07), (0.02, 0.04, 0.035), BRASS)
    s.box((0.06, 0.17, hip_z - 0.02), (0.06, 0.035, 0.07), LEATHER_, round_=0.02)
    # leather chest strap / bodice
    s.ellipsoid(chest + np.array([0.04, 0, -0.06]), (0.12, 0.175, 0.13), LEATHER_)
    # neck & head
    neck = chest + np.array([0.0, 0, 0.18])
    head = neck + np.array([0.02, 0, 0.17])
    s.capsule(neck, neck + np.array([0, 0, 0.08]), 0.06, SKIN_)
    s.ellipsoid(head, (0.12, 0.11, 0.13), SKIN_)
    s.sphere(head + np.array([0.105, 0.04, 0.02]), 0.016, EYE)
    s.sphere(head + np.array([0.105, -0.04, 0.02]), 0.016, EYE)
    s.sphere(head + np.array([0.12, 0.0, -0.02]), 0.022, SKIN_)
    # voluminous curly hair: clustered noisy blobs around back/top/sides
    hair_pts = [(-0.05, 0, 0.06, 0.15), (-0.02, 0, 0.11, 0.13), (-0.1, 0.0, -0.02, 0.13),
                (-0.04, 0.12, 0.02, 0.11), (-0.04, -0.12, 0.02, 0.11), (0.04, 0.1, 0.08, 0.09),
                (0.04, -0.1, 0.08, 0.09), (-0.09, 0.1, -0.1, 0.1), (-0.09, -0.1, -0.1, 0.1),
                (-0.12, 0.0, -0.14, 0.11), (-0.06, 0.15, -0.14, 0.08), (-0.06, -0.15, -0.14, 0.08),
                (0.07, 0.0, 0.12, 0.08)]
    if bandit:
        s.ellipsoid(head + np.array([-0.025, 0, 0.03]), (0.15, 0.145, 0.16), BANDIT["hood"], displace=(0.01, 14.0, 3))
        s.ellipsoid(head + np.array([0.06, 0, -0.07]), (0.07, 0.115, 0.05), BANDIT["hood"])  # face scarf
        s.capsule(head + np.array([-0.1, 0, -0.08]), chest + np.array([-0.14, 0, 0.12]), 0.07, BANDIT["hood"])
    else:
        for i, (x, y, z, r) in enumerate(hair_pts):
            # fuller at the back and sides; kept off the face so it stays visible
            k = 1.0 if x > 0 else 1.14
            s.sphere(head + np.array([x * k - (0.0 if x > 0 else 0.01), y * 1.12, z * 1.06]), r * (0.95 if x > 0 else 1.1),
                     HAIR, displace=(0.03, 30.0, 50 + i))
    # cloak: hangs from shoulders behind the back, swings with gait
    sway = 0.08 * walk * (0.6 + 0.4 * np.cos(2 * phase))
    top = chest + np.array([-0.12, 0, 0.13])
    bot = np.array([-0.22 - sway, 0, 0.42 + bob])
    cl_dir = bot - top
    ang = np.arctan2(-cl_dir[0], -cl_dir[2])
    from sdf import rot_axis_mat
    mid = (top + bot) / 2
    L = np.linalg.norm(cl_dir)
    if not bandit:
        Rc = rot_axis_mat((0, 1, 0), -ang)
        s.box((0, 0, 0), (0.035, 0.215, L / 2), CLOAK, round_=0.035, T=mid, R=Rc)
        # pale hem band so the cloak edge reads from behind
        s.box((0, 0, -L / 2 + 0.035), (0.04, 0.22, 0.028), CLOAK_TRIM, round_=0.02, T=mid, R=Rc)
        s.capsule(top + np.array([0.04, 0.2, 0]), top + np.array([0.04, -0.2, 0]), 0.058, CLOAK)
        s.sphere(chest + np.array([0.13, 0.0, 0.15]), 0.03, BRASS)   # cloak clasp

    # arms. swing in [0,1] = attack progress (windup until 0.45, strike, recover)
    bow = weapon == "hunting_bow"
    def arm(side, pitch, bend, raise_out=0.0):
        sh = chest + np.array([-0.01, side * 0.23, 0.11])
        s.sphere(sh, 0.085, LEATHER_)
        up = _rot_pitch(np.array([0, side * (0.04 + raise_out), -0.28]), -pitch)
        elbow = sh + up
        fore = _rot_pitch(np.array([0, 0, -0.26]), -pitch - bend)
        hand = elbow + fore
        s.capsule(sh, elbow, 0.062, TUNIC_ if bandit else SHIRT, rb=0.055)
        s.capsule(elbow, hand, 0.052, LEATHER_, rb=0.045)
        s.sphere(hand, 0.045, SKIN_)
        return hand

    attacking = swing >= 0.0
    if bow:
        draw = 0.0
        if attacking:
            draw = min(1.0, swing / 0.6) if swing < 0.75 else max(0.0, 1.0 - (swing - 0.75) * 4.0)
        lp = 1.45 * (1.0 if attacking else 0.25) - (0.0 if attacking else 0.45 * sw)
        lhand = arm(+1, lp, 0.05, 0.05)
        rhand = arm(-1, 1.2 * (1.0 if attacking else 0.2), 1.3 * (1.0 if attacking else 0.25))
        fwd = np.array([1.0, 0.0, 0.0]) if attacking else np.array([0.6, 0.0, -0.8])
        upd = np.array([0.0, 0.25, 1.0]) if attacking else np.array([0.8, 0.0, 0.6])
        nock = add_bow(s, lhand, upd, fwd, draw)
        anchors["blade_base"] = lhand
        anchors["blade_tip"] = lhand + fwd * 0.5
    else:
        arm(+1, -0.45 * sw if not attacking else 0.25, 0.2)
        if attacking:
            if swing < 0.45:
                k = swing / 0.45
                rp, el = -0.2 - 1.9 * k, -0.69 + 1.95 * k        # wind up: blade raised behind
            elif swing < 0.7:
                k = (swing - 0.45) / 0.25
                rp, el = -2.1 + 3.1 * k, 1.26 - 1.9 * k          # strike down and forward
            else:
                k = (swing - 0.7) / 0.3
                rp, el = 1.0 - 0.8 * k, -0.64 - 0.05 * k        # recover
            hand = arm(-1, rp, 0.3)
            bdir = np.array([np.cos(el), -0.18, np.sin(el)])
        else:
            hand = arm(-1, 0.18 * sw, 0.35)
            bdir = np.array([0.62, -0.18, -0.52])
        bdir = bdir / np.linalg.norm(bdir)
        if weapon in ("iron_sword", "lightning_sword", "rusty_dagger"):
            hilt, tip = add_sword(s, hand, bdir, magic=weapon == "lightning_sword")
        else:
            hilt = hand + bdir * 0.07
            tip = hilt + bdir * 0.74
        anchors["blade_base"] = hilt
        anchors["blade_tip"] = tip
    anchors["head"] = head + np.array([0, 0, 0.2])
    return s, anchors


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
    hip_z = 0.82 - 0.02 * abs(np.cos(phase)) * walk
    for side, ang in ((1, 0.4 * sw), (-1, -0.4 * sw)):
        hip = np.array([0, side * 0.09, hip_z])
        knee = hip + _rot_pitch(np.array([0, 0, -0.38]), -ang)
        ankle = knee + _rot_pitch(np.array([0, 0, -0.37]), -ang + 0.25 * max(0, -np.cos(phase)) * walk)
        ankle[2] = max(ankle[2], 0.05)
        s.capsule(hip, knee, 0.03, BONE_M)
        s.capsule(knee, ankle, 0.026, BONE_M)
        s.sphere(knee, 0.04, BONE_M)
        s.capsule(ankle, ankle + np.array([0.12, 0, -0.02]), 0.03, BONE_M, rb=0.02)
    s.ellipsoid((0, 0, hip_z + 0.03), (0.08, 0.14, 0.06), BONE_M)
    chest = np.array([0.02, 0, hip_z + 0.42])
    s.capsule((0, 0, hip_z), chest, 0.03, BONE_M)
    for k in range(4):
        z = hip_z + 0.22 + k * 0.065
        r = 0.13 - abs(k - 1.5) * 0.015
        s.torus_z((0.02, 0, z), r, 0.014, BONE_M)
    head = chest + np.array([0.03, 0, 0.27])
    s.sphere(head, 0.115, BONE_M)
    s.ellipsoid(head + np.array([0.06, 0, -0.08]), (0.07, 0.075, 0.04), BONE_M)
    for y in (-1, 1):
        s.sphere(head + np.array([0.09, y * 0.045, 0.0]), 0.03, SOCKET)
    for side in (1, -1):
        sh = chest + np.array([0, side * 0.2, 0.08])
        s.sphere(sh, 0.05, BONE_M)
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
        elbow = sh + _rot_pitch(np.array([0, side * 0.03, -0.28]), -rp)
        hand = elbow + _rot_pitch(np.array([0, 0, -0.25]), -rp - 0.3)
        s.capsule(sh, elbow, 0.025, BONE_M)
        s.capsule(elbow, hand, 0.022, BONE_M)
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
