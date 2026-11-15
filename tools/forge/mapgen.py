#!/usr/bin/env python3
"""Generates game/data/maps/homestead.json.

Key landmarks are placed by hand below; only small flora (flowers, tufts) is
scattered, deterministically, into the remaining open grass.  The output is
plain JSON so it can be hand-edited afterwards.
"""
import json
import math
import os
import random

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
N = 40  # tiles per side

COTTAGE = (12.0, 7.0)          # back corner; footprint 3 x 4.5
DOOR = (15.6, 9.55)
ROAD = [(23.0, -1.0), (22.6, 6.0), (21.8, 12.0), (20.4, 20.0), (19.6, 28.0), (20.6, 41.0)]
LANES = [[(15.4, 9.55), (18.5, 9.8), (22.4, 9.4)],                    # door -> road
         [(22.0, 13.0), (25.5, 15.0), (29.0, 15.6)]]                  # branch toward the river
PADDOCK = (4, 11, 10, 17)      # x0, y0, x1, y1 (tile corners)


def river_x(y):
    return 32.5 + 1.6 * math.sin(y * 0.16) + 0.8 * math.sin(y * 0.41 + 1.0)


def seg_dist(p, a, b):
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    t = max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - ay) * dy) / (dx * dx + dy * dy)))
    return math.hypot(p[0] - ax - t * dx, p[1] - ay - t * dy)


def poly_dist(p, pts):
    return min(seg_dist(p, pts[i], pts[i + 1]) for i in range(len(pts) - 1))


def terrain():
    rows = []
    for j in range(N + 1):
        row = []
        for i in range(N + 1):
            p = (i, j)
            wob = 0.25 * math.sin(i * 1.7 + j * 0.9)
            if i >= river_x(j):
                row.append("w")
            elif poly_dist(p, ROAD) < 1.3 + wob or any(poly_dist(p, l) < 1.05 + wob for l in LANES):
                row.append("d")
            else:
                row.append("g")
        rows.append("".join(row))
    return rows


