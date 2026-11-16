"""Character kit: one rig, one set of animation clips, any number of characters.

A character is a CharacterSpec (proportions + palette + costume options).
A frame is a Pose (joint angles) produced by a clip. `build(spec, pose)` solves
the rig and dresses it, returning (Scene, anchors). Because every facing and
every frame of every animation is the same solved 3D figure rendered through
the same camera, proportions, costume and equipment cannot drift between
directions.

Local frame: the figure faces +x, its right hand is on -y, feet on z = 0, and
the origin is the point on the ground between the feet (the sprite pivot).
"""
from dataclasses import dataclass, field

import numpy as np

from sdf import Scene, rot_axis_mat
from materials import PaletteMaterial

BODY = (1, 0.045)      # smooth-blend group for flesh and fitted clothing


def P(*ramp, **kw):
    return PaletteMaterial(list(ramp), **kw)


def _pitch(v, a):
    """Rotate v about the y axis. A hanging limb (0, 0, -L) swings forward (+x)
    for negative a, so callers pass -angle for 'swing forward by angle'."""
    x, z = v[0], v[2]
    return np.array([x * np.cos(a) + z * np.sin(a), v[1], -x * np.sin(a) + z * np.cos(a)])


@dataclass
class Proportions:
    """Lengths in tiles (1 tile ~ 1 m). Defaults: a sturdy, slightly heroic
    adult of about 6.5 heads - solid enough to hold its shape at 73 px."""
    hip_h: float = 0.81
    hip_w: float = 0.11
    thigh: float = 0.40
    shin: float = 0.375
    torso: float = 0.43
    neck: float = 0.15
    head: float = 0.17         # neck top to head centre
    head_r: tuple = (0.122, 0.11, 0.132)
    shoulder_w: float = 0.24
    upper_arm: float = 0.29
    fore_arm: float = 0.27
    foot: float = 0.17
    bulk: float = 1.18         # limb and torso thickness multiplier


@dataclass
class Pose:
    """Joint angles in radians. Legs and arms: index 0 = left (+y), 1 = right (-y)."""
    hip_drop: float = 0.0                      # pelvis height offset
    lean: float = 0.0                          # torso pitch forward
    thigh: tuple = (0.0, 0.0)                  # forward swing
    knee: tuple = (0.0, 0.0)                   # bend (>= 0)
    arm: tuple = (0.0, 0.0)                    # shoulder swing forward
    elbow: tuple = (0.2, 0.35)                 # bend
    arm_out: tuple = (0.0, 0.0)                # abduction
    head_pitch: float = 0.0
    cloak_sway: float = 0.0
    blade: tuple = None                        # blade direction override (attack)
    bow_draw: float = -1.0                     # >= 0 while shooting


# --- animation clips: t in [0, 1) -> Pose --------------------------------------

def clip_idle(t):
    b = np.sin(t * 2 * np.pi)
    return Pose(hip_drop=0.006 * b, arm=(0.03 * b, -0.02 * b), elbow=(0.22, 0.36), cloak_sway=0.0)


def clip_walk(t):
    ph = t * 2 * np.pi
    sw = np.sin(ph)
    return Pose(hip_drop=-0.028 * np.cos(2 * ph), lean=0.05,
                thigh=(0.5 * sw, -0.5 * sw),
                knee=(0.75 * max(0.0, -np.cos(ph)), 0.75 * max(0.0, np.cos(ph))),
                arm=(-0.5 * sw, 0.22 * sw), elbow=(0.25 + 0.2 * max(0.0, -sw), 0.4),
                cloak_sway=0.08 * (0.6 + 0.4 * np.cos(2 * ph)))


def clip_run(t):
    """A real run: long stride, high knee on the recovering leg, forward lean,
    bent pumping arms, and a deeper bounce than the walk."""
    ph = t * 2 * np.pi
    sw = np.sin(ph)
    return Pose(hip_drop=-0.055 * np.cos(2 * ph) - 0.02, lean=0.24,
                thigh=(0.95 * sw + 0.1, -0.95 * sw + 0.1),
                knee=(0.35 + 1.25 * max(0.0, -np.cos(ph)), 0.35 + 1.25 * max(0.0, np.cos(ph))),
                arm=(-0.95 * sw, 0.5 * sw), elbow=(1.35, 1.1), arm_out=(0.04, 0.04),
                head_pitch=-0.12, cloak_sway=0.11 + 0.03 * np.cos(2 * ph))


