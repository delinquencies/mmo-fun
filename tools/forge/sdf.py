"""Signed-distance scene description + numba-compiled evaluation kernels.

World convention (shared with the Godot runtime, see game/scripts/core/iso.gd):
  * 1 world unit == 1 ground tile edge (~1 metre).
  * +x points screen down-right, +y points screen down-left, +z is up.

A Scene is a flat list of primitive records (float64 rows).  Each record holds
a rigid transform (translation T + rotation R, world = R @ local + T), a world
bounding box for culling, an optional noise displacement, and primitive
parameters expressed in the primitive's local frame.
"""
import math

import numba as nb
import numpy as np

SPHERE, ELLIPSOID, BOX, CAPSULE, CYLZ, GABLE, CYLAX, TORUSZ = range(8)
REC = 40
P0 = 23  # first parameter slot


def rot_z_mat(a):
    c, s = math.cos(a), math.sin(a)
    return np.array([[c, -s, 0.0], [s, c, 0.0], [0.0, 0.0, 1.0]])


def rot_axis_mat(axis, a):
    axis = np.asarray(axis, float)
    axis = axis / np.linalg.norm(axis)
    x, y, z = axis
    c, s, C = math.cos(a), math.sin(a), 1 - math.cos(a)
    return np.array([[c + x * x * C, x * y * C - z * s, x * z * C + y * s],
                     [y * x * C + z * s, c + y * y * C, y * z * C - x * s],
                     [z * x * C - y * s, z * y * C + x * s, c + z * z * C]])


class Scene:
    def __init__(self):
        self.recs = []
        self.materials = []
        self._mat_ids = {}

    # -- materials -------------------------------------------------------
    def _mid(self, m):
        k = id(m)
        if k not in self._mat_ids:
            self._mat_ids[k] = len(self.materials)
            self.materials.append(m)
        return self._mat_ids[k]

    # -- generic add -----------------------------------------------------
    def _add(self, typ, mat, params, lmin, lmax, T=(0, 0, 0), R=None, displace=None):
        R = np.eye(3) if R is None else np.asarray(R, float)
        T = np.asarray(T, float)
        rec = np.zeros(REC)
        rec[0] = typ
        rec[1] = self._mid(mat)
        pad = 0.01
        if displace:
            rec[8], rec[9], rec[10] = displace
            pad += abs(displace[0]) * 1.1
        corners = np.array([[x, y, z] for x in (lmin[0], lmax[0])
                            for y in (lmin[1], lmax[1]) for z in (lmin[2], lmax[2])])
        w = corners @ R.T + T
        rec[2:5] = w.min(0) - pad
        rec[5:8] = w.max(0) + pad
        rec[11:14] = T
        rec[14:23] = R.ravel()
        rec[P0:P0 + len(params)] = params
        self.recs.append(rec)
        return self

    def sphere(self, c, r, mat, displace=None, **kw):
        c = np.asarray(c, float)
        return self._add(SPHERE, mat, [*c, r], c - r, c + r, displace=displace, **kw)

    def ellipsoid(self, c, r, mat, displace=None, **kw):
        c, r = np.asarray(c, float), np.asarray(r, float)
        return self._add(ELLIPSOID, mat, [*c, *r], c - r, c + r, displace=displace, **kw)

    def box(self, c, half, mat, round_=0.0, displace=None, **kw):
        c, h = np.asarray(c, float), np.asarray(half, float)
        return self._add(BOX, mat, [*c, *h, round_], c - h, c + h, displace=displace, **kw)

    def capsule(self, a, b, ra, mat, rb=None, displace=None, **kw):
        rb = ra if rb is None else rb
        a, b = np.asarray(a, float), np.asarray(b, float)
        r = max(ra, rb)
        return self._add(CAPSULE, mat, [*a, *b, ra, rb], np.minimum(a, b) - r,
                         np.maximum(a, b) + r, displace=displace, **kw)

    def cyl(self, c, r, h0, h1, mat, round_=0.0, displace=None, **kw):
        return self._add(CYLZ, mat, [c[0], c[1], r, h0, h1, round_],
                         (c[0] - r, c[1] - r, h0), (c[0] + r, c[1] + r, h1), displace=displace, **kw)

    def cyl_axis(self, a, b, r, mat, displace=None, **kw):
        a, b = np.asarray(a, float), np.asarray(b, float)
        return self._add(CYLAX, mat, [*a, *b, r], np.minimum(a, b) - r,
                         np.maximum(a, b) + r, displace=displace, **kw)

    def gable(self, c, half_len, half_w, h0, h1, mat, axis="x", displace=None, **kw):
        c = np.asarray(c, float)
        ax = 0.0 if axis == "x" else 1.0
        hl = np.array([half_len, half_w, 0]) if axis == "x" else np.array([half_w, half_len, 0])
        lmin = c + np.array([-hl[0], -hl[1], h0])
        lmax = c + np.array([hl[0], hl[1], h1])
        return self._add(GABLE, mat, [*c, half_len, half_w, h0, h1, ax], lmin, lmax,
                         displace=displace, **kw)

    def torus_z(self, c, R_, r, mat, **kw):
        c = np.asarray(c, float)
        e = np.array([R_ + r, R_ + r, r])
        return self._add(TORUSZ, mat, [*c, R_, r], c - e, c + e, **kw)

    # -- composition -----------------------------------------------------
    def extend(self, other, offset=(0, 0, 0), yaw=0.0, R=None):
        Rw = rot_z_mat(yaw) if R is None else np.asarray(R, float)
        off = np.asarray(offset, float)
        for rec in other.recs:
            r = rec.copy()
            r[1] = self._mid(other.materials[int(rec[1])])
            R0 = rec[14:23].reshape(3, 3)
            T0 = rec[11:14]
            r[14:23] = (Rw @ R0).ravel()
            r[11:14] = Rw @ T0 + off
            c = np.array([[x, y, z] for x in (rec[2], rec[5]) for y in (rec[3], rec[6])
                          for z in (rec[4], rec[7])]) @ Rw.T + off
            r[2:5], r[5:8] = c.min(0), c.max(0)
            self.recs.append(r)
        return self

    def array(self):
        return np.ascontiguousarray(np.array(self.recs, dtype=np.float64))

    def bounds(self):
        a = self.array()
        return a[:, 2:5].min(0), a[:, 5:8].max(0)