def main():
    props = []

    def put(t, x, y):
        props.append({"type": t, "x": round(x, 3), "y": round(y, 3)})

    put("cottage", *COTTAGE)
    # homestead clutter
    put("barrel", 14.6, 12.35)
    put("crate", 13.5, 12.3)
    put("log_pile", 11.35, 9.0)
    put("lamppost", 16.6, 8.5)
    put("bush_blossom", 16.4, 6.6)
    put("signpost", 23.6, 11.2)
    put("trough", 10.8, 15.6)
    put("stump", 25.0, 19.0)
    put("lamppost", 28.6, 14.3)

    # paddock fence with a gate gap on the +x side
    x0, y0, x1, y1 = PADDOCK
    for i in range(x0, x1):
        put("fence_x", i + 0.5, y0)
        put("fence_x", i + 0.5, y1)
    for j in range(y0, y1):
        if x1 == PADDOCK[2] and j in (13,):
            continue
        put("fence_y", x0, j + 0.5)
        put("fence_y", x1, j + 0.5)

    # trees: woodland edge along the back of the map plus specimen trees
    trees = [("tree_oak_c", 3.0, 3.5), ("tree_oak_a", 6.5, 2.0), ("tree_oak_b", 1.5, 7.5),
             ("tree_oak_a", 9.5, 3.5), ("tree_young", 4.5, 6.5), ("tree_oak_b", 2.0, 12.0),
             ("tree_oak_c", 15.5, 2.5), ("tree_young", 12.0, 3.2), ("tree_oak_a", 19.5, 1.5),
             ("tree_oak_b", 18.6, 5.2), ("tree_oak_a", 26.0, 6.0), ("tree_young", 28.0, 3.0),
             ("tree_oak_c", 9.0, 21.0), ("tree_oak_a", 3.0, 22.0), ("tree_young", 13.0, 19.5),
             ("tree_oak_b", 26.5, 23.5), ("tree_young", 24.2, 27.5), ("tree_oak_a", 14.0, 27.0),
             ("tree_oak_c", 5.5, 29.0), ("tree_oak_b", 10.5, 33.0), ("tree_young", 27.0, 33.0),
             ("tree_oak_a", 2.0, 35.0), ("tree_oak_b", 16.0, 36.5), ("tree_oak_c", 29.0, 38.5),
             ("tree_young", 29.5, 9.5)]
    for t, x, y in trees:
        put(t, x, y)
    bushes = [("bush_berry", 17.5, 13.5), ("bush_green", 11.0, 6.0), ("bush_green", 24.5, 9.0),
              ("bush_berry", 27.5, 18.5), ("bush_green", 7.0, 9.0), ("bush_blossom", 3.5, 17.0),
              ("bush_green", 15.0, 22.5), ("bush_berry", 8.0, 25.5), ("bush_blossom", 23.0, 31.0),
              ("bush_green", 12.0, 37.0)]
    for t, x, y in bushes:
        put(t, x, y)
    # rocky river bank
    rng = random.Random(7)
    for j in range(1, N, 3):
        x = river_x(j) - 0.4 + rng.uniform(-0.3, 0.2)
        put(rng.choice(["rock_large", "rock_medium", "rock_medium", "rock_small"]), x, j + rng.uniform(0, 1.5))
    put("rock_large", 18.0, 17.0)
    put("rock_medium", 7.5, 31.5)
    put("rock_small", 25.8, 12.5)

    rows = terrain()
    blocked = [(p["x"], p["y"]) for p in props]

    def free(x, y, r=0.9):
        i, j = int(x), int(y)
        if rows[j][i] != "g" or rows[j + 1][i + 1] != "g" or rows[j][i + 1] != "g" or rows[j + 1][i] != "g":
            return False
        if COTTAGE[0] - 0.5 < x < COTTAGE[0] + 4 and COTTAGE[1] - 0.5 < y < COTTAGE[1] + 5.2:
            return False
        return all(math.hypot(x - bx, y - by) > r for bx, by in blocked)

    flora = ["flowers_yellow", "flowers_white", "flowers_purple", "flowers_pink",
             "grass_tuft_a", "grass_tuft_b", "grass_tuft_a", "grass_tuft_b"]
    for _ in range(420):
        x, y = rng.uniform(0.5, N - 0.5), rng.uniform(0.5, N - 0.5)
        if free(x, y):
            t = rng.choice(flora)
            put(t, x, y)
            blocked.append((x, y))

    data = {
        "name": "Homestead calibration map",
        "size": [N, N],
        "terrain_legend": {"g": "grass", "d": "dirt", "w": "water"},
        "terrain_rows": rows,
        "props": props,
        "sheep": [{"x": 6.5, "y": 13.5}, {"x": 8.2, "y": 15.4}, {"x": 5.6, "y": 15.8}],
        "sheep_pen": [PADDOCK[0] + 0.5, PADDOCK[1] + 0.5, PADDOCK[2] - 0.5, PADDOCK[3] - 0.5],
        "player_start": [17.5, 10.6],
        # Slice 002 interactables (definitions: game/data/interactables.json)
        "entities": [
            {"id": "cottage_door", "def": "door_wood", "x": COTTAGE[0] + 3.06, "y": COTTAGE[1] + 2.55,
             "persistence": "permanent"},
            {"id": "cottage_chest", "def": "chest_wood", "x": COTTAGE[0] + 0.85, "y": COTTAGE[1] + 1.25,
             "persistence": "permanent",
             "contents": [["gold_coins", 25], ["red_apple", 3], ["healing_potion", 1]]},
        ],
        # spawn_id is the stable identity used by persistence (docs/PERSISTENCE.md)
        "ground_items": [
            {"spawn_id": "spawn_iron_sword", "def": "iron_sword", "x": 18.4, "y": 12.2, "persistence": "permanent"},
            {"spawn_id": "spawn_trough_apples", "def": "red_apple", "qty": 2, "x": 11.45, "y": 16.35, "persistence": "resettable"},
        ],
    }
    out = os.path.join(ROOT, "game", "data", "maps", "homestead.json")
    with open(out, "w") as f:
        json.dump(data, f, indent=1)
    print(f"wrote {out}: {len(props)} props")


if __name__ == "__main__":
    main()
