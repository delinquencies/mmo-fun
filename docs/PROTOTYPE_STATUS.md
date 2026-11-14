# Milestone 1 Status: Isometric Visual Laboratory

Status of the first assignment in the brief (Part III). Sections keep
**implemented and verified**, **implemented but unverified**, and
**proposed** work separate.

## 1. Implemented and verified

"Verified" here means the item ran in Godot 4.3 (software OpenGL under
Xvfb, no GPU) and was inspected in captured screenshots
(`docs/images/`). Interactive input on real hardware has not been tested
(see §2).

| Brief requirement (§4) | Implementation | Evidence |
|---|---|---|
| 1. Small outdoor medieval environment | 40×40-tile homestead: cottage, fenced paddock, forking dirt paths, river with rocky bank, woodland edge | `homestead_t64_zoom1.png` |
| 2. One controllable player | Adventurer based on the Melanie concept: dark curly hair, warm complexion, olive and brown gear, cloak, sword | `homestead_t64_zoom2.png` |
| 3. 8-direction movement and facing | 8 facings × idle (4 frames) and walk (8 frames) sheets; keyboard and hold-right-mouse movement | `readability_t64.png`, `readability_t96.png` |
| 4. Correct placement and depth sorting | Point y-sort for props and actors. The cottage is sliced into half-tile strips, each sorted at its footprint's front edge. The building fades while it hides the player. | `sorting_debug.png` |
| 5. Camera follows player | Camera2D locked to the player, pixel-rounded | all screenshots |
| 6. Trees, obstacles, cottage, props | 4 tree types, 3 bushes, 3 rocks, stump, flowers, grass tufts, fences, barrel, crate, signpost, 2 lamp posts, log pile, trough, sheep | `homestead_t64_zoom1.png` |
| 7. Adjustable zoom | 0.5×, 1×, 1.5×, 2×, 3×, 4× with nearest-neighbour filtering | `homestead_t64_zoom1.png` (1×), `homestead_t64_zoom2.png` (2×) |
| 8. Compare native resolutions | Tab switches 64×32 / 96×48. C shows both side by side; M switches between native pixels and matched world scale. | `compare_native.png`, `compare_matched.png` |

Also implemented:

- **Collision** in world units: water, footprints and trunks, with
  slide-along-walls movement.
- **Ambient life**: sheep wander and graze inside the paddock; chimney smoke;
  brazier flames.
- **Sword energy** as a separate runtime effect (brief §12). It is drawn from
  per-frame blade anchors and is ordered behind the body when the forge's
  depth test says the blade is hidden.
- **Shadows**: baked per sprite, then composited in one layer.
- **Debug overlays**: tile grid, collision shapes, and sort anchors.
- **Tooling**: hot reload (F5) and a headless screenshot mode.

## 2. Implemented but not verified

- **Real-hardware performance.** Measured only under software rendering
  (llvmpipe): ~30 FPS in single view at 2×, and 3–10 FPS in compare mode
  (two full viewports). These numbers say nothing about GPU performance.
  Profile on target hardware.
- **Interactive input.** Keyboard, mouse-hold walking, run, and toggles are
  coded but were exercised only through command-line automation. Movement
  and walk animation were checked via `--walk`. Please play-test.
- **Running animation** reuses the walk cycle at 1.75× speed. There is no
  dedicated run cycle.

## 3. Calibration findings

The brief treats tile size and character height as provisional. These are
observations for the director to decide on, not decisions.

| | 64×32 set | 96×48 set |
|---|---|---|
| Character, head to foot | **72 px** | **108 px** |
| Cottage sprite | 388 × 351 px | 578 × 522 px |
| World visible at 1280×720, zoom 1× | ~20 × 22 tiles | ~13 × 15 tiles |

- Both sets render the **same 3D models**, so proportions match exactly. The
  brief's targets (~70 px and ~100 px) can't both hold at identical
  proportions: 70 px at 64 implies 105 px at 96. The current model is
  ~1.8 tiles tall including hair volume.
- **64×32 at native 1×**: silhouette, hair mass, cloak, sword and facing all
  read. The face is only ~6 px, so expression and features are lost. This
  matches how the original UO played. Belts, boots and the brass buckle
  merge into colour blocks.
- **96×48 at native 1×**: equipment separates clearly (buckle, bracers, boot
  cuffs, cloak edge), and the stone courses and roof tiles read
  individually. The cost is a much smaller view of the world at the same
  window size. Matched-world-scale mode (M) shows 96-px art downscaled
  to 64-px world size.
- **Our read**: 64×32 is closest to the brief's late-90s feel and the
  approved homestead framing at 2× zoom. 96×48 holds the brief's character
  goals (readable weapons, differentiated equipment) better. A middle size,
  such as 80×40 (~90 px character), costs one forge run to evaluate:
  `SETS` in `build.py` plus `SETS` in `main.gd`.

## 4. Deviations and assumptions (please confirm)

- **Assets are procedural stand-ins**, not Blender renders. The Sprite Forge
  (`tools/forge/`) follows the same camera, scale and sun contract so the
  game code doesn't change when real assets arrive. They are calibration
  art, not production art.
- **Camera**: exactly 30° elevation, which gives the exact 2:1 diamond the
  brief specifies.
- **Lighting**: one fixed sun from screen-left, slightly toward the viewer.
  Shadows fall back and to the right.
- **Colour**: quantised to RGB555 for period-authentic banding.
- **Diagonal keys** (e.g. Up+Right) move along tile axes, as in classic
  isometric games, so that facings match the 8 rendered directions exactly.
- **Brief sections not yet represented**: no blacksmith asset (that
  reference informed style only), no hanging shop sign, and no well.

## 5. Proposed next steps (not started)

1. Director review of the screenshots, then a choice of native resolution
   (or an 80×40 trial).
2. Replace the forge stand-ins one family at a time with Blender renders
   that use the same manifest contract. Start with the character, since
   that's where the procedural limits show most.
3. Character art: dedicated run cycle, idle variety, and a face-readability
   pass at the chosen size.
4. Roof handling for interiors, UO-style (hide the roof when inside).
5. A performance pass on target GPUs, plus chunked ground drawing for
   larger maps.
6. Only after the visual direction is locked: the authoritative-server
   prototype. `WorldSim` is already separated from presentation for that
   step.

Combat, classes, skills, crafting and economy have **not** been designed or
implemented, per brief §3.