# ---------------------------------------------------------------------------
# numba kernels
# ---------------------------------------------------------------------------

@nb.njit(cache=True)
def _mix(h):
    h ^= h >> 16
    h = (h * 0x7FEB352D) & 0xFFFFFFFF
    h ^= h >> 15
    h = (h * 0x846CA68B) & 0xFFFFFFFF
    h ^= h >> 16
    return h


@nb.njit(cache=True)
def _hash3(x, y, z, seed):
    h = (seed * 0x9E3779B1) & 0xFFFFFFFF
    h = _mix(h ^ (((x & 0xFFFFFFFF) + 0x632BE5AB) & 0xFFFFFFFF))
    h = _mix(h ^ (((y & 0xFFFFFFFF) + 0xC657CB56) & 0xFFFFFFFF))
    h = _mix(h ^ (((z & 0xFFFFFFFF) + 0x2983B101) & 0xFFFFFFFF))
    return h / 4294967296.0


@nb.njit(cache=True)
def _vnoise(x, y, z, seed):
    xi, yi, zi = math.floor(x), math.floor(y), math.floor(z)
    fx, fy, fz = x - xi, y - yi, z - zi
    fx = fx * fx * (3 - 2 * fx)
    fy = fy * fy * (3 - 2 * fy)
    fz = fz * fz * (3 - 2 * fz)
    ix, iy, iz = int(xi), int(yi), int(zi)
    a = _hash3(ix, iy, iz, seed)
    b = _hash3(ix + 1, iy, iz, seed)
    c = _hash3(ix, iy + 1, iz, seed)
    d = _hash3(ix + 1, iy + 1, iz, seed)
    e = _hash3(ix, iy, iz + 1, seed)
    f = _hash3(ix + 1, iy, iz + 1, seed)
    g = _hash3(ix, iy + 1, iz + 1, seed)
    h = _hash3(ix + 1, iy + 1, iz + 1, seed)
    x0 = a + (b - a) * fx
    x1 = c + (d - c) * fx
    x2 = e + (f - e) * fx
    x3 = g + (h - g) * fx
    y0 = x0 + (x1 - x0) * fy
    y1 = x2 + (x3 - x2) * fy
    return y0 + (y1 - y0) * fz


@nb.njit(cache=True)
def _len3(x, y, z):
    return math.sqrt(x * x + y * y + z * z)


