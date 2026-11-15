#!/usr/bin/env python3
"""Placeholder sound effects, synthesised so the project ships with no
third-party audio.  Replace any file in game/assets/audio/ with a recorded
effect of the same name (or remap it in game/data/audio_events.json)."""
import os
import wave

import numpy as np

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(ROOT, "game", "assets", "audio")
SR = 22050
rng = np.random.default_rng(7)


def t(d):
    return np.arange(int(SR * d)) / SR


def env(n, a=0.005, r=0.2):
    x = np.arange(n) / SR
    return np.clip(x / a, 0, 1) * np.exp(-x / r)


def lowpass(x, k):
    k = max(1, int(k))
    return np.convolve(x, np.ones(k) / k, mode="same")


def noise(d):
    return rng.uniform(-1, 1, int(SR * d))


def thump(d=0.25, f=85, r=0.06):
    tt = t(d)
    s = np.sin(2 * np.pi * f * tt * (1 - tt * 0.8)) * env(len(tt), 0.002, r)
    s += lowpass(noise(d), 12) * env(len(tt), 0.001, r * 0.5) * 0.8
    return s


def knock(f=180, d=0.12):
    tt = t(d)
    return (np.sin(2 * np.pi * f * tt) + 0.5 * np.sin(2 * np.pi * f * 2.7 * tt)) * env(len(tt), 0.001, 0.025) \
        + lowpass(noise(d), 4) * env(len(tt), 0.0005, 0.01) * 0.6


def creak(d=0.55, f0=150, f1=230):
    tt = t(d)
    f = f0 + (f1 - f0) * (tt / d) + 18 * np.sin(2 * np.pi * 7 * tt) + rng.normal(0, 6, len(tt)).cumsum() * 0.02
    ph = 2 * np.pi * np.cumsum(f) / SR
    saw = (ph / (2 * np.pi)) % 1.0 * 2 - 1
    s = lowpass(saw, 3) * (0.6 + 0.4 * np.sin(2 * np.pi * 23 * tt) ** 2)
    e = np.clip(tt / 0.05, 0, 1) * np.clip((d - tt) / 0.12, 0, 1)
    return s * e * 0.55


def mix(*parts):
    n = max(len(p) + o for p, o in parts)
    out = np.zeros(n)
    for p, o in parts:
        out[o:o + len(p)] += p
    return out


def at(sec):
    return int(sec * SR)


def swish(d=0.16, lo=3, hi=12):
    tt = t(d)
    x = noise(d)
    k = np.linspace(hi, lo, len(tt)).astype(int)
    y = np.array([x[max(0, i - kk):i + 1].mean() for i, kk in enumerate(k)])
    return y * np.sin(np.pi * tt / d) * 1.4


def ring(freqs, d=0.6, r=0.18):
    tt = t(d)
    s = sum(np.sin(2 * np.pi * f * tt + i) / (i + 1) for i, f in enumerate(freqs))
    return s * env(len(tt), 0.002, r)


def growl(d=0.7, f=85):
    tt = t(d)
    f0 = f * (1 + 0.15 * np.sin(2 * np.pi * 6 * tt)) + rng.normal(0, 4, len(tt)).cumsum() * 0.01
    ph = 2 * np.pi * np.cumsum(f0) / SR
    saw = (ph / (2 * np.pi)) % 1.0 * 2 - 1
    rough = lowpass(noise(d), 6) * 0.6
    e = np.clip(tt / 0.08, 0, 1) * np.clip((d - tt) / 0.2, 0, 1)
    return (lowpass(saw, 4) + rough) * e * (0.7 + 0.3 * np.sin(2 * np.pi * 23 * tt))


def zap(d=0.45):
    tt = t(d)
    crack = noise(d) * np.exp(-tt / 0.03)
    buzz = np.sign(np.sin(2 * np.pi * (110 + 40 * np.sin(2 * np.pi * 9 * tt)) * tt)) * 0.35 * np.exp(-tt / 0.18)
    sizzle = (noise(d) - lowpass(noise(d), 3)) * 0.5 * np.exp(-tt / 0.12) * (0.5 + 0.5 * (rng.uniform(0, 1, len(tt)) > 0.7))
    return crack + buzz + sizzle


def rattle(n=7, gap=0.045):
    return mix(*[(knock(900 + rng.uniform(-200, 300), 0.04) * 0.5, at(gap * k + rng.uniform(0, 0.015))) for k in range(n)])


