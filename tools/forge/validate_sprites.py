#!/usr/bin/env python3
"""Production checks for animated character sheets.

Usage:  python3 tools/forge/validate_sprites.py [--sets 64,96] [--names player,bandit] [--determinism]
Exit code 0 when every check passes.

Per character and animation it verifies:
  * sheet = frames x 8 directions of one standard frame size; shadow and weapon
    layer sheets match it exactly
  * alpha is strictly 0 or 255 (no semi-transparent fringe)
  * no frame touches its frame border (nothing clipped)
  * ground contact: the lowest opaque pixel stays within a fixed band around
    the pivot row in every facing (tight for idle, a stride wide for walk/run)
  * every stored anchor (head, blade base, blade tip) lies inside its frame
and reports palette size and the share of stray single pixels (pixel-art
cleanliness). --determinism renders one frame twice and requires identical bytes.
"""
import argparse
import json
import os
import sys

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "game", "assets", "generated")


def stray_share(a):
    """Share of opaque pixels with none of their 8 neighbours in the same colour
    (true orphans: speckle, not line work)."""
    op = a[..., 3] > 0
    key = (a[..., 0].astype(np.int64) << 16) | (a[..., 1].astype(np.int64) << 8) | a[..., 2]
    key = np.where(op, key, -1)
    pd = np.pad(key, 1, constant_values=-2)
    H, W = key.shape
    same = np.zeros_like(op)
    for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1), (-1, -1), (-1, 1), (1, -1), (1, 1)):
        same |= pd[1 + dy:1 + dy + H, 1 + dx:1 + dx + W] == key
    return float((op & ~same).sum()) / max(1, int(op.sum()))


def check_character(setdir, tile_w, name, meta, problems, report):
    fw, fh = meta["frame_size"]
    px, py = meta["pivot"]
    k = tile_w / 64.0
    colours = set()
    strays = []
    for anim, a in meta["anims"].items():
        path = os.path.join(setdir, a["file"])
        img = np.array(Image.open(path).convert("RGBA"))
        n = a["frames"]
        tag = f"{name}/{anim}"
        if img.shape[:2] != (fh * 8, fw * n):
            problems.append(f"{tag}: sheet is {img.shape[1]}x{img.shape[0]}, expected {fw * n}x{fh * 8}")
            continue
        sh = np.array(Image.open(os.path.join(setdir, a["shadow"])).convert("RGBA"))
        if sh.shape != img.shape:
            problems.append(f"{tag}: shadow sheet size differs")
        al = img[..., 3]
        if np.any((al != 0) & (al != 255)):
            problems.append(f"{tag}: semi-transparent pixels")
        op = al > 0
        rgb = img[..., :3][op]
        colours |= set(map(tuple, np.unique(rgb, axis=0)))
        strays.append(stray_share(img))
        lows = []
        for d in range(8):
            for f in range(n):
                fr = op[d * fh:(d + 1) * fh, f * fw:(f + 1) * fw]
                if not fr.any():
                    problems.append(f"{tag}: empty frame dir {d} frame {f}")
                    continue
                if fr[0].any() or fr[-1].any() or fr[:, 0].any() or fr[:, -1].any():
                    problems.append(f"{tag}: content touches the frame border (dir {d} frame {f})")
                ys = np.nonzero(fr.any(axis=1))[0]
                lows.append(int(ys[-1]) - py)
                for key, v in a["anchors"][d][f].items():
                    if isinstance(v, list):
                        x, y = v[0] + px, v[1] + py
                        if not (0 <= x < fw and 0 <= y < fh):
                            problems.append(f"{tag}: anchor {key} outside the frame (dir {d} frame {f})")
        if anim in ("idle", "walk", "run") and lows:
            lo, hi = min(lows), max(lows)
            report.append(f"  {tag:22s} lowest pixel {lo:+d}..{hi:+d} px from the pivot row")
            # a planted foot sits on the pivot row; a striding foot is drawn up to a
            # stride nearer or farther on the ground plane, which moves it on screen
            reach = {"idle": (3, 10), "walk": (5, 12), "run": (12, 14)}[anim]   # idle allows a held blade tip
            if lo < -reach[0] * k or hi > reach[1] * k:
                problems.append(f"{tag}: ground contact out of range ({lo:+d}..{hi:+d} px)")
    for ov, layers in meta.get("overlays", {}).items():
        for anim, a in layers.items():
            n = meta["anims"][anim]["frames"]
            o = Image.open(os.path.join(setdir, a["file"]))
            if o.size != (fw * n, fh * 8):
                problems.append(f"{name}/{anim}/{ov}: weapon layer size differs from the base sheet")
        missing = set(meta["anims"]) - set(layers)
        if missing:
            problems.append(f"{name}/{ov}: weapon layer missing for {sorted(missing)}")
    report.append(f"  {name}: frame {fw}x{fh}, pivot ({px},{py}), style {meta.get('style', 'scene')}, "
                  f"{len(colours)} colours, stray pixels {100 * float(np.mean(strays)):.2f}%")


def determinism(problems, report):
    sys.path.insert(0, HERE)
    from render import render_sprite
    from sdf import Scene
    from models import characters
    outs = []
    for _ in range(2):
        sc, _a = characters.adventurer_pose(walk=0.0, weapon="lightning_sword")
        w = Scene().extend(sc, yaw=characters.DIR_YAW["SE"])
        outs.append(render_sprite(w, 64).rgba.tobytes())
    ok = outs[0] == outs[1]
    report.append(f"  determinism: two renders of the same frame are {'identical' if ok else 'DIFFERENT'}")
    if not ok:
        problems.append("render is not deterministic")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", default="64,96")
    ap.add_argument("--names", default="")
    ap.add_argument("--determinism", action="store_true")
    a = ap.parse_args()
    names = set(x for x in a.names.split(",") if x)
    problems, report = [], []
    for tw in [int(x) for x in a.sets.split(",")]:
        setdir = os.path.join(OUT, f"t{tw}")
        man = json.load(open(os.path.join(setdir, "manifest.json")))
        report.append(f"set t{tw}")
        for name, meta in man.get("animations", {}).items():
            if "anims" not in meta or (names and name not in names):
                continue
            if "anchors" not in next(iter(meta["anims"].values())):
                continue
            check_character(setdir, tw, name, meta, problems, report)
    if a.determinism:
        determinism(problems, report)
    print("\n".join(report))
    for p in problems:
        print("PROBLEM", p)
    print(f"\n{len(problems)} problems")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