@nb.njit(cache=True)
def _prim(rec, x, y, z):
    # to local frame: local = R^T (p - T)
    px, py, pz = x - rec[11], y - rec[12], z - rec[13]
    lx = rec[14] * px + rec[17] * py + rec[20] * pz
    ly = rec[15] * px + rec[18] * py + rec[21] * pz
    lz = rec[16] * px + rec[19] * py + rec[22] * pz
    t = int(rec[0])
    q = P0
    if t == SPHERE:
        d = _len3(lx - rec[q], ly - rec[q + 1], lz - rec[q + 2]) - rec[q + 3]
    elif t == ELLIPSOID:
        ax = (lx - rec[q]) / rec[q + 3]
        ay = (ly - rec[q + 1]) / rec[q + 4]
        az = (lz - rec[q + 2]) / rec[q + 5]
        k0 = _len3(ax, ay, az)
        k1 = _len3(ax / rec[q + 3], ay / rec[q + 4], az / rec[q + 5])
        d = k0 * (k0 - 1.0) / max(k1, 1e-9)
    elif t == BOX:
        r = rec[q + 6]
        qx = abs(lx - rec[q]) - (rec[q + 3] - r)
        qy = abs(ly - rec[q + 1]) - (rec[q + 4] - r)
        qz = abs(lz - rec[q + 2]) - (rec[q + 5] - r)
        d = _len3(max(qx, 0.0), max(qy, 0.0), max(qz, 0.0)) + min(max(qx, max(qy, qz)), 0.0) - r
    elif t == CAPSULE:
        ax, ay, az = rec[q], rec[q + 1], rec[q + 2]
        bx, by, bz = rec[q + 3] - ax, rec[q + 4] - ay, rec[q + 5] - az
        pax, pay, paz = lx - ax, ly - ay, lz - az
        bb = bx * bx + by * by + bz * bz
        h = (pax * bx + pay * by + paz * bz) / max(bb, 1e-12)
        h = min(max(h, 0.0), 1.0)
        d = _len3(pax - bx * h, pay - by * h, paz - bz * h) - (rec[q + 6] + (rec[q + 7] - rec[q + 6]) * h)
    elif t == CYLZ:
        r = rec[q + 5]
        dxy = math.sqrt((lx - rec[q]) ** 2 + (ly - rec[q + 1]) ** 2) - (rec[q + 2] - r)
        mid = (rec[q + 3] + rec[q + 4]) * 0.5
        hh = (rec[q + 4] - rec[q + 3]) * 0.5 - r
        dz = abs(lz - mid) - hh
        d = min(max(dxy, dz), 0.0) + math.sqrt(max(dxy, 0.0) ** 2 + max(dz, 0.0) ** 2) - r
    elif t == GABLE:
        cx, cy, cz = rec[q], rec[q + 1], rec[q + 2]
        hl, hw, h0, h1 = rec[q + 3], rec[q + 4], rec[q + 5], rec[q + 6]
        if rec[q + 7] < 0.5:
            along, across = lx - cx, ly - cy
        else:
            along, across = ly - cy, lx - cx
        zz = lz - cz
        rise = h1 - h0
        nl = math.sqrt(rise * rise + hw * hw)
        slope = (abs(across) * rise + (zz - h1) * hw) / nl
        d = max(max(slope, h0 - zz), abs(along) - hl)
    elif t == CYLAX:
        ax, ay, az = rec[q], rec[q + 1], rec[q + 2]
        bx, by, bz = rec[q + 3] - ax, rec[q + 4] - ay, rec[q + 5] - az
        pax, pay, paz = lx - ax, ly - ay, lz - az
        baba = bx * bx + by * by + bz * bz
        paba = pax * bx + pay * by + paz * bz
        X = _len3(pax * baba - bx * paba, pay * baba - by * paba, paz * baba - bz * paba) - rec[q + 6] * baba
        Y = abs(paba - baba * 0.5) - baba * 0.5
        x2 = X * X
        y2 = Y * Y * baba
        if max(X, Y) < 0.0:
            dd = -min(x2, y2)
        else:
            dd = (x2 if X > 0 else 0.0) + (y2 if Y > 0 else 0.0)
        d = math.copysign(math.sqrt(abs(dd)), dd) / baba
    else:  # TORUSZ
        qx = math.sqrt((lx - rec[q]) ** 2 + (ly - rec[q + 1]) ** 2) - rec[q + 3]
        d = math.sqrt(qx * qx + (lz - rec[q + 2]) ** 2) - rec[q + 4]
    amp = rec[8]
    if amp != 0.0:
        f = rec[9]
        s = int(rec[10])
        n = _vnoise(x * f, y * f, z * f, s) * 0.667 + _vnoise(x * f * 2.03, y * f * 2.03, z * f * 2.03, s + 17) * 0.333
        d += (n - 0.5) * 2.0 * amp
    return d


