# Character sprite pipeline

How character sprites are produced, why it was rebuilt, and how to make the
next character. Before/after images: `docs/images/character_pipeline/`.

## 1. Audit of the old pipeline

The old character path was the scenery path with a figure in it. Its problems,
in order of visible damage:

| # | Problem | Cause |
|---|---|---|
| 1 | Muddy colour clusters, soft edges | Each sprite pixel was the *average* of 9 continuously shaded samples, then snapped to 15-bit colour. Averaging across a material edge invents in-between colours that belong to neither surface. |
| 2 | Noisy "dither" inside every surface | Materials were 3D noise functions. At 73 px a noise octave is one pixel wide, so cloth and skin became speckle. |
| 3 | Texture changed between facings and crawled during animation | That noise was evaluated in *world* space after the figure was rotated and posed, so the same sleeve got a different pattern in every direction and every frame. |
| 4 | Sausage anatomy | Limbs were capsules joined by a hard union: a crease at every joint, no flow from thigh to knee to calf. |
| 5 | Flat, single-light shading | One sun plus sky ambient. The side away from the sun lost its form, and nothing lifted the silhouette off the grass. |
| 6 | Uniform near-black outline | Applied to every edge at the same strength, which ate two of the figure's ~24 pixels of width and made thin weapons darker than the body. |
| 7 | Pose, costume and palette tangled in one function | A new character meant copying the function; a new animation meant editing every character. Running reused the walk cycle. |
| 8 | No production checks | Nothing verified frame sizes, pivots, ground contact, anchors or determinism. |

What was already sound and is kept: one 3D figure rendered through one fixed
orthographic camera for all 8 facings; a fixed frame size and pivot per
character; weapon layers cut from a full render so occlusion is exact;
per-frame anchors; binary alpha.

The reshape made just before this work (long legs, thin tapered limbs) made
things worse at game size: with the old renderer, thin limbs turned into
broken dark lines. It is replaced by the build below.

## 2. The new pipeline

```
CharacterSpec ──┐
(proportions,   │      charkit.build()        render_sprite()            build.py
 tone ramps,    ├──► solved 3D figure ──► finished frame (pixel art) ──► sheets + manifest
 costume)       │    (rig + anatomy +       key / fill / rim / AO,        validate_sprites.py
Pose (a clip) ──┘     costume + weapon)     one ramp tone per pixel,
                                            selective line work
```

**Files**

| File | Role |
|---|---|
| `tools/forge/charkit.py` | Rig, proportions, animation clips, body and costume builder |
| `tools/forge/models/characters.py` | Character definitions: `ADVENTURER`, `BANDIT_SPEC` (palettes and options only) |
| `tools/forge/materials.py` | `PaletteMaterial`: a hand-picked tone ramp per material |
| `tools/forge/sdf.py` | Smooth-blend groups for organic joins |
| `tools/forge/render.py` | `render_sprite()`: lighting, tone selection, pixel finishing |
| `tools/forge/build.py` | Sheets, weapon layers, anchors, manifest (`style: "sprite"`) |
| `tools/forge/validate_sprites.py` | Production checks |

### What changed technically

1. **Consistent geometry.** A character is a `CharacterSpec`; a frame is a
   `Pose`. `charkit.solve()` runs forward kinematics once, `charkit.build()`
   dresses the result, and that one figure is rotated for the 8 facings. No
   material depends on world position any more, so nothing about the costume
   can differ between directions or frames. Weapons attach at the solved hand
   joint.
2. **Anatomy.** Primitives in a blend group are joined with a smooth minimum
   (`blend=(group, radius)`), so thigh, knee, calf and ankle are one surface,
   as are torso and shoulders. The default build is a sturdy figure of about
   6.5 heads: at 73 px, mass reads and thin limbs do not.