SOUNDS = {
    "door_open": lambda: mix((creak(0.6, 140, 240), 0), (knock(120), at(0.02))),
    "door_close": lambda: mix((creak(0.25, 220, 160) * 0.6, 0), (thump(0.3, 75, 0.08), at(0.2)), (knock(420, 0.06) * 0.5, at(0.26))),
    "chest_open": lambda: mix((knock(260), 0), (creak(0.4, 260, 330) * 0.8, at(0.03))),
    "chest_close": lambda: mix((creak(0.18, 300, 240) * 0.6, 0), (thump(0.25, 110, 0.05), at(0.15))),
    "item_pickup": lambda: swish(0.14, 2, 10) * 0.7,
    "item_place": lambda: mix((thump(0.18, 140, 0.035) * 0.8, 0), (swish(0.08, 2, 6) * 0.3, 0)),
    "coins": lambda: mix(*[(ring([2400 + 300 * k, 5100 + 200 * k], 0.15, 0.04) * 0.25, at(0.035 * k)) for k in range(5)]),
    "equip": lambda: mix((swish(0.2, 1, 4) * 0.5, 0), (ring([1250, 2830, 4170, 6020], 0.7, 0.16) * 0.35, at(0.06))),
    "unequip": lambda: mix((ring([980, 2210, 3590], 0.4, 0.08) * 0.3, 0), (swish(0.14, 2, 8) * 0.4, at(0.04))),
    "invalid": lambda: mix((knock(140, 0.1), 0), (knock(110, 0.12), at(0.11))),
    "window_open": lambda: swish(0.1, 3, 14) * 0.5,
    "window_close": lambda: mix((swish(0.08, 3, 10) * 0.4, 0), (knock(300, 0.05) * 0.3, at(0.05))),
    "ui_click": lambda: knock(520, 0.05) * 0.35,
    # Slice 005 combat
    "sword_swing": lambda: swish(0.22, 1, 5) * 0.9,
    "hit_flesh": lambda: mix((thump(0.2, 120, 0.04), 0), (lowpass(noise(0.08), 2) * env(int(SR * 0.08), 0.001, 0.02) * 0.6, 0)),
    "hit_bone": lambda: mix((knock(700, 0.08), 0), (knock(1100, 0.06) * 0.6, at(0.01)), (thump(0.15, 160, 0.03) * 0.4, 0)),
    "miss_whoosh": lambda: swish(0.18, 2, 9) * 0.6,
    "bow_fire": lambda: mix((ring([180, 410], 0.25, 0.06) * 0.5, 0), (swish(0.12, 1, 4) * 0.6, at(0.02))),
    "arrow_impact": lambda: mix((knock(300, 0.06), 0), (thump(0.12, 140, 0.025) * 0.5, 0)),
    "lightning_zap": lambda: zap(0.45),
    "wolf_growl": lambda: growl(0.8, 80),
    "wolf_bite": lambda: mix((growl(0.25, 120) * 0.6, 0), (knock(450, 0.05), at(0.12))),
    "wolf_death": lambda: mix((growl(0.5, 140) * 0.5, 0), (thump(0.3, 70, 0.08), at(0.35))),
    "bone_rattle": lambda: rattle(9, 0.05),
    "bone_collapse": lambda: mix((rattle(14, 0.03), 0), (thump(0.3, 90, 0.07), at(0.3))),
    "bandit_shout": lambda: growl(0.45, 150) * 0.8,
    "bandit_death": lambda: mix((growl(0.5, 120) * 0.6, 0), (thump(0.3, 75, 0.08), at(0.4))),
    "player_hurt": lambda: mix((thump(0.18, 110, 0.04), 0), (growl(0.18, 190) * 0.35, 0)),
    "loot_open": lambda: mix((swish(0.12, 3, 10) * 0.5, 0), (thump(0.15, 120, 0.03) * 0.4, at(0.06))),
}


def write(name, s):
    s = s / max(1e-6, np.abs(s).max()) * 0.8
    pcm = (s * 32767).astype(np.int16)
    with wave.open(os.path.join(OUT, f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())


def main():
    os.makedirs(OUT, exist_ok=True)
    for name, fn in SOUNDS.items():
        write(name, fn())
    print(f"wrote {len(SOUNDS)} placeholder sounds to {OUT}")


if __name__ == "__main__":
    main()