def clip_attack(s):
    """Sword swing, s = progress 0..1: wind up (to 0.45), strike (to 0.7), recover."""
    if s < 0.45:
        k = s / 0.45
        rp, el, lean = -0.2 - 1.9 * k, -0.69 + 1.95 * k, -0.06 * k
    elif s < 0.7:
        k = (s - 0.45) / 0.25
        rp, el, lean = -2.1 + 3.1 * k, 1.26 - 1.9 * k, -0.06 + 0.22 * k
    else:
        k = (s - 0.7) / 0.3
        rp, el, lean = 1.0 - 0.8 * k, -0.64 - 0.05 * k, 0.16 * (1 - k)
    front = 0.25 * min(1.0, s / 0.45) if s < 0.7 else 0.25 * (1 - (s - 0.7) / 0.3)
    return Pose(lean=lean, thigh=(front, -front * 0.8), knee=(front * 0.9, 0.1),
                arm=(0.25, rp), elbow=(0.2, 0.3),
                blade=(np.cos(el), -0.18, np.sin(el)))


def clip_shoot(s):
    """Bow shot: raise and draw (to 0.6), hold, loose at 0.75, lower."""
    draw = min(1.0, s / 0.6) if s < 0.75 else max(0.0, 1.0 - (s - 0.75) * 4.0)
    return Pose(thigh=(0.18, -0.14), knee=(0.1, 0.05), arm=(1.45, 1.2), elbow=(0.05, 1.3),
                arm_out=(0.05, 0.0), bow_draw=draw)


# --- the character -----------------------------------------------------------------

@dataclass
class CharacterSpec:
    name: str
    prop: Proportions = field(default_factory=Proportions)
    skin: PaletteMaterial = None
    tunic: PaletteMaterial = None
    sleeve: PaletteMaterial = None
    leather: PaletteMaterial = None
    trousers: PaletteMaterial = None
    boots: PaletteMaterial = None
    cuff: PaletteMaterial = None
    metal: PaletteMaterial = None
    eye: PaletteMaterial = None
    hair: PaletteMaterial = None          # curly hair mass (None = no hair)
    hood: PaletteMaterial = None          # hood and face scarf
    cloak: PaletteMaterial = None
    cloak_trim: PaletteMaterial = None


def solve(prop, pose):
    """Forward kinematics: joint positions in the local frame."""
    J = {}
    hip_z = prop.hip_h + pose.hip_drop
    J["pelvis"] = np.array([0.0, 0.0, hip_z + 0.04])
    spine = np.array([np.sin(pose.lean) * (prop.torso - 0.04), 0.0, np.cos(pose.lean) * (prop.torso - 0.04)])
    J["chest"] = J["pelvis"] + spine
    up = spine / np.linalg.norm(spine)
    fwd = np.array([up[2], 0.0, -up[0]])
    J["up"], J["fwd"] = up, fwd
    J["waist"] = J["pelvis"] + spine * 0.34
    J["neck"] = J["chest"] + up * prop.neck
    hp = pose.lean * 0.5 + pose.head_pitch
    J["head"] = J["neck"] + np.array([np.sin(hp) * prop.head + 0.02, 0.0, np.cos(hp) * prop.head])
    for i, side in enumerate((1, -1)):
        hip = np.array([0.0, side * prop.hip_w, hip_z])
        knee = hip + _pitch(np.array([0.0, side * 0.012, -prop.thigh]), -pose.thigh[i])
        ankle = knee + _pitch(np.array([0.0, 0.0, -prop.shin]), -pose.thigh[i] + pose.knee[i])
        ankle[2] = max(ankle[2], 0.07)                      # feet never sink below the ground
        planted = ankle[2] < 0.1
        toe_dir = np.array([1.0, 0.0, -0.2]) if planted else _pitch(np.array([1.0, 0.0, 0.0]), pose.thigh[i] - pose.knee[i] + 0.35)
        toe = ankle + toe_dir / np.linalg.norm(toe_dir) * prop.foot
        toe[2] = max(toe[2], 0.04)
        sh = J["chest"] + up * 0.07 + np.array([-0.01, side * prop.shoulder_w, 0.0])
        a = pose.arm[i] + pose.lean * 0.5
        elbow = sh + _pitch(np.array([0.0, side * (0.075 + pose.arm_out[i]), -prop.upper_arm]), -a)
        hand = elbow + _pitch(np.array([0.0, -side * 0.02, -prop.fore_arm]), -a - pose.elbow[i])
        k = "L" if side == 1 else "R"
        J["hip" + k], J["knee" + k], J["ankle" + k], J["toe" + k] = hip, knee, ankle, toe
        J["sh" + k], J["elbow" + k], J["hand" + k] = sh, elbow, hand
    return J