3. **Lighting.** Key light (the world's sun, with soft self-shadow), a cool
   fill from screen right, a rim light from behind that lifts the far edge of
   the silhouette, sky term, and ambient occlusion. Polished leather and metal
   get a highlight step.
4. **Intentional pixels.**
   - Every material is a ramp of 5 chosen tones (shadows lean cool, lights lean
     warm). Lighting selects a tone; nothing is blended, dithered or noised.
   - A sprite pixel takes the *most common* (material, tone) among its 16
     samples. Tiny features flagged `detail` (eyes, buckle) get extra weight so
     they survive.
   - Single stray pixels are removed.
   - Line work is selective: the silhouette is drawn in the material's own dark
     tone (not black); where one part overlaps another, the part behind drops
     a tone, two for a large gap; where two materials meet on one surface, the
     seam is one consistent pixel. One-pixel-wide features and blades are never
     outlined.
5. **Animation.** Clips are functions from time to `Pose`: `clip_idle`,
   `clip_walk`, `clip_run` (new: long stride, high recovering knee, forward
   lean, pumping bent arms), `clip_attack`, `clip_shoot`. Every character
   built on the kit gets every clip. The cloak is two blended panels with
   folds and trails with speed. The game now plays `run` when running.
6. **Output.** Unchanged contract, now checked: one PNG per animation, 8 rows
   (S, SW, W, NW, N, NE, E, SE) by N frames, fixed frame size and pivot per
   character, matching shadow sheet and weapon-layer sheets, anchors per frame
   in the manifest, alpha strictly 0 or 255.

Legacy materials still work in the sprite renderer: a tone ramp is derived
once from the material's average colour and cached, which is how the existing
sword and bow models are finished without being rewritten.

## 3. Blender: tested, and what it would and would not fix

**Test.** The benchmark character was exported as a mesh (marching cubes over
the same model), coloured per material and rendered in Blender 5.3 (Cycles,
CPU) through the same camera contract, then reduced to sprite size. Scripts:
`tools/blender/`. Image: `docs/images/character_pipeline/blender_comparison.png`
(rows: old sprite, Blender, new pipeline; left at game size, right enlarged).

**Result.**
- Blender's render of the same model is clean and correctly lit, and soft: at
  73 px its anti-aliased gradients read as modern low-poly 3D, with no line
  work and less separation between parts than the new sprites.
- So the renderer was not what held the old sprites back. The damage came from
  the model, the materials and above all the step from samples to pixels.
- Speed is not an obstacle: 8 facings took about 42 s on CPU here.

**What Blender would add** is authoring, not rendering: sculpted anatomy,
real cloth, hand-keyed or motion-captured animation, and a normal way for an
artist to work. None of that exists in a procedural kit.

**Recommendation: hybrid, in this order.**
1. Keep the kit for characters now. It is deterministic, needs no assets, and
   a new character is a palette and a few options.
2. When an artist-made rigged model exists for a hero character, render it in
   Blender to material-index, normal, depth and shadow passes, and feed those
   to the same finishing step (tone ramps, majority vote, line work, sheets,
   validator). The finishing step is where the look comes from, so both
   sources would match.
3. Not built yet: the pass exchange between Blender and the finisher.
   `render_sprite()` currently shades its own samples. Splitting it into
   "produce passes" and "finish passes" is the first task of that work.

## 4. Making a new character

```python
# tools/forge/models/characters.py
RANGER = charkit.CharacterSpec(
    name="ranger",
    prop=charkit.Proportions(bulk=1.1, shoulder_w=0.23),     # optional
    skin=P("#5a3220", "#86523a", "#ae7650", "#cc9568", "#e4b488"),
    tunic=P(...), sleeve=P(...), leather=P(...), trousers=P(...),
    boots=P(...), cuff=P(...), metal=_BRASS, eye=_EYE,
    hood=P(...),            # or hair=P(...); cloak=P(...), cloak_trim=P(...)
)
SPECS["ranger"] = RANGER
```

Add it to `CREATURES` and `SPRITE_STYLE` in `build.py` (the bandit is the
worked example), then:

```bash
python3 tools/forge/build.py --only ranger
python3 tools/forge/validate_sprites.py --names ranger --determinism
```

Rules for ramps: 5 tones, dark to light; neighbouring materials should differ
in value, not only in hue; keep the darkest tone well above black so the
outline stays coloured.

## 5. Known limits of this slice

- **Cloth is rigid panels.** The cloak bends at one joint and trails with
  speed, but in the run it still reads as a board. Real cloth needs either
  more panels driven by the motion or a simulated mesh (a Blender strength).
- **The sword attack is weak.** The clip carries over the old swing angles;
  wind-up and follow-through need a pass with body rotation and a step.
- **Flat surfaces shade flat.** A cloak seen square-on gets one tone. A
  per-material pattern (folds, weave) defined in the figure's own space would
  fix this without bringing back world-space noise.
- **Faces are two eye pixels and a nose shadow** at 73 px, as in the games
  this follows.
- **The skeleton, wolf and sheep still use the old renderer.** The skeleton is
  built on its own model with the lean proportions; it should move onto the
  kit as a spec with a bone costume.
- **Characters are cleaner than the scenery.** The environment keeps its
  noise-textured materials, so figures now read as slightly more graphic than
  the ground they stand on. That separation helps readability, but the
  scenery's small props would benefit from the same finishing step.
- **Build time went up:** about 15 minutes for the player on the 64×32 set and
  about 45 on 96×48 (16 samples per pixel, five animations, three weapon
  layers), on 4 CPU cores.

## 6. Verification (all executed, automated)

`python3 tools/forge/validate_sprites.py --determinism`: **0 problems** on
both sets.

| | Old renderer (skeleton, for reference) | New pipeline (player) |
|---|---|---|
| Colours in the sheets | 473 | 66 |
| Pixels with no same-colour neighbour | 63% | 5.5% (64×32), 3.5% (96×48) |
| Frame size and pivot, 64×32 | 282×207, (125, 143) | 282×207, (125, 143): unchanged |
| Idle ground contact across 8 facings | – | −1..+4 px of the pivot row |
| Two renders of one frame | – | byte-identical |

Game runs at 1920×1080 on the new sprites: UI acceptance 45/45 on the 64×32
set and 45/45 on the 96×48 set, combat walkthrough 16/16 (weapon layers,
energy anchors, bandit), display scenario 33/33, rules 79/79, combat rules
60/60.

Not verified: a human eye on a real monitor; the multiplayer and persistence
suites were not re-run (no code they use changed).
