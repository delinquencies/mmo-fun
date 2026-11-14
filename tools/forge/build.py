#!/usr/bin/env python3
"""Sprite Forge build: renders every calibration asset for each native resolution.

Usage:  python3 tools/forge/build.py [--sets 64,96] [--only name,...]
Output: game/assets/generated/t<tile_w>/  (PNGs + manifest.json)
        game/data/props.json              (resolution-independent prop definitions)
"""
import argparse
import json
import os
import sys
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from render import render, canvas_for, save_rgba, shadow_rgba, project  # noqa: E402
from sdf import Scene  # noqa: E402
import terrain  # noqa: E402
from models import nature, props, buildings, characters  # noqa: E402

ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "game", "assets", "generated")
DATA = os.path.join(ROOT, "game", "data")

# Resolution sets under comparison: tile width -> target character height (px)
SETS = {64: "t64", 96: "t96"}


# ---------------------------------------------------------------------------
# Prop catalogue.  collision: list of shapes in world units relative to anchor
#   {"circle": [x, y, r]} or {"rect": [x0, y0, x1, y1]}
# sort: "point" (y-sort at anchor) or "footprint" (sliced building sort)
# ---------------------------------------------------------------------------
def catalogue():
    c = {}

    def add(name, builder, collision=None, sort="point", anchors=None):
        c[name] = dict(builder=builder, collision=collision or [], sort=sort, anchors=anchors or {})

    add("tree_oak_a", lambda: nature.tree(1, 3.7, 1.35), [{"circle": [0, 0, 0.22]}])
    add("tree_oak_b", lambda: nature.tree(7, 3.3, 1.2), [{"circle": [0, 0, 0.2]}])
    add("tree_oak_c", lambda: nature.tree(12, 4.1, 1.5, 0.17, 54), [{"circle": [0, 0, 0.24]}])
    add("tree_young", lambda: nature.tree(21, 2.6, 0.8, 0.09, 22), [{"circle": [0, 0, 0.14]}])
    add("bush_green", lambda: nature.bush(2, 0.42), [{"circle": [0, 0, 0.3]}])
    add("bush_berry", lambda: nature.bush(5, 0.4, "#b0201a"), [{"circle": [0, 0, 0.3]}])
    add("bush_blossom", lambda: nature.bush(9, 0.44, "#d68ac8", 0.045), [{"circle": [0, 0, 0.3]}])
    add("rock_large", lambda: nature.rock_pile(3, 4, 0.5), [{"circle": [0, 0, 0.45]}])
    add("rock_medium", lambda: nature.rock_pile(8, 3, 0.36), [{"circle": [0, 0, 0.3]}])
    add("rock_small", lambda: nature.rock_pile(14, 2, 0.2))
    add("stump", lambda: nature.stump(), [{"circle": [0, 0, 0.22]}])
    add("flowers_yellow", lambda: nature.flower_clump(5, "#f2d84a"))
    add("flowers_white", lambda: nature.flower_clump(6, "#f4f2ea"))
    add("flowers_purple", lambda: nature.flower_clump(7, "#a070d0"))
    add("flowers_pink", lambda: nature.flower_clump(8, "#e48ab8"))
    add("grass_tuft_a", lambda: nature.grass_tuft(6, 0.22))
    add("grass_tuft_b", lambda: nature.grass_tuft(11, 0.3))
    add("fence_x", lambda: props.fence("x", 1), [{"rect": [-0.5, -0.08, 0.5, 0.08]}])
    add("fence_y", lambda: props.fence("y", 2), [{"rect": [-0.08, -0.5, 0.08, 0.5]}])
    add("barrel", lambda: props.barrel(), [{"circle": [0, 0, 0.3]}])
    add("crate", lambda: props.crate(), [{"rect": [-0.32, -0.32, 0.32, 0.32]}])
    add("signpost", lambda: props.signpost(), [{"circle": [0, 0, 0.1]}])
    add("lamppost", lambda: props.lamppost(), [{"circle": [0, 0, 0.14]}])
    add("log_pile", lambda: props.log_pile(), [{"rect": [-0.45, -0.38, 0.45, 0.38]}])
    add("trough", lambda: props.trough(), [{"rect": [-0.52, -0.22, 0.52, 0.22]}])
    add("cottage", lambda: buildings.cottage(),
        [{"rect": [0, 0, buildings.FW, buildings.FD]}], sort="footprint")
    return c


