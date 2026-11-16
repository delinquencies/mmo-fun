"""Orthographic isometric SDF pre-renderer.

Camera contract (must match game/scripts/core/iso.gd):
  * orthographic, 30 deg elevation, 45 deg azimuth  -> exact 2:1 ground diamond
  * tile_w px wide diamond per 1x1 world tile, tile_h = tile_w / 2
  * screen_x = (x - y) * tile_w / 2
  * screen_y = (x + y) * tile_w / 4 - z * (tile_w / sqrt(2)) * cos(30deg)
"""
import numpy as np
from PIL import Image

import sdf

SQ2 = np.sqrt(2.0)
COS30 = np.cos(np.radians(30.0))
SIN30 = 0.5
# unit vector pointing from the scene toward the camera
TOWARD_CAM = np.array([COS30 / SQ2, COS30 / SQ2, SIN30])
# unit vector pointing toward the sun: from screen-left, slightly toward the viewer
SUN = np.array([0.32, 0.95, 1.25])
SUN = SUN / np.linalg.norm(SUN)
# Ground shadows are cast from a steeper sun than the one used for shading, so
# they sit under their object as a compact pool (as in the approved reference)
# instead of stretching a tile and a half across the grass.
SHADOW_SUN = np.array([0.2, 0.6, 1.9])
SHADOW_SUN = SHADOW_SUN / np.linalg.norm(SHADOW_SUN)
SUN_COL = np.array([1.08, 1.0, 0.86])
SKY_COL = np.array([0.50, 0.56, 0.66])
BOUNCE_COL = np.array([0.36, 0.34, 0.24])
OUTLINE_COL = np.array([0.10, 0.075, 0.06])


def project(p, tile_w):
    """World (N,3) -> screen px (N,2), origin at world (0,0,0)."""
    p = np.atleast_2d(np.asarray(p, float))
    sx = (p[:, 0] - p[:, 1]) * tile_w / 2.0
    sy = (p[:, 0] + p[:, 1]) * tile_w / 4.0 - p[:, 2] * tile_w / SQ2 * COS30
    return np.stack([sx, sy], axis=1)


def canvas_for(bmin, bmax, tile_w, with_shadow=True, pad=3):
    corners = np.array([[x, y, z] for x in (bmin[0], bmax[0])
                        for y in (bmin[1], bmax[1]) for z in (bmin[2], bmax[2])])
    pts = [corners]
    if with_shadow:
        g = corners - SUN[None, :] * (corners[:, 2:3] / SUN[2])
        pts.append(g)
    s = project(np.concatenate(pts), tile_w)
    x0 = int(np.floor(s[:, 0].min())) - pad
    y0 = int(np.floor(s[:, 1].min())) - pad
    x1 = int(np.ceil(s[:, 0].max())) + pad
    y1 = int(np.ceil(s[:, 1].max())) + pad
    return x0, y0, x1 - x0, y1 - y0


class Render:
    """Result of rendering one scene at one resolution."""

    def __init__(self, rgba, shadow, pivot, depth, tile_w, origin):
        self.rgba = rgba          # uint8 (H,W,4)
        self.shadow = shadow      # bool (H,W)
        self.pivot = pivot        # (px, py) of world origin inside the canvas
        self.depth = depth        # float (H,W), larger = nearer camera, nan = empty
        self.tile_w = tile_w
        self.origin = origin      # canvas top-left in screen px

    def to_canvas(self, world_pts):
        s = project(world_pts, self.tile_w)
        return s - np.asarray(self.origin)[None, :]

    def size(self):
        return self.rgba.shape[1], self.rgba.shape[0]


def _ray_box(p0, bmin, bmax):
    u = TOWARD_CAM
    t1 = (bmin[None, :] - p0) / u[None, :]
    t2 = (bmax[None, :] - p0) / u[None, :]
    tlo = np.max(np.minimum(t1, t2), axis=1)
    thi = np.min(np.maximum(t1, t2), axis=1)
    tlo = np.maximum(tlo, 0.0)
    return tlo, thi


