"""Stone-and-timber cottage.  Footprint x:[0,FW] y:[0,FD], origin = back corner."""
import numpy as np

from sdf import Scene, rot_axis_mat
from materials import Material, ramp, wood_grain, _c
from noise import fbm3, value3, hash01

FW, FD = 3.0, 4.5          # footprint (tiles): long wall faces +x (door side)
WALL_T = 0.18              # wall thickness (interior is hollow and walkable)
DOOR_Y = 2.55              # doorway centre along the +x wall
DOOR_HALF_W = 0.42
WALL_H = 2.35
RIDGE_H = 4.05
STONE_TOP = 1.2


def masonry(p, n, row_h=0.19, seed=11):
    """Irregular coursed stonework on vertical faces. Returns colour (N,3)."""
    use_y = np.abs(n[:, 0]) > np.abs(n[:, 1])
    u = np.where(use_y, p[:, 1], p[:, 0])
    v = p[:, 2]
    row = np.floor(v / row_h)
    off = hash01(row, seed=seed) * 2.0
    blen = 0.2 + hash01(row, seed=seed + 1) * 0.3
    cu = (u + off) / blen
    col = np.floor(cu)
    fu = cu - col
    fv = v / row_h - row
    jag = (fbm3(p, 24, 2, seed + 9) - 0.5) * 0.25
    fu = np.clip(fu + jag, 0, 1)
    fv = np.clip(fv + jag * 0.8, 0, 1)
    cid = hash01(row, col, seed=seed + 2)
    warm = hash01(row, col, seed=seed + 3)
    base = ramp(0.25 + cid * 0.6 + (fbm3(p, 9, 2, seed) - 0.5) * 0.5,
                ["#56534f", "#77736c", "#8f8a80", "#a9a397"])
    tint = np.where(warm[:, None] > 0.6, np.array([1.05, 0.98, 0.9]), np.array([0.95, 0.98, 1.04]))
    c = base * tint
    # bevel shading + mortar joints
    eu = np.minimum(fu, 1 - fu) * blen[:]
    ev = np.minimum(fv, 1 - fv) * row_h
    e = np.minimum(eu, ev)
    c = c * np.clip(0.55 + e * 14.0, 0.55, 1.0)[:, None]
    mortar = e < 0.018
    c[mortar] = _c("#2a2622") * (0.9 + 0.2 * cid[mortar, None])
    return c


def timber_plaster(p, n, posts=0.75):
    use_y = np.abs(n[:, 0]) > np.abs(n[:, 1])
    u = np.where(use_y, p[:, 1], p[:, 0])
    z = p[:, 2]
    plaster = ramp(fbm3(p, 7, 3, 21), ["#a89a7c", "#bfb293", "#cfc4a7"])
    wood = wood_grain(["#2c1c10", "#45301d", "#5c4129"], axis=2, seed=5).albedo(p, n)
    beam = (np.abs(z - (STONE_TOP + 0.05)) < 0.07) | (np.abs(z - WALL_H + 0.06) < 0.07)
    pu = np.mod(u + 0.06, posts)
    beam |= pu < 0.12
    # diagonal braces in each bay
    bay_u = pu / posts
    bz = (z - STONE_TOP) / (WALL_H - STONE_TOP)
    beam |= (np.abs(bay_u - bz) < 0.09) & (np.floor((u + 0.06) / posts) % 2 == 0)
    beam |= (np.abs((1 - bay_u) - bz) < 0.09) & (np.floor((u + 0.06) / posts) % 2 == 1)
    return np.where(beam[:, None], wood, plaster)


def wall_material():
    def f(p, n):
        stone = masonry(p, n)
        upper = timber_plaster(p, n)
        top = n[:, 2] > 0.7
        c = np.where((p[:, 2] < STONE_TOP)[:, None], stone, upper)
        c[top] = _c("#4a3a2a")
        return c
    return Material(f, 0.12, 30.0, seed=2)


def gable_material():
    def f(p, n):
        plaster = ramp(fbm3(p, 7, 3, 21), ["#a89a7c", "#bfb293", "#cfc4a7"])
        wood = wood_grain(["#2c1c10", "#45301d", "#5c4129"], axis=2, seed=5).albedo(p, n)
        z = p[:, 2]
        xc = FW / 2
        dx = p[:, 0] - xc
        beam = (np.abs(dx) < 0.07) | (np.abs(z - (WALL_H + 0.75)) < 0.06)
        beam |= (np.abs(np.abs(dx) - 0.75) < 0.06) & (z < WALL_H + 0.75)
        # diagonal struts
        beam |= (np.abs(np.abs(dx) - (z - WALL_H) * 0.9) < 0.06) & (z < WALL_H + 0.75)
        return np.where(beam[:, None], wood, plaster)
    return Material(f, 0.1, 30.0)


