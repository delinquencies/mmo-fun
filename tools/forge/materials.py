"""Procedural surface materials. shade(p, n) -> (albedo, normal, emissive)."""
import numpy as np

from noise import fbm3, value3, hash01


def _c(hexstr):
    hexstr = hexstr.lstrip("#")
    return np.array([int(hexstr[i:i + 2], 16) / 255.0 for i in (0, 2, 4)])


def mix(a, b, t):
    t = np.asarray(t)[..., None] if np.ndim(t) else t
    return a + (b - a) * t


def ramp(t, cols):
    """Piecewise-linear colour ramp; cols: list of hex strings."""
    cs = np.array([_c(c) for c in cols])
    t = np.clip(t, 0, 1) * (len(cs) - 1)
    i = np.minimum(np.floor(t).astype(int), len(cs) - 2)
    f = (t - i)[..., None]
    return cs[i] * (1 - f) + cs[i + 1] * f


def bump(p, n, strength, freq, seed=0):
    if strength <= 0:
        return n
    g = np.stack([fbm3(p, freq, 2, seed + i * 7) - 0.5 for i in range(3)], axis=1)
    nn = n + g * strength
    return nn / np.linalg.norm(nn, axis=1, keepdims=True)


class Material:
    def __init__(self, albedo, bump_strength=0.0, bump_freq=20.0, emissive=None, seed=0):
        self.albedo = albedo
        self.bs = bump_strength
        self.bf = bump_freq
        self.emissive = emissive
        self.seed = seed

    def shade(self, p, n):
        a = self.albedo(p, n) if callable(self.albedo) else np.tile(self.albedo, (p.shape[0], 1))
        nb = bump(p, n, self.bs, self.bf, self.seed)
        e = self.emissive(p, n) if callable(self.emissive) else None
        return a, nb, e


def flat(hexcol, var=0.06, freq=14.0, seed=0, bump_s=0.0):
    base = _c(hexcol)

    def f(p, n):
        v = (fbm3(p, freq, 2, seed) - 0.5) * 2 * var
        return np.clip(base[None, :] * (1 + v[:, None]), 0, 1)
    return Material(f, bump_s, freq * 1.5, seed=seed)


def noisy_ramp(cols, freq=10.0, seed=0, bump_s=0.15, fine=0.0):
    def f(p, n):
        t = fbm3(p, freq, 3, seed)
        t = np.clip((t - 0.5) * 1.8 + 0.5, 0, 1)
        c = ramp(t, cols)
        if fine:
            c = c * (1 + (value3(p[:, 0] * 60, p[:, 1] * 60, p[:, 2] * 60, seed + 5) - 0.5) * fine)[:, None]
        return c
    return Material(f, bump_s, freq * 2, seed=seed)


def wood_grain(cols, axis=2, freq=6.0, seed=0, bump_s=0.12):
    """Grain streaks running along `axis`: long fibres, occasional dark seams
    and checks, and slow weathering variation along the board."""
    def f(p, n):
        scale = np.array([26.0, 26.0, 26.0])
        scale[axis] = 1.6
        g = value3(p[:, 0] * scale[0], p[:, 1] * scale[1], p[:, 2] * scale[2], seed)
        fine = value3(p[:, 0] * scale[0] * 2.3, p[:, 1] * scale[1] * 2.3, p[:, 2] * scale[2] * 2.3, seed + 11)
        g2 = fbm3(p, freq, 2, seed + 3)
        t = np.clip(g * 0.55 + fine * 0.2 + g2 * 0.5 - 0.1, 0, 1)
        c = ramp(t, cols)
        return np.where((g < 0.16)[:, None], c * 0.62, c)      # dark checks along the grain
    return Material(f, bump_s, 25.0, seed=seed)


def plain(hexcol):
    return Material(_c(hexcol))


def emissive_flat(hexcol, glow):
    base = _c(hexcol)
    g = _c(glow)
    return Material(base, emissive=lambda p, n: np.tile(g, (p.shape[0], 1)))


class PaletteMaterial(Material):
    """A material drawn from a hand-picked tone ramp (dark -> light) instead of
    noise. The sprite renderer picks one tone per pixel from the lighting, so a
    surface becomes a few clean colour clusters. `spec` adds a highlight step
    for metal and polished leather; `detail` marks tiny features (eyes, buckles)
    that must survive downsampling. In the legacy renderer it behaves as a flat
    mid-tone material, so one model works in both."""

    def __init__(self, ramp_hex, spec=0.0, gloss=24.0, detail=False, emissive=None, name=""):
        self.ramp = np.array([_c(h) for h in ramp_hex])
        self.spec = spec
        self.gloss = gloss
        self.detail = detail
        self.name = name
        mid = self.ramp[len(self.ramp) // 2]
        super().__init__(mid, emissive=emissive)


def auto_ramp(material, albedo, emissive=None):
    """Tone ramp for a legacy (noise) material, derived once from its average
    colour and cached on the material so every frame and facing uses the same
    tones. Shadows lean cool, highlights lean warm."""
    r = getattr(material, "_auto_ramp", None)
    if r is None:
        base = np.median(albedo, axis=0)
        if emissive is not None:
            base = np.clip(base + np.median(emissive, axis=0), 0, 1)
        cool = np.array([0.92, 0.96, 1.08])
        warm = np.array([1.06, 1.02, 0.9])
        r = np.clip(np.array([base * 0.4 * cool, base * 0.62 * cool, base * 0.82, base * 1.0, base * 1.2 * warm]), 0, 1)
        material._auto_ramp = r
    return r
