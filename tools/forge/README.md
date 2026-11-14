# Sprite Forge

A procedural **stand-in for the Blender pre-render step** of the production
pipeline (brief §13). It models assets as signed-distance-field primitives,
ray-marches them through the project's fixed isometric camera, and writes
sprites, shadows and metadata in the format the game consumes. When real
Blender or ComfyUI assets exist, they only need to produce the same
PNG + manifest contract.

## Camera / scale contract (shared with `game/scripts/core/iso.gd`)

- Orthographic camera, **30° elevation, 45° azimuth**. This gives an exact
  2:1 ground diamond, because sin 30° = 0.5.
- 1 world unit = 1 tile edge (~1 m). +x is screen down-right, +y is screen
  down-left, z is up.
- `screen_x = (x − y)·W/2`, `screen_y = (x + y)·W/4 − z·(W/√2)·cos30°`,
  where W is the tile width in px.
- One sun for every asset: from screen-left and slightly toward the viewer,
  ~51° high. Shadows fall back and to the right.

Both sets render **the same 3D models**, so proportions are identical between
asset families (art bible §14). Only the pixel density changes.

## Pipeline per sprite

1. Ray-march at 3× supersampling, using a numba-compiled SDF interpreter
   (`sdf.py`).
2. Shading: albedo from procedural materials (`materials.py`), Lambert sun
   with soft shadows, sky/bounce hemisphere ambient, and ambient occlusion.
3. Box-downsample to native resolution. Alpha is binary (classic sprite
   cut-outs).
4. Dark silhouette outline, plus crease lines at depth discontinuities.
5. Colour quantised to 5 bits per channel (RGB555, the colour depth of
   original UO art).
6. Ground shadow written to a separate `*_shadow.png`. The game composites
   all shadows into one layer so overlapping shadows don't double-darken.

## Outputs (`game/assets/generated/t<W>/manifest.json`)

- `sprites.<name>`: file, shadow file, size, `pivot` (the ground anchor in
  px), and `anchors`, which are named points as px offsets from the pivot
  (for example `chimney_top` and `flame`).
- `animations.<actor>`: `frame_size`, `pivot`, `directions` (row order
  S, SW, W, NW, N, NE, E, SE), and per-animation sheets. Every frame carries
  anchors; the player's include `blade_base`, `blade_tip` and
  `blade_visible`, which depth-test whether the blade is behind the body.
  The game uses them to draw the separate sword-energy effect.
- `terrain`: seamless world-periodic atlases. `grass` is a P×P block.
  `dirt` and `water` hold 15 corner masks × P² variants each.
  Mask bits: top=1, right=2, bottom=4, left=8.

## Files

- `models/nature.py`: trees, bushes, rocks, stumps, flowers, tufts
- `models/buildings.py`: cottage (stone, timber frame, stepped tile roof)
- `models/props.py`: fences, barrel, crate, signpost, lamp post, logs, trough
- `models/characters.py`: posable adventurer (walk cycle) and sheep
- `terrain.py`: ground tiles and transitions
- `build.py`: catalogue and build entry point. Prop collision lives here
  and is exported to `game/data/props.json`.