def roof_material(seed=31):
    def f(p, n):
        side = np.sign(p[:, 0] - FW / 2)
        dist = np.abs(p[:, 0] - FW / 2)
        row = np.floor(dist / 0.205)
        tw = 0.24
        cu = (p[:, 1] + (row % 2) * tw * 0.5) / tw
        col = np.floor(cu)
        fu = cu - col
        h = hash01(row, col, side, seed=seed)
        c = ramp(0.2 + 0.65 * h + (fbm3(p, 6, 2, seed) - 0.5) * 0.4,
                 ["#4a2618", "#663523", "#7a442c", "#8c5436", "#9c6442"])
        edge = np.minimum(fu, 1 - fu)
        c = c * np.where(edge[:, None] < 0.06, 0.45, 1.0)
        # moss/age streaks
        moss = np.clip((fbm3(p, 3, 2, seed + 7) - 0.62) * 3.0, 0, 1)
        c = c * (1 - moss[:, None] * 0.35) + _c("#5c5a2c")[None, :] * moss[:, None] * 0.35
        return c
    return Material(f, 0.18, 24.0, seed=seed)


def window_material():
    glass = _c("#f6c45a")

    def alb(p, n):
        use_y = np.abs(n[:, 0]) > np.abs(n[:, 1])
        u = np.where(use_y, p[:, 1], p[:, 0])
        z = p[:, 2]
        lat = (np.abs(np.mod(u + z, 0.16) - 0.08) < 0.016) | (np.abs(np.mod(u - z, 0.16) - 0.08) < 0.016)
        return np.where(lat[:, None], _c("#2a1a0e"), glass * 0.35)

    def emi(p, n):
        a = alb(p, n)
        lit = a[:, 0] > 0.2
        g = np.where(lit[:, None], _c("#ffcf6a") * (0.55 + 0.35 * fbm3(p, 6, 2, 4))[:, None], 0.0)
        return g
    return Material(alb, emissive=emi)


def door_material():
    def f(p, n):
        w = wood_grain(["#3b2414", "#5a3820", "#6f4a2b"], axis=2, seed=8).albedo(p, n)
        plank = np.abs(np.mod(p[:, 1], 0.2) - 0.1) > 0.088
        brace = np.abs(p[:, 2] - 0.5) < 0.05
        brace |= np.abs(p[:, 2] - 1.45) < 0.05
        w = np.where(plank[:, None], w * 0.45, w)
        w = np.where(brace[:, None], w * 0.75, w)
        return w
    return Material(f, 0.1, 30.0)


TIMBER = wood_grain(["#2c1c10", "#45301d", "#5c4129"], axis=0, seed=9, bump_s=0.15)
STONE_BLOCK = Material(lambda p, n: masonry(p, n, row_h=0.17, seed=4) * 1.05, 0.15, 30.0)


def flowerbox(s, c, along="y", length=0.7, seed=1):
    c = np.asarray(c, float)
    half = (0.11, length / 2, 0.07) if along == "y" else (length / 2, 0.11, 0.07)
    s.box(c, half, TIMBER, round_=0.01)
    rng = np.random.default_rng(seed)
    leaves = Material(lambda p, n: ramp(value3(p[:, 0] * 40, p[:, 1] * 40, p[:, 2] * 40, 3), ["#1e3b10", "#3a6a1c", "#5d8f2a"]), 0.4, 30)
    red = Material(lambda p, n: ramp(value3(p[:, 0] * 60, p[:, 1] * 60, p[:, 2] * 60, 5), ["#8e1410", "#d0281c", "#f0503a"]))
    for i in range(9):
        t = (i + 0.5) / 9 - 0.5
        o = np.array([0, t * length, 0]) if along == "y" else np.array([t * length, 0, 0])
        q = c + o + np.array([0, 0, 0.12])
        s.sphere(q, 0.07, leaves, displace=(0.02, 25, seed + i))
        if rng.uniform() < 0.75:
            s.sphere(q + rng.uniform(-0.04, 0.04, 3) + np.array([0, 0, 0.05]), 0.04, red)


