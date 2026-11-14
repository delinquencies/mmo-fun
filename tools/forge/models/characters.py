"""Posable characters built from SDF limbs.

Models are built facing local +x (right hand on -y) and rotated by yaw for the
eight facings.  Height ~1.8 world units incl. hair: ~70 px at the 64-px tile set and
~105 px at the 96-px tile set -- identical proportions in both.
"""
import numpy as np

from sdf import Scene
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


SKIN = _cloth(["#6e432a", "#8a5a3c", "#a06c48"], 8, 1, 0.05)
HAIR = Material(lambda p, n: ramp(value3(p[:, 0] * 55, p[:, 1] * 55, p[:, 2] * 55, 4) * 0.8 + fbm3(p, 10, 2, 2) * 0.3,
                                  ["#0e0907", "#1e140e", "#33231a", "#4a3324"]), 0.7, 40.0, seed=3)
TUNIC = _cloth(["#3c4a1e", "#56682c", "#6c7f38"], 12, 5)
LEATHER = _cloth(["#3a2414", "#5e3b20", "#7a5030"], 16, 6, 0.2)
PANTS = _cloth(["#33241a", "#4a3424", "#5c4430"], 12, 7)
BOOTS = _cloth(["#24170e", "#3a2616", "#4e3420"], 12, 8)
CLOAK = _cloth(["#2a3416", "#3e4a22", "#52602e"], 9, 9, 0.25)
BRASS = Material(lambda p, n: ramp(fbm3(p, 30, 2, 1), ["#6a4a18", "#b08a3a", "#e0c070"]), 0.1, 30)
STEEL = Material(lambda p, n: ramp(fbm3(p, 20, 2, 2), ["#9fb4d0", "#d6e4f4", "#ffffff"]),
                 emissive=lambda p, n: np.tile(_c("#3c6cff"), (p.shape[0], 1)) * 0.45)
EYE = Material(_c("#140c08"))


def _rot_pitch(v, a):
    """rotate vector in the x-z plane (forward pitch about y)."""
    x, z = v[0], v[2]
    return np.array([x * np.cos(a) + z * np.sin(a), v[1], -x * np.sin(a) + z * np.cos(a)])