def render(scene, tile_w, ss=3, canvas=None, outline=True, shadow=True,
           max_steps=200, quantize=True, light_scale=1.0, mask_materials=None):
    """mask_materials: optional list of Material objects; the result's `mask`
    marks native pixels whose visible surface belongs to them (used to cut a
    weapon layer out of a full-character render with correct occlusion)."""
    recs = scene.array()
    bmin, bmax = scene.bounds()
    if canvas is None:
        canvas = canvas_for(bmin, bmax, tile_w, with_shadow=shadow)
    ox, oy, cw, ch = canvas
    H, W = ch * ss, cw * ss
    jj, ii = np.mgrid[0:H, 0:W]
    sx = (ox + (ii + 0.5) / ss).ravel()
    sy = (oy + (jj + 0.5) / ss).ravel()
    gx = (sx * 2.0 / tile_w + sy * 4.0 / tile_w) * 0.5
    gy = (sy * 4.0 / tile_w - sx * 2.0 / tile_w) * 0.5
    p0 = np.ascontiguousarray(np.stack([gx, gy, np.zeros_like(gx)], axis=1))

    k_ss = tile_w / SQ2 * ss
    eps = 0.3 / k_ss
    tlo, thi = _ray_box(p0, bmin, bmax)
    cand = np.nonzero(thi > tlo)[0]
    t, hit = sdf.k_march(recs, np.ascontiguousarray(p0[cand]), TOWARD_CAM,
                         np.ascontiguousarray(tlo[cand]), np.ascontiguousarray(thi[cand]),
                         eps, max_steps)
    npx = H * W
    color = np.zeros((npx, 3))
    cover = np.zeros(npx)
    depth = np.full(npx, np.nan)
    hid = cand[hit]
    msub = np.zeros(npx)
    if hid.size:
        th = t[hit]
        p = np.ascontiguousarray(p0[hid] + TOWARD_CAM[None, :] * th[:, None])
        n, rec_i, ao, sh = sdf.k_shade_geom(recs, p, 0.7 / k_ss, SUN)
        mat = recs[rec_i, 1].astype(int)
        if mask_materials:
            ids = [i for i, m in enumerate(scene.materials) if any(m is mm for mm in mask_materials)]
            msub[hid] = np.isin(mat, ids).astype(float)
        alb = np.zeros((hid.size, 3))
        emi = np.zeros((hid.size, 3))
        nn = n.copy()
        for mi in np.unique(mat):
            sel = mat == mi
            a, nbm, e = scene.materials[mi].shade(p[sel], n[sel])
            alb[sel] = a
            nn[sel] = nbm
            if e is not None:
                emi[sel] = e
        diff = np.clip(nn @ SUN, 0.0, 1.0)
        hemi = 0.5 + 0.5 * nn[:, 2]
        amb = SKY_COL[None, :] * hemi[:, None] + BOUNCE_COL[None, :] * (1 - hemi[:, None])
        lit = alb * (amb * (0.30 + 0.70 * ao[:, None])
                     + SUN_COL[None, :] * (diff * sh)[:, None] * 0.92 * light_scale)
        lit += alb * 0.06 * (1 - diff)[:, None] * ao[:, None]
        color[hid] = lit + emi
        cover[hid] = 1.0
        depth[hid] = th

    gshadow = np.zeros(npx)
    if shadow:
        t1 = (bmin[None, :] - p0) / SHADOW_SUN[None, :]
        t2 = (bmax[None, :] - p0) / SHADOW_SUN[None, :]
        lo_ = np.max(np.minimum(t1, t2), axis=1)
        hi_ = np.min(np.maximum(t1, t2), axis=1)
        sc = np.nonzero(hi_ > np.maximum(lo_, 0.0))[0]
        if sc.size:
            gshadow[sc] = sdf.k_ground_shadow(recs, np.ascontiguousarray(p0[sc]), SHADOW_SUN, 8.0, 14.0)

    def down(a):
        return a.reshape(ch, ss, cw, ss, *a.shape[2:]).mean(axis=(1, 3))

    color = color.reshape(H, W, 3)
    cover2 = cover.reshape(H, W)
    csum = down(color * cover2[..., None])
    cov = down(cover2)
    rgb = csum / np.maximum(cov[..., None], 1e-6)
    alpha = cov >= 0.5
    dep = depth.reshape(H, W)
    dnat = np.where(np.isnan(dep), -1e9, dep).reshape(ch, ss, cw, ss).max(axis=(1, 3))
    dnat = np.where(alpha, dnat, np.nan)

    if outline:
        rgb = _outline(rgb, alpha, dnat)
    rgb = np.clip(rgb, 0.0, 1.0)
    if quantize:
        rgb = np.round(rgb * 31.0) / 31.0
    rgba = np.zeros((ch, cw, 4), np.uint8)
    rgba[..., :3] = (rgb * 255.0 + 0.5).astype(np.uint8)
    rgba[..., 3] = np.where(alpha, 255, 0)
    rgba[~alpha, :3] = 0
    gs = down(gshadow.reshape(H, W)) > 0.45
    out = Render(rgba, gs, (-ox, -oy), dnat, tile_w, (ox, oy))
    out.mask = (down(msub.reshape(H, W)) >= 0.5) & alpha
    return out