def cottage():
    s = Scene()
    wm_ = wall_material()
    t = WALL_T
    s.box((FW - t / 2, FD / 2, WALL_H / 2), (t / 2, FD / 2, WALL_H / 2), wm_)      # door wall (+x)
    s.box((t / 2, FD / 2, WALL_H / 2), (t / 2, FD / 2, WALL_H / 2), wm_)           # back wall (-x)
    s.box((FW / 2, FD - t / 2, WALL_H / 2), (FW / 2, t / 2, WALL_H / 2), wm_)      # gable wall (+y)
    s.box((FW / 2, t / 2, WALL_H / 2), (FW / 2, t / 2, WALL_H / 2), wm_)           # chimney wall (-y)
    # plank floor inside (visible through the doorway / when the cottage fades)
    floor = wood_grain(["#2a1a0e", "#3e2816", "#523620"], axis=1, seed=23)
    s.box((FW / 2, FD / 2, 0.015), (FW / 2 - t, FD / 2 - t, 0.015), floor)
    # loft floor closes the interior under the gable so the roof reads solid
    s.box((FW / 2, FD / 2, WALL_H - 0.05), (FW / 2, FD / 2, 0.05), wm_)
    # corner posts / sill beam
    for x in (0.0, FW):
        for y in (0.0, FD):
            s.box((x, y, (STONE_TOP + WALL_H) / 2), (0.07, 0.07, (WALL_H - STONE_TOP) / 2 + 0.02), TIMBER)
    # gable triangles (ridge along y)
    gm = gable_material()
    s.gable((FW / 2, FD / 2, 0), FD / 2, FW / 2, WALL_H, RIDGE_H - 0.12, gm, axis="y")
    # roof: rows of tilted shingle slabs, each tipped so its lower edge steps out
    half_w = FW / 2 + 0.38
    rise = RIDGE_H - WALL_H + 0.3
    ang = np.arctan2(rise, half_w)
    slope_len = np.hypot(rise, half_w)
    rm = roof_material()
    rows = 10
    for side in (-1, 1):
        for r in range(rows):
            s0 = slope_len * r / rows
            s1 = slope_len * (r + 1.25) / rows
            sm = (s0 + s1) / 2
            hx = half_w - sm * np.cos(ang)
            z = WALL_H - 0.3 + sm * np.sin(ang) + 0.06
            tilt = ang + np.radians(4.0)
            R = rot_axis_mat((0, 1, 0), side * tilt)
            s.box((0, 0, 0), ((s1 - s0) / 2, FD / 2 + 0.3, 0.045), rm,
                  T=(FW / 2 + side * hx, FD / 2, z), R=R)
    # ridge cap
    s.cyl_axis((FW / 2, -0.32, RIDGE_H + 0.1), (FW / 2, FD + 0.32, RIDGE_H + 0.1), 0.09, rm)
    # bargeboards along the gable verges
    for y in (-0.31, FD + 0.31):
        for side in (-1, 1):
            a = (FW / 2 + side * (half_w + 0.02), y, WALL_H - 0.28)
            b = (FW / 2, y, RIDGE_H + 0.08)
            s.capsule(a, b, 0.05, TIMBER)
    # chimney at back gable (y=0 end), stone
    s.box((FW * 0.5, 0.35, (RIDGE_H + 0.75) / 2), (0.28, 0.28, (RIDGE_H + 0.75) / 2), STONE_BLOCK)
    s.box((FW * 0.5, 0.35, RIDGE_H + 0.78), (0.32, 0.32, 0.06), STONE_BLOCK)
    # door frame on +x wall; the leaf itself is a separate interactive sprite (door())
    s.box((FW + 0.03, DOOR_Y - 0.46, 1.0), (0.05, 0.05, 1.0), TIMBER)
    s.box((FW + 0.03, DOOR_Y + 0.46, 1.0), (0.05, 0.05, 1.0), TIMBER)
    s.box((FW + 0.03, DOOR_Y, 1.95), (0.05, 0.51, 0.06), TIMBER)
    s.carve_box((FW - 0.1, DOOR_Y, 0.95), (0.25, DOOR_HALF_W, 0.95))
    # step
    s.box((FW + 0.32, 2.55, 0.09), (0.3, 0.55, 0.09), STONE_BLOCK, round_=0.02)
    # windows with frames and flower boxes
    wm = window_material()
    for y in (1.15, 3.85):
        s.box((FW + 0.02, y, 1.45), (0.04, 0.36, 0.42), TIMBER)
        s.box((FW + 0.04, y, 1.45), (0.04, 0.28, 0.34), wm)
        flowerbox(s, (FW + 0.14, y, 0.98), "y", 0.7, seed=int(y * 10))
    # gable-end window (faces +y)
    s.box((FW / 2, FD + 0.02, 1.45), (0.36, 0.04, 0.42), TIMBER)
    s.box((FW / 2, FD + 0.04, 1.45), (0.28, 0.04, 0.34), wm)
    flowerbox(s, (FW / 2, FD + 0.14, 0.98), "x", 0.7, seed=7)
    anchors = {"chimney_top": (FW * 0.5, 0.35, RIDGE_H + 0.86)}
    return s, anchors