def offset_of(r, world_pt):
    """Anchor as a screen offset (px) from the sprite pivot."""
    s = project(np.asarray(world_pt, float)[None, :], r.tile_w)[0]
    return [round(float(s[0]), 2), round(float(s[1]), 2)]


def build_props(tile_w, outdir, only=None):
    out = {}
    for name, spec in catalogue().items():
        if only and name not in only:
            continue
        t = time.time()
        res = spec["builder"]()
        anchors = {}
        if isinstance(res, tuple):
            res, anchors = res
        r = render(res, tile_w)
        save_rgba(r.rgba, os.path.join(outdir, f"{name}.png"))
        save_rgba(shadow_rgba(r.shadow), os.path.join(outdir, f"{name}_shadow.png"))
        out[name] = {"file": f"{name}.png", "shadow": f"{name}_shadow.png",
                     "size": list(r.size()), "pivot": list(map(int, r.pivot)),
                     "anchors": {k: offset_of(r, v) for k, v in anchors.items()}}
        print(f"  {name:16s} {r.size()} {time.time() - t:.1f}s", flush=True)
    return out


def _blade_visibility(r, base, tip):
    """Fraction of blade sample points not hidden behind the body (depth test)."""
    vis = 0
    n = 9
    for k in range(n):
        w = base + (tip - base) * (k + 0.5) / n
        c = r.to_canvas(w[None, :])[0]
        x, y = int(c[0]), int(c[1])
        if not (0 <= x < r.depth.shape[1] and 0 <= y < r.depth.shape[0]):
            vis += 1
            continue
        d = r.depth[y, x]
        t_pt = 2.0 * w[2]  # ray parameter of the point along this pixel's ray
        if np.isnan(d) or t_pt >= d - 0.06:
            vis += 1
    return vis / n


def build_animated(tile_w, outdir, name, pose_fn, anims, bounds, frame_anchor_keys=()):
    """Render an 8-direction sprite sheet per animation. rows = directions."""
    bmin, bmax = np.array(bounds[0], float), np.array(bounds[1], float)
    canvas = canvas_for(bmin, bmax, tile_w, with_shadow=True)
    fw, fh = canvas[2], canvas[3]
    meta = {"frame_size": [fw, fh], "pivot": [-canvas[0], -canvas[1]],
            "directions": characters.DIRECTIONS, "anims": {}}
    for anim, (nframes, fps, args_fn) in anims.items():
        t = time.time()
        sheet = np.zeros((fh * 8, fw * nframes, 4), np.uint8)
        shs = np.zeros((fh * 8, fw * nframes), bool)
        frame_anchors = []
        for di, d in enumerate(characters.DIRECTIONS):
            row = []
            for f in range(nframes):
                res = pose_fn(*args_fn(f, nframes))
                anchors = {}
                if isinstance(res, tuple):
                    res, anchors = res
                sc = Scene().extend(res, yaw=characters.DIR_YAW[d])
                yaw = characters.DIR_YAW[d]
                R = np.array([[np.cos(yaw), -np.sin(yaw), 0], [np.sin(yaw), np.cos(yaw), 0], [0, 0, 1]])
                wa = {k: R @ np.asarray(v, float) for k, v in anchors.items()}
                r = render(sc, tile_w, canvas=canvas)
                sheet[di * fh:(di + 1) * fh, f * fw:(f + 1) * fw] = r.rgba
                shs[di * fh:(di + 1) * fh, f * fw:(f + 1) * fw] = r.shadow
                fa = {k: offset_of(r, v) for k, v in wa.items()}
                if "blade_base" in wa:
                    fa["blade_visible"] = round(_blade_visibility(r, wa["blade_base"], wa["blade_tip"]), 2)
                row.append(fa)
            frame_anchors.append(row)
        a0 = sheet[0:fh, 0:fw, 3] > 0  # direction S, frame 0
        ys = np.nonzero(a0.any(axis=1))[0]
        if ys.size:
            # head-to-foot height: topmost opaque pixel down to the foot pivot
            meta.setdefault("content_height_px", int(meta["pivot"][1] - ys[0]))
        save_rgba(sheet, os.path.join(outdir, f"{name}_{anim}.png"))
        save_rgba(shadow_rgba(shs), os.path.join(outdir, f"{name}_{anim}_shadow.png"))
        meta["anims"][anim] = {"file": f"{name}_{anim}.png", "shadow": f"{name}_{anim}_shadow.png",
                               "frames": nframes, "fps": fps, "anchors": frame_anchors}
        print(f"  {name}_{anim:8s} {fw}x{fh} x {nframes}f x 8 dirs  {time.time() - t:.1f}s", flush=True)
    return meta


