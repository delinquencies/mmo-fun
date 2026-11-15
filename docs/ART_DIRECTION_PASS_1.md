# Art pass 1: toward the approved homestead

Scope: art only. No gameplay, collision, anchor, sorting, overlay or network
code changed. The camera and projection contract (`tools/forge/render.py`,
`game/scripts/core/iso.gd`) is untouched, and every sprite keeps its canvas
size and pivot, so the manifests' geometry is identical to before.

Before/after screenshots: `docs/images/art_pass_1/`.

## 1. Assessment (before this pass)

Compared side by side with `docs/reference/approved_homestead.png` at gameplay
scale, the prototype read as calibration art for six reasons, in order of
damage:

1. **The player disappeared into the grass.** Olive tunic, olive cloak and
   dark brown limbs on saturated green ground: one dark shape, face and hair
   merged, no separation between pieces of gear.
2. **Grass was fur.** Long vertical streaks in a single saturated lime, with
   no mottling, clumps or bare patches. It was the largest surface on screen
   and the least like the reference.
3. **Trees were sphere clouds on sticks.** Thin trunks, one noisy ball of
   canopy: exactly the "smooth spherical canopies" the art bible rules out.
4. **Shadows were a tile and a half long** and dark, so every tree sat on a
   large dark diamond that fought the terrain.
5. **Materials were averaged out.** Roof tiles, stones and wood grain existed
   but at low contrast: no course shadows on the roof, small uniform stones,
   faint grain.
6. **UI frames were plain** leather with rivets; no metal or carved trim.

## 2. Scale recommendation

**Stay on 64×32.** I agree with the director's instinct.

- At the default 1.5× zoom the character is about 108 screen pixels tall, and
  after this pass its gear separates clearly. The remaining readability
  problems were value and silhouette problems, not resolution problems.
- 64×32 keeps roughly twice the visible world of 96×48 at the same window
  size, which is what gives the late-UO sense of place.
- 96×48 stays in the build as the sharper option for 1440p and 4K displays.
  Both sets render from the same models, so the choice remains reversible.

## 3. Plan

| Priority | Work | Status |
|---|---|---|
| 1 | Player readability: value-separated gear, visible face, dark hair mass, cloak with a pale hem | **Done (this pass)** |
| 2 | Ground: mottled meadow, tan trodden paths with ragged tufted edges | **Done** |
| 3 | Trees and bushes: trunks that fork into limbs, layered leaf masses, leaf-spray texture, olive / moss / yellow-green mix | **Done** |
| 4 | Shadows: compact pools under objects, lighter | **Done** |
| 5 | Cottage materials: coursed clay roof tiles, larger irregular masonry with warm and cool stones, stronger timber grain | **Done** |
| 6 | Rocks, wood props (fences, barrel, crate, signpost) | **Done** (through shared materials) |
| 7 | UI trim: brass corner plates, tooled leather, carved title rail | **Done** |
| 8 | Lived-in dressing: woodpile against the wall, path-side weeds, worn ground at the door and gate, a well or cart | Next |
| 9 | Character animation polish: flinch frames, a real run cycle, cloak folds | Next |
| 10 | Creatures: wolf and skeleton material pass to the same standard | Next |
| 11 | Water and river bank: reeds, stones in the shallows, softer shoreline | Next |
| 12 | Hand-finish or model the hero assets in Blender, as the art bible's pipeline describes | Later; needs a decision |

## 4. What changed and why

**Player (`tools/forge/models/characters.py`).** Each piece of gear now sits
in its own value and hue band: cream linen sleeves, khaki-olive tunic, tan
leather bodice, bracers and boot cuffs, umber trousers, darker boots, and a
russet cloak with a pale gold hem and a brass clasp. Skin is lighter and
warmer so the face reads; hair is a near-black curly mass, fuller at the back
and sides and kept off the face. The concept is unchanged (dark curly hair,
warm complexion, olive and brown gear, blue energy sword). The bandit's
palette was lifted the same way (grey cloth, rust hood) so it reads as "not
the player" at a glance.

**Ground (`tools/forge/terrain.py`).** Grass is now a mottled meadow: broad
drifts, clumps with dark roots between them, lit tuft tips, short blade
flecks, dry yellowed drifts, bare earth and occasional tiny wildflowers, in
olive rather than lime. Paths are a lighter trodden tan with fine grit and
small rimmed stones, and their edges are ragged where grass bites in.

**Trees, bushes, rocks (`tools/forge/models/nature.py`, `noise.py`).** Trees
have a stout trunk with root flare that forks into visible limbs, each
carrying a flattened leaf mass with smaller sprays breaking its outline.
A new 3D cellular pattern (`cells3`) draws each spray of leaves lit on top and
dark where it tucks under its neighbour. Three palettes (olive, warm
yellow-green, cool moss) mix within one crown. Rocks are faceted, lighter and
cracked, with warm and cool faces.

**Shadows (`tools/forge/render.py`, `world_view.gd`).** Ground shadows are
cast from a steeper sun than the one used for shading, so they sit under the
object. The shadow layer is lighter (30% instead of 42%) and slightly green
rather than blue-black. Sprite canvases are unchanged.

**Cottage and wood (`models/buildings.py`, `materials.py`).** Roof tiles are
laid in clear courses: individual tile colours, a shadow under the course
above, a lit lower lip, the odd weathered tile, moss near the eaves. Masonry
has larger irregular stones, deeper joints, a lit top edge on each stone and
restrained warm and cool variation. Plaster is lighter; all timber has longer
grain with dark checks.

**UI (`tools/forge/ui_art.py`).** Panels are tooled leather with a pressed
inner line, raised stitching and worn brass corner plates. Title bars are
carved timber rails with a gilt inlay line and brass end caps. Nine-slice
margins and all sizes are unchanged, so no layout code moved.

## 5. Regenerated

Everything the forge renders, for both sets, because the changes are in
shared materials and lighting: terrain, props, the cottage, door and chest,
ground items and icons, the player with its three weapon layers, the bandit,
wolf, skeleton and sheep. UI textures were regenerated with `ui_art.py`.
Sounds, maps and data files were not touched.

## 6. Known weaknesses after this pass

- All of it is still procedural forge art. It is closer to the reference in
  colour, value structure and material, but it does not have the reference's
  hand-drawn leaf shapes, window detail or prop charm.
- Tree shadows are still hard-edged shapes.
- The wolf, skeleton and sheep only inherited the lighting and shadow
  changes; their materials were not reworked.
- The hit reaction is still a red flash, and running still reuses the walk
  cycle.