@nb.njit(cache=True)
def _box_dist(rec, x, y, z):
    cx = (rec[2] + rec[5]) * 0.5
    cy = (rec[3] + rec[6]) * 0.5
    cz = (rec[4] + rec[7]) * 0.5
    qx = abs(x - cx) - (rec[5] - rec[2]) * 0.5
    qy = abs(y - cy) - (rec[6] - rec[3]) * 0.5
    qz = abs(z - cz) - (rec[7] - rec[4]) * 0.5
    return _len3(max(qx, 0.0), max(qy, 0.0), max(qz, 0.0)) + min(max(qx, max(qy, qz)), 0.0)


@nb.njit(cache=True)
def scene_eval(recs, x, y, z):
    best = 1e9
    bi = -1
    for i in range(recs.shape[0]):
        bd = _box_dist(recs[i], x, y, z)
        if bd >= best:
            continue
        if bd > 0.04:
            d = bd
        else:
            d = _prim(recs[i], x, y, z)
        if d < best:
            best = d
            bi = i
    return best, bi


@nb.njit(cache=True, parallel=True)
def k_march(recs, p0, u, tlo, thi, eps, max_steps):
    n = p0.shape[0]
    t_out = np.empty(n)
    hit = np.zeros(n, np.bool_)
    for i in nb.prange(n):
        t = thi[i]
        lo = tlo[i]
        for _ in range(max_steps):
            x = p0[i, 0] + u[0] * t
            y = p0[i, 1] + u[1] * t
            z = p0[i, 2] + u[2] * t
            d, _bi = scene_eval(recs, x, y, z)
            if d < eps:
                hit[i] = True
                break
            t -= max(d * 0.8, eps * 0.5)
            if t < lo:
                break
        t_out[i] = t
    return t_out, hit


@nb.njit(cache=True, parallel=True)
def k_shade_geom(recs, p, h, sun):
    """normals, material record index, ambient occlusion, sun visibility."""
    n = p.shape[0]
    nrm = np.empty((n, 3))
    mat = np.empty(n, np.int64)
    ao = np.empty(n)
    vis = np.empty(n)
    for i in nb.prange(n):
        x, y, z = p[i, 0], p[i, 1], p[i, 2]
        _d, bi = scene_eval(recs, x, y, z)
        mat[i] = bi
        gx = scene_eval(recs, x + h, y, z)[0] - scene_eval(recs, x - h, y, z)[0]
        gy = scene_eval(recs, x, y + h, z)[0] - scene_eval(recs, x, y - h, z)[0]
        gz = scene_eval(recs, x, y, z + h)[0] - scene_eval(recs, x, y, z - h)[0]
        L = max(_len3(gx, gy, gz), 1e-12)
        nx, ny, nz = gx / L, gy / L, gz / L
        nrm[i, 0], nrm[i, 1], nrm[i, 2] = nx, ny, nz
        occ = 0.0
        w = 1.0
        for k in range(1, 6):
            hh = 0.035 * k
            dd = scene_eval(recs, x + nx * hh, y + ny * hh, z + nz * hh)[0]
            occ += (hh - min(dd, hh)) * w
            w *= 0.75
        ao[i] = min(max(1.0 - 4.0 * occ, 0.0), 1.0)
        vis[i] = _soft_shadow(recs, x + nx * 0.01, y + ny * 0.01, z + nz * 0.01, sun, 4.0, 48, 10.0)
    return nrm, mat, ao, vis


@nb.njit(cache=True)
def _soft_shadow(recs, x, y, z, sun, maxd, steps, k):
    res = 1.0
    t = 0.03
    for _ in range(steps):
        d = scene_eval(recs, x + sun[0] * t, y + sun[1] * t, z + sun[2] * t)[0]
        res = min(res, k * d / t)
        if d < 0.002:
            return 0.0
        t += min(max(d, 0.015), 0.25)
        if t > maxd:
            break
    return min(max(res, 0.0), 1.0)


@nb.njit(cache=True, parallel=True)
def k_ground_shadow(recs, p, sun, maxd, k):
    n = p.shape[0]
    out = np.empty(n)
    for i in nb.prange(n):
        out[i] = 1.0 - _soft_shadow(recs, p[i, 0], p[i, 1], p[i, 2], sun, maxd, 64, k)
    return out