# --- sprite finishing ------------------------------------------------------------
# Characters are not rendered like scenery. A small figure averaged down from a
# noisy, continuously shaded render turns to mud; here each native pixel gets
# exactly one tone from its material's ramp.
FILL = np.array([0.95, -0.25, 0.3])
FILL = FILL / np.linalg.norm(FILL)                 # cool fill from screen right
RIM = np.array([-0.55, -0.55, 0.62])
RIM = RIM / np.linalg.norm(RIM)                    # back light: lifts the far silhouette edge
HALF = (SUN + TOWARD_CAM) / np.linalg.norm(SUN + TOWARD_CAM)
SPRITE_SS = 4


def _bands(light, n):
    """Light value 0..1 -> tone index 0..n-1 (fixed thresholds, no dithering)."""
    edges = 0.14 + 0.6 * (np.arange(1, n) / n) ** 1.05
    return np.searchsorted(edges, light).astype(np.int64)


def render_sprite(scene, tile_w, canvas=None, shadow=True, max_steps=200, mask_materials=None, ss=SPRITE_SS):
    """Render a character frame as finished pixel art. Same camera, canvas and
    pivot as render(); differs in lighting (key, fill, rim, occlusion), in
    shading (per-material tone ramps) and in how subsamples become pixels
    (majority vote per pixel, then selective outlines) - never averaging."""
    from materials import PaletteMaterial, auto_ramp
    recs = scene.array()
    bmin, bmax = scene.bounds()
    if canvas is None:
        canvas = canvas_for(bmin, bmax, tile_w, with_shadow=shadow)
    ox, oy, cw, ch = canvas
    H, W = ch * ss, cw * ss
    jj, ii = np.mgrid[0:H, 0:W]
    sx = (ox + (ii + 0.5) / ss).ravel()
    sy = (oy + (jj + 0.5) / ss).ravel()
    gx = (sx * 2.0 / tile_w + sy * 4.0 / tile_w) * 0.5
    gy = (sy * 4.0 / tile_w - sx * 2.0 / tile_w) * 0.5
    p0 = np.ascontiguousarray(np.stack([gx, gy, np.zeros_like(gx)], axis=1))
    k_ss = tile_w / SQ2 * ss
    eps = 0.3 / k_ss
    tlo, thi = _ray_box(p0, bmin, bmax)
    cand = np.nonzero(thi > tlo)[0]
    t, hit = sdf.k_march(recs, np.ascontiguousarray(p0[cand]), TOWARD_CAM,
                         np.ascontiguousarray(tlo[cand]), np.ascontiguousarray(thi[cand]), eps, max_steps)
    npx = H * W
    NB = 8                                     # tone slots per material in the pixel code
    code = np.full(npx, -1, np.int64)          # material * NB + tone
    depth = np.full(npx, np.nan)
    hid = cand[hit]
    mats = scene.materials
    ramps = [None] * len(mats)
    if hid.size:
        th = t[hit]
        p = np.ascontiguousarray(p0[hid] + TOWARD_CAM[None, :] * th[:, None])
        n, rec_i, ao, sh = sdf.k_shade_geom(recs, p, 0.9 / k_ss, SUN)
        mat = recs[rec_i, 1].astype(int)
        key = np.clip(n @ SUN, 0.0, 1.0) * sh
        fill = np.clip(n @ FILL, 0.0, 1.0)
        up = 0.5 + 0.5 * n[:, 2]
        facing = np.clip(n @ TOWARD_CAM, 0.0, 1.0)
        rim = np.clip(n @ RIM, 0.0, 1.0) ** 2 * (1.0 - facing) * 1.6
        light = (0.24 + 0.56 * key + 0.22 * fill + 0.12 * up) * (0.62 + 0.38 * ao) + 0.2 * rim
        light = np.clip(light, 0.0, 1.0)
        blinn = np.clip(n @ HALF, 0.0, 1.0)
        tone = np.zeros(hid.size, np.int64)
        for mi in np.unique(mat):
            sel = mat == mi
            m = mats[mi]
            if isinstance(m, PaletteMaterial):
                r = m.ramp
                emi = m.emissive is not None
                spec, gloss = m.spec, m.gloss
            else:
                a, _nb, e = m.shade(p[sel], n[sel])
                r = auto_ramp(m, a, e)
                emi = e is not None
                spec, gloss = 0.0, 1.0
            ramps[mi] = r
            nt = len(r)
            b = _bands(light[sel], nt)
            if spec > 0:
                b = np.where(blinn[sel] ** gloss * spec * sh[sel] > 0.45, nt - 1, np.minimum(b, nt - 2))
            if emi:
                b[:] = nt - 1
            tone[sel] = b
        code[hid] = mat * NB + tone
        depth[hid] = th

    # --- subsamples -> pixels by majority vote
    c3 = code.reshape(ch, ss, cw, ss).transpose(0, 2, 1, 3).reshape(ch, cw, ss * ss)
    cov = (c3 >= 0).mean(axis=2)
    alpha = cov >= 0.5
    srt = np.sort(c3, axis=2)
    best = np.full((ch, cw), -1, np.int64)
    bestn = np.zeros((ch, cw), np.int64)
    detail_ids = [i for i, m in enumerate(mats) if getattr(m, "detail", False)]
    for u in np.unique(code):
        if u < 0:
            continue
        cnt = (c3 == u).sum(axis=2)
        w = cnt * (2.5 if (u // NB) in detail_ids else 1)       # tiny features outvote their surroundings
        better = w > bestn
        best = np.where(better, u, best)
        bestn = np.where(better, w, bestn)
    del srt
    pix = np.where(alpha, best, -1)
    dep = depth.reshape(H, W)
    dnat = np.where(np.isnan(dep), -1e9, dep).reshape(ch, ss, cw, ss).max(axis=(1, 3))
    dnat = np.where(alpha, dnat, np.nan)

    pix = _despeckle(pix, NB, detail_ids)
    pix_mat = np.where(pix >= 0, pix // NB, -1)
    pix_tone = np.where(pix >= 0, pix % NB, 0)
    pix_tone, edge = _sprite_lines(pix_mat, pix_tone, dnat, alpha, detail_ids)
    glow = [i for i, m in enumerate(mats) if m.emissive is not None or getattr(m, "no_outline", False)]
    if glow:
        edge &= ~np.isin(pix_mat, glow)          # glowing blades are never outlined dark

    rgb = np.zeros((ch, cw, 3))
    for mi, r in enumerate(ramps):
        if r is None:
            continue
        sel = pix_mat == mi
        if sel.any():
            rgb[sel] = r[np.minimum(pix_tone[sel], len(r) - 1)]
            e = sel & edge
            # silhouette line: the material's own darkest tone, deepened - a coloured
            # outline, not a black one
            rgb[e] = np.where((pix_tone[e] >= len(r) - 2)[:, None], r[1], r[0] * 0.8 + r[1] * 0.2)
    rgba = np.zeros((ch, cw, 4), np.uint8)
    rgba[..., :3] = (np.clip(rgb, 0, 1) * 255.0 + 0.5).astype(np.uint8)
    rgba[..., 3] = np.where(alpha, 255, 0)
    rgba[~alpha, :3] = 0

    gshadow = np.zeros(npx)
    if shadow:
        t1 = (bmin[None, :] - p0) / SHADOW_SUN[None, :]
        t2 = (bmax[None, :] - p0) / SHADOW_SUN[None, :]
        lo_ = np.max(np.minimum(t1, t2), axis=1)
        hi_ = np.min(np.maximum(t1, t2), axis=1)
        sc = np.nonzero(hi_ > np.maximum(lo_, 0.0))[0]
        if sc.size:
            gshadow[sc] = sdf.k_ground_shadow(recs, np.ascontiguousarray(p0[sc]), SHADOW_SUN, 8.0, 14.0)
    gs = gshadow.reshape(ch, ss, cw, ss).mean(axis=(1, 3)) > 0.45
    out = Render(rgba, gs, (-ox, -oy), dnat, tile_w, (ox, oy))
    if mask_materials:
        ids = [i for i, m in enumerate(mats) if any(m is mm for mm in mask_materials)]
        out.mask = np.isin(pix_mat, ids) & alpha
    else:
        out.mask = np.zeros_like(alpha)
    return out


def _neigh(a, fill):
    """The four neighbours of every pixel (up, down, left, right)."""
    H, W = a.shape
    pd = np.pad(a, 1, constant_values=fill)
    return [pd[1 + dy:1 + dy + H, 1 + dx:1 + dx + W] for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1))]


def _despeckle(pix, NB, detail_ids):
    """Remove single stray pixels: a pixel whose tone no neighbour shares, while
    three or more neighbours agree with each other on another tone of the same
    material, takes their tone. Detail materials are left alone."""
    nb = _neigh(pix, -2)
    same = sum((q == pix).astype(int) for q in nb)
    out = pix.copy()
    for q in nb:
        agree = sum((r == q).astype(int) for r in nb)
        ok = (same == 0) & (agree >= 3) & (q >= 0) & (pix >= 0) & (q // NB == pix // NB)
        out = np.where(ok, q, out)
    if detail_ids:
        keep = np.isin(pix // NB, detail_ids)
        out = np.where(keep, pix, out)
    return out


def _sprite_lines(mat, tone, depth, alpha, detail_ids):
    """Selective line work. Returns (tone, silhouette_mask).
    - silhouette: opaque pixel touching transparency
    - overlap: a pixel that sits behind a nearer neighbour (limb over body,
      cloak behind arm) drops two tones: a drawn contact line
    - seam: where two materials meet on one surface, the lower/right pixel drops
      one tone, so every seam is one consistent pixel wide"""
    dz = np.where(np.isnan(depth), -1e9, depth)
    a_nb = _neigh(alpha, False)
    edge = alpha & ~(a_nb[0] & a_nb[1] & a_nb[2] & a_nb[3])
    # features one pixel wide (blades, bowstrings) keep their own colour: an
    # outline there would replace the whole feature
    thin = (~a_nb[0] & ~a_nb[1]) | (~a_nb[2] & ~a_nb[3])
    edge &= ~thin
    d_nb = _neigh(dz, -1e9)
    m_nb = _neigh(mat, -1)
    over = np.zeros_like(alpha)
    far = np.zeros_like(alpha)
    for q in d_nb:
        over |= (q - dz) > 0.11
        far |= (q - dz) > 0.3
    over &= alpha & ~edge
    seam = np.zeros_like(alpha)
    for k in (0, 2):                         # only look up and left
        seam |= (m_nb[k] != mat) & (m_nb[k] >= 0) & (np.abs(d_nb[k] - dz) <= 0.11)
    seam &= alpha & ~edge & ~over
    if detail_ids:
        isd = np.isin(mat, detail_ids)
        over &= ~isd
        seam &= ~isd
    tone = np.where(over, np.maximum(tone - np.where(far, 2, 1), 0), tone)
    tone = np.where(seam, np.maximum(tone - 1, 0), tone)
    return tone, edge


def _outline(rgb, alpha, depth):
    H, W = alpha.shape
    pad_a = np.pad(alpha, 1, constant_values=False)
    edge = np.zeros_like(alpha)
    for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        edge |= ~pad_a[1 + dy:1 + dy + H, 1 + dx:1 + dx + W]
    edge &= alpha
    dz = np.where(np.isnan(depth), -1e9, depth)
    pad_d = np.pad(dz, 1, constant_values=-1e9)
    crease = np.zeros_like(alpha)
    for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
        nb = pad_d[1 + dy:1 + dy + H, 1 + dx:1 + dx + W]
        crease |= (nb - dz) > 0.22
    crease &= alpha & ~edge
    out = rgb.copy()
    out[edge] = out[edge] * 0.42 + OUTLINE_COL * 0.58
    out[crease] = out[crease] * 0.62 + OUTLINE_COL * 0.38
    return out


def save_rgba(arr, path):
    Image.fromarray(arr, "RGBA").save(path, optimize=True)


def shadow_rgba(mask):
    out = np.zeros(mask.shape + (4,), np.uint8)
    out[mask, 3] = 255
    return out