def build_terrain(tile_w, outdir):
    t = time.time()
    at = terrain.build_atlases(tile_w)
    meta = {"period": terrain.PERIOD}
    for k, v in at.items():
        save_rgba(v, os.path.join(outdir, f"terrain_{k}.png"))
        meta[k] = f"terrain_{k}.png"
    print(f"  terrain atlases {time.time() - t:.1f}s", flush=True)
    return meta


def write_props_json():
    os.makedirs(DATA, exist_ok=True)
    defs = {k: {"collision": v["collision"], "sort": v["sort"]} for k, v in catalogue().items()}
    defs["cottage"]["footprint"] = [0, 0, buildings.FW, buildings.FD]
    with open(os.path.join(DATA, "props.json"), "w") as f:
        json.dump(defs, f, indent=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--sets", default="64,96")
    ap.add_argument("--only", default="", help="comma list: terrain, player, sheep or prop names")
    a = ap.parse_args()
    only = set(x for x in a.only.split(",") if x)
    write_props_json()
    for tw in [int(x) for x in a.sets.split(",")]:
        outdir = os.path.join(OUT, SETS[tw])
        os.makedirs(outdir, exist_ok=True)
        mpath = os.path.join(outdir, "manifest.json")
        manifest = json.load(open(mpath)) if os.path.exists(mpath) else {}
        manifest.update({"tile_w": tw, "tile_h": tw // 2, "units": "1 world unit = 1 tile edge"})
        print(f"== set t{tw}", flush=True)
        if not only or "terrain" in only:
            manifest["terrain"] = build_terrain(tw, outdir)
        prop_only = only - {"terrain", "player", "sheep"}
        if not only or prop_only:
            manifest.setdefault("sprites", {}).update(build_props(tw, outdir, prop_only or None))
        anims = manifest.setdefault("animations", {})
        if not only or "player" in only:
            anims["player"] = build_animated(
                tw, outdir, "player", characters.adventurer_pose,
                {"idle": (4, 4, lambda f, n: (0.0, 0.0, np.sin(f / n * 2 * np.pi))),
                 "walk": (8, 10, lambda f, n: (f / n * 2 * np.pi, 1.0, 0.0))},
                ((-0.95, -0.95, 0.0), (0.95, 0.95, 2.0)))
        if not only or "sheep" in only:
            anims["sheep"] = build_animated(
                tw, outdir, "sheep", characters.sheep_pose,
                {"stand": (2, 2, lambda f, n: (0.0, f * 0.25)),
                 "graze": (2, 1, lambda f, n: (1.0 - 0.15 * f, 0.0))},
                ((-0.65, -0.65, 0.0), (0.65, 0.65, 0.85)))
        with open(mpath, "w") as f:
            json.dump(manifest, f, indent=1)
    print("done")


if __name__ == "__main__":
    main()