def build(spec, pose, weapon=None, add_sword=None, add_bow=None, blade_mat=None):
    """Dress the solved rig. Returns (Scene, anchors)."""
    s = Scene()
    pr = spec.prop
    J = solve(pr, pose)
    b = pr.bulk
    up, fwd = J["up"], J["fwd"]
    anchors = {}
    for k in ("L", "R"):
        hip, knee, ankle, toe = J["hip" + k], J["knee" + k], J["ankle" + k], J["toe" + k]
        # thigh, knee, calf and ankle flow into one another (smooth group)
        s.capsule(hip, knee, 0.09 * b, spec.trousers, rb=0.058 * b, blend=BODY)
        calf = knee + (ankle - knee) * 0.32
        s.capsule(knee, calf, 0.058 * b, spec.boots, rb=0.07 * b, blend=BODY)
        s.capsule(calf, ankle, 0.07 * b, spec.boots, rb=0.044 * b, blend=BODY)
        s.capsule(knee + np.array([0.0, 0, 0.035]), knee + np.array([0.012, 0, -0.03]), 0.074 * b, spec.cuff)
        s.capsule(ankle, toe, 0.054, spec.boots, rb=0.04, blend=BODY)
        mid = (ankle + toe) / 2
        s.box(mid + np.array([0.0, 0, -0.03]), (pr.foot * 0.62, 0.047, 0.018), spec.boots, round_=0.012)
    pelvis, chest, waist = J["pelvis"], J["chest"], J["waist"]
    hip_z = pelvis[2] - 0.04
    # torso: rib cage over a narrow waist, shoulders as a yoke
    s.ellipsoid(pelvis + np.array([0, 0, 0.03]), (0.115 * b, 0.15 * b, 0.11), spec.tunic, blend=BODY)
    s.capsule(waist, chest - up * 0.06, 0.105 * b, spec.tunic, rb=0.14 * b, blend=BODY)
    s.ellipsoid(chest + up * 0.02, (0.125 * b, 0.215, 0.12), spec.tunic, blend=BODY)
    # tunic skirt: narrow at the belt, flaring to a square hem
    s.capsule((0.0, 0.0, hip_z + 0.07), (0.0, 0.0, hip_z - 0.07), 0.125 * b, spec.tunic, rb=0.185)
    s.cyl((0.0, 0.0), 0.2, hip_z - 0.2, hip_z - 0.07, spec.tunic, round_=0.015)
    # belt, buckle, pouch
    s.cyl((0.0, 0.0), 0.142 * b, hip_z + 0.085, hip_z + 0.135, spec.leather, round_=0.015)
    s.box((0.14 * b, 0.0, hip_z + 0.11), (0.02, 0.035, 0.032), spec.metal)
    s.box((0.05, 0.155 * b, hip_z + 0.02), (0.055, 0.03, 0.065), spec.leather, round_=0.02)
    # leather bodice
    s.ellipsoid(chest + fwd * 0.035 - up * 0.07, (0.105 * b, 0.15 * b, 0.125), spec.leather)
    # neck, head, face
    neck, head = J["neck"], J["head"]
    s.capsule(neck - up * 0.03, neck + up * 0.08, 0.05, spec.skin, blend=BODY)
    s.ellipsoid(head, pr.head_r, spec.skin)
    s.ellipsoid(head + np.array([0.03, 0, -0.085]), (0.07, 0.065, 0.05), spec.skin)          # jaw
    s.sphere(head + np.array([0.108, 0.04, 0.018]), 0.016, spec.eye)
    s.sphere(head + np.array([0.108, -0.04, 0.018]), 0.016, spec.eye)
    s.sphere(head + np.array([0.122, 0.0, -0.03]), 0.02, spec.skin)                          # nose
    if spec.hood is not None:
        s.ellipsoid(head + np.array([-0.025, 0, 0.03]), (0.135, 0.125, 0.15), spec.hood, displace=(0.01, 14.0, 3))
        s.capsule(head + np.array([-0.06, 0, 0.13]), head + np.array([-0.13, 0, 0.17]), 0.05, spec.hood, rb=0.015)
        s.ellipsoid(head + np.array([0.06, 0, -0.07]), (0.065, 0.1, 0.045), spec.hood)        # face scarf
        s.capsule(head + np.array([-0.1, 0, -0.08]), chest + np.array([-0.14, 0, 0.12]), 0.07, spec.hood)
    if spec.hair is not None:
        # curls are geometry (displaced lobes), so they shade in clean tones and
        # look the same from every side
        for i, (x, y, z, r) in enumerate(HAIR_LOBES):
            back = x <= 0
            s.sphere(head + np.array([x * (1.0 if back else 0.9) - (0.01 if back else 0.0), y * 0.98, z * 0.95]),
                     r * (0.95 if back else 0.82), spec.hair, displace=(0.03, 30.0, 50 + i))
    # cloak: narrow at the shoulders, wider at a square hem, trailing with speed
    if spec.cloak is not None:
        top = chest - fwd * (0.13 * b + 0.02) + up * 0.13
        hem_z = 0.34 + pose.hip_drop
        # two panels: the upper one lies along the back, the lower one swings out
        # behind with speed, so the cloak bends instead of pivoting like a board
        midp = top - up * (top[2] - hem_z) * 0.5 - fwd * (0.07 + pose.cloak_sway * 0.5)
        bot = np.array([midp[0] - 0.05 - pose.cloak_sway * 1.6, 0.0, hem_z + pose.cloak_sway * 0.5])
        for (p0_, p1_, w0, last) in ((top, midp, 0.175, False), (midp, bot, 0.215, True)):
            d = p1_ - p0_
            L = np.linalg.norm(d)
            Rc = rot_axis_mat((0, 1, 0), -np.arctan2(-d[0], -d[2]))
            c = (p0_ + p1_) / 2
            s.box((0, 0, 0), (0.03, w0, L / 2 + 0.02), spec.cloak, round_=0.025, T=c, R=Rc, blend=(2, 0.05))
            # drapery: shallow folds running down the cloth, part of the same
            # smooth surface, so the back of the figure is not a flat board
            for fy in (-0.6, 0.0, 0.6):
                s.capsule((-0.022, fy * w0, L / 2), (-0.03, fy * w0 * 1.15, -L / 2 + 0.03), 0.03, spec.cloak,
                          rb=0.042, T=c, R=Rc, blend=(2, 0.05))
            if last and spec.cloak_trim is not None:
                s.box((0, 0, -L / 2 + 0.015), (0.036, w0 + 0.005, 0.026), spec.cloak_trim, round_=0.012, T=c, R=Rc)
        s.capsule(top + np.array([0.05, 0.21, 0]), top + np.array([0.05, -0.21, 0]), 0.06, spec.cloak)
        s.sphere(chest + fwd * 0.13 + up * 0.15, 0.03, spec.metal)                            # clasp
    # arms: shoulder cap, sleeve, bracer, hand
    for k, side in (("L", 1), ("R", -1)):
        sh, elbow, hand = J["sh" + k], J["elbow" + k], J["hand" + k]
        s.ellipsoid(sh + np.array([0, side * 0.01, 0.015]), (0.08, 0.075, 0.062), spec.leather)
        s.capsule(sh, elbow, 0.058 * b, spec.sleeve, rb=0.046 * b, blend=BODY)
        s.capsule(elbow, hand, 0.05 * b, spec.leather, rb=0.036 * b, blend=BODY)
        s.ellipsoid(hand + np.array([0, 0, -0.012]), (0.036, 0.03, 0.045), spec.skin)
    # weapon: always attached at the hand joint, so it cannot drift between facings
    lhand, rhand = J["handL"], J["handR"]
    if weapon == "hunting_bow" and add_bow:
        shooting = pose.bow_draw >= 0
        f = np.array([1.0, 0.0, 0.0]) if shooting else np.array([0.6, 0.0, -0.8])
        u = np.array([0.0, 0.25, 1.0]) if shooting else np.array([0.8, 0.0, 0.6])
        add_bow(s, lhand, u, f, max(pose.bow_draw, 0.0))
        anchors["blade_base"] = lhand
        anchors["blade_tip"] = lhand + f * 0.5
    else:
        bd = np.asarray(pose.blade if pose.blade is not None else (0.62, -0.18, -0.52), float)
        bd = bd / np.linalg.norm(bd)
        if weapon in ("iron_sword", "lightning_sword", "rusty_dagger") and add_sword:
            hilt, tip = add_sword(s, rhand, bd, magic=weapon == "lightning_sword", blade_mat=blade_mat)
        else:
            hilt = rhand + bd * 0.07
            tip = hilt + bd * 0.74
        anchors["blade_base"] = hilt
        anchors["blade_tip"] = tip
    anchors["head"] = head + np.array([0, 0, 0.2])
    return s, anchors


HAIR_LOBES = [(-0.05, 0, 0.06, 0.15), (-0.02, 0, 0.11, 0.13), (-0.1, 0.0, -0.02, 0.13),
              (-0.04, 0.12, 0.02, 0.11), (-0.04, -0.12, 0.02, 0.11), (0.04, 0.1, 0.08, 0.09),
              (0.04, -0.1, 0.08, 0.09), (-0.09, 0.1, -0.1, 0.1), (-0.09, -0.1, -0.1, 0.1),
              (-0.12, 0.0, -0.14, 0.11), (-0.06, 0.15, -0.14, 0.08), (-0.06, -0.15, -0.14, 0.08),
              (0.07, 0.0, 0.12, 0.08)]
