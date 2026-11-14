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
        t1 = (bmin[None, :] - p0) / SUN[None, :]
        t2 = (bmax[None, :] - p0) / SUN[None, :]
        lo_ = np.max(np.minimum(t1, t2), axis=1)
        hi_ = np.min(np.maximum(t1, t2), axis=1)
        sc = np.nonzero(hi_ > np.maximum(lo_, 0.0))[0]
        if sc.size:
            gshadow[sc] = sdf.k_ground_shadow(recs, np.ascontiguousarray(p0[sc]), SUN, 8.0, 14.0)

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