def adventurer_pose(phase=0.0, walk=1.0, breathe=0.0):
    """Return (Scene, anchors) for a walk phase in radians. walk=0 -> idle."""
    s = Scene()
    sw = np.sin(phase) * walk
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
        s.capsule(hip, knee, 0.085, PANTS, rb=0.07)
        s.capsule(knee, ankle, 0.075, BOOTS, rb=0.065)
        s.capsule(knee + np.array([0.0, 0, 0.02]), knee + np.array([0.02, 0, -0.06]), 0.085, BOOTS)
        s.capsule(ankle, toe, 0.06, BOOTS, rb=0.05)

    lift_l = 0.7 * max(0.0, -np.cos(phase)) * walk
    lift_r = 0.7 * max(0.0, np.cos(phase)) * walk
    leg(+1, 0.45 * sw, lift_l)
    leg(-1, -0.45 * sw, lift_r)

    # torso
    pelvis = np.array([0.0, 0, hip_z + 0.05])
    chest = np.array([0.02, 0, hip_z + 0.43])
    s.ellipsoid(pelvis + np.array([0, 0, 0.04]), (0.13, 0.17, 0.13), TUNIC)
    s.ellipsoid(chest, (0.14, 0.2, 0.2), TUNIC)
    s.capsule(pelvis, chest, 0.15, TUNIC)
    # tunic skirt flare
    s.cyl((0.0, 0.0), 0.19, hip_z - 0.18, hip_z + 0.05, TUNIC, round_=0.05)
    # belt with buckle and pouch
    s.cyl((0.0, 0.0), 0.175, hip_z + 0.04, hip_z + 0.1, LEATHER, round_=0.02)
    s.box((0.17, 0.0, hip_z + 0.07), (0.02, 0.04, 0.035), BRASS)
    s.box((0.06, 0.17, hip_z - 0.02), (0.06, 0.035, 0.07), LEATHER, round_=0.02)
    # leather chest strap / bodice
    s.ellipsoid(chest + np.array([0.04, 0, -0.06]), (0.12, 0.175, 0.13), LEATHER)
    # neck & head
    neck = chest + np.array([0.0, 0, 0.18])
    head = neck + np.array([0.02, 0, 0.17])
    s.capsule(neck, neck + np.array([0, 0, 0.08]), 0.06, SKIN)
    s.ellipsoid(head, (0.12, 0.11, 0.13), SKIN)
    s.sphere(head + np.array([0.105, 0.04, 0.02]), 0.016, EYE)
    s.sphere(head + np.array([0.105, -0.04, 0.02]), 0.016, EYE)
    s.sphere(head + np.array([0.12, 0.0, -0.02]), 0.022, SKIN)
    # voluminous curly hair: clustered noisy blobs around back/top/sides
    hair_pts = [(-0.05, 0, 0.06, 0.15), (-0.02, 0, 0.11, 0.13), (-0.1, 0.0, -0.02, 0.13),
                (-0.04, 0.12, 0.02, 0.11), (-0.04, -0.12, 0.02, 0.11), (0.04, 0.1, 0.08, 0.09),
                (0.04, -0.1, 0.08, 0.09), (-0.09, 0.1, -0.1, 0.1), (-0.09, -0.1, -0.1, 0.1),
                (-0.12, 0.0, -0.14, 0.11), (-0.06, 0.15, -0.14, 0.08), (-0.06, -0.15, -0.14, 0.08),
                (0.07, 0.0, 0.12, 0.08)]
    for i, (x, y, z, r) in enumerate(hair_pts):
        s.sphere(head + np.array([x, y, z]), r, HAIR, displace=(0.028, 34.0, 50 + i))
    # cloak: hangs from shoulders behind the back, swings with gait
    sway = 0.08 * walk * (0.6 + 0.4 * np.cos(2 * phase))
    top = chest + np.array([-0.12, 0, 0.13])
    bot = np.array([-0.22 - sway, 0, 0.42 + bob])
    cl_dir = bot - top
    ang = np.arctan2(-cl_dir[0], -cl_dir[2])
    from sdf import rot_axis_mat
    mid = (top + bot) / 2
    L = np.linalg.norm(cl_dir)
    s.box((0, 0, 0), (0.035, 0.23, L / 2), CLOAK, round_=0.03, T=mid, R=rot_axis_mat((0, 1, 0), -ang))
    s.capsule(top + np.array([0.04, 0.2, 0]), top + np.array([0.04, -0.2, 0]), 0.055, CLOAK)

    # arms
    def arm(side, swing, holds):
        sh = chest + np.array([-0.01, side * 0.23, 0.11])
        s.sphere(sh, 0.085, LEATHER)
        up = _rot_pitch(np.array([0, side * 0.04, -0.28]), -swing)
        elbow = sh + up
        bend = 0.35 if holds else 0.2
        fore = _rot_pitch(np.array([0, 0, -0.26]), -swing - bend)
        hand = elbow + fore
        s.capsule(sh, elbow, 0.062, TUNIC, rb=0.055)
        s.capsule(elbow, hand, 0.052, LEATHER, rb=0.045)
        s.sphere(hand, 0.045, SKIN)
        return hand

    arm(+1, -0.45 * sw, False)
    hand = arm(-1, 0.18 * sw, True)
    # sword in right hand, held low with the tip forward and down
    bdir = np.array([0.62, -0.18, -0.52])
    bdir = bdir / np.linalg.norm(bdir)
    hilt = hand + bdir * 0.06
    tip = hilt + bdir * 0.78
    s.capsule(hand - bdir * 0.1, hand + bdir * 0.04, 0.022, LEATHER)
    s.sphere(hand - bdir * 0.12, 0.03, BRASS)
    perp = np.cross(bdir, np.array([0, 0, 1.0]))
    perp = perp / np.linalg.norm(perp)
    s.capsule(hilt - perp * 0.09, hilt + perp * 0.09, 0.02, BRASS)
    s.capsule(hilt, tip, 0.03, STEEL, rb=0.008)
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