def door_material2():
    """Plank door whose grain follows the leaf even when it swings open."""
    def f(p, n):
        along_y = np.abs(n[:, 0]) > np.abs(n[:, 1])
        u = np.where(along_y, p[:, 1], p[:, 0])
        w = wood_grain(["#3b2414", "#5a3820", "#6f4a2b"], axis=2, seed=8).albedo(p, n)
        plank = np.abs(np.mod(u, 0.2) - 0.1) > 0.088
        brace = (np.abs(p[:, 2] - 0.55) < 0.05) | (np.abs(p[:, 2] - 1.5) < 0.05)
        w = np.where(plank[:, None], w * 0.45, w)
        w = np.where(brace[:, None], w * 0.72, w)
        return w
    return Material(f, 0.1, 30.0)


DOOR_MAT = None
IRON_DARK = Material(_c("#2a2a2e"))


def door(open_frac=0.0):
    """Door leaf in door-anchor space. Anchor = cottage-local (FW + 0.06, DOOR_Y).
    Hinged at the -y edge; opens outward (toward +x) by open_frac * 90 deg."""
    global DOOR_MAT
    if DOOR_MAT is None:
        DOOR_MAT = door_material2()
    s = Scene()
    hinge = np.array([-0.09, -0.39, 0.0])
    R = rot_axis_mat((0, 0, 1), -np.pi / 2 * open_frac)
    s.box((0.0, 0.39, 1.03), (0.03, 0.39, 0.83), DOOR_MAT, T=hinge, R=R)
    s.torus_z((0, 0, 0), 0.055, 0.012, IRON_DARK, T=hinge + R @ np.array([0.04, 0.62, 1.0]),
              R=R @ rot_axis_mat((0, 1, 0), np.pi / 2))
    for z in (0.5, 1.5):  # strap hinges
        s.box((0.035, 0.15, z), (0.008, 0.15, 0.03), IRON_DARK, T=hinge, R=R)
    return s



DOOR_ANCHOR = (FW + 0.06, DOOR_Y)


def chest_material():
    def f(p, n):
        along_y = np.abs(n[:, 0]) > np.abs(n[:, 1])
        u = np.where(along_y, p[:, 1], p[:, 0])
        top = n[:, 2] > 0.6
        u = np.where(top, p[:, 1], u)
        w = wood_grain(["#4a2e18", "#6b4424", "#875a32"], axis=2, seed=19).albedo(p, n)
        plank = np.abs(np.mod(p[:, 2] + 0.02, 0.13) - 0.065) > 0.058
        w = np.where((plank & ~top)[:, None], w * 0.5, w)
        return w
    return Material(f, 0.12, 30.0)


CHEST_WOOD = chest_material()
CHEST_INSIDE = Material(_c("#1c120a"))
GOLD = Material(lambda p, n: ramp(value3(p[:, 0] * 90, p[:, 1] * 90, p[:, 2] * 90, 3), ["#8a6418", "#d8a830", "#ffe27a"]),
                emissive=lambda p, n: np.tile(_c("#3a2a00"), (p.shape[0], 1)))
BRASS_PLATE = Material(lambda p, n: ramp(fbm3(p, 30, 2, 1), ["#5a3e14", "#a07a30", "#d2b060"]), 0.1, 30)


def chest(open_frac=0.0):
    """Iron-banded wooden chest, front faces +y. Lid hinged along the back top edge."""
    s = Scene()
    L, D, H = 0.38, 0.25, 0.36
    s.box((0, 0, H / 2), (L, D, H / 2), CHEST_WOOD, round_=0.015)
    s.carve_box((0, 0, H / 2 + 0.06), (L - 0.05, D - 0.05, H / 2))
    s.box((0, 0, 0.04), (L - 0.05, D - 0.05, 0.04), CHEST_INSIDE)
    for x in (-L * 0.62, L * 0.62):
        s.box((x, 0, H / 2), (0.03, D + 0.012, H / 2 + 0.005), IRON_DARK)
    # coins glinting inside
    rng = np.random.default_rng(4)
    for i in range(10):
        c = (rng.uniform(-0.25, 0.25), rng.uniform(-0.12, 0.12), 0.11 + rng.uniform(0, 0.04))
        s.cyl((c[0], c[1]), 0.035, c[2] - 0.008, c[2] + 0.008, GOLD)
    hinge = np.array([0.0, -D, H])
    R = rot_axis_mat((1, 0, 0), np.radians(105.0) * open_frac)
    s.box((0, D, 0.07), (L + 0.01, D + 0.005, 0.07), CHEST_WOOD, round_=0.05, T=hinge, R=R)
    for x in (-L * 0.62, L * 0.62):
        s.box((x, D, 0.075), (0.03, D + 0.015, 0.075), IRON_DARK, round_=0.04, T=hinge, R=R)
    s.box((0, 2 * D + 0.012, 0.0), (0.06, 0.012, 0.07), BRASS_PLATE, T=hinge, R=R)
    return s
