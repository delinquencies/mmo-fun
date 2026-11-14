# Project State

_Last updated: Slice 002, "The World Responds"_

| Slice | Theme | Status |
|---|---|---|
| 001 | Isometric visual lab: world, movement, sorting, camera, zoom, 64/96 resolution comparison | Done ([report](docs/PROTOTYPE_STATUS.md)) |
| 002 | Interaction: door, chest, ground items, inventory, equipment, tactile UI | **Done**. All acceptance tests pass (see below). |

Native resolution (64×32 vs 96×48) is **still an open director decision**.
Everything in Slice 002 works with both sets.

## Slice 002: what was built

**Authoritative layer** (`game/scripts/sim/`, no rendering code):

- `ItemDefinition` (data: `game/data/items.json`) and `ItemInstance`, which
  carries a unique uid and a stack quantity.
- `ItemStore`: the single owner of item state. It records exactly one
  location per item and checks invariants after every change.
- `ContainerComponent`:
  - Backpack: 15 slots.
  - Chest: 8 slots, with capacity rules.
- `EquipmentComponent`: main hand, plus an off hand that is reserved.
- `ItemTransferService`: `plan()` validates with no side effects;
  `commit()` mutates. Handles splitting, merging, and equip swaps.
- `InteractionCommand` → `InteractionSystem.submit()` → `CommandResult` plus
  events. Commands serialise to JSON for a future server.
- `Interactable`: doors and chests (data: `game/data/interactables.json`).
  Doors switch between closed and open collision; chests open, close, and
  auto-close when the player walks away.

**Presentation** (`game/scripts/view/`, `game/scripts/ui/`, `game/scripts/audio/`):

- **Picking**: pixel-accurate hover with highlight. Single-click shows the
  name; double-click uses the object.
- **Cursors**: default, in range, out of range, dragging, forbidden.
- **Windows**: draggable leather/timber backpack, chest and equipment windows
  with close buttons, a pop-in animation, and I/P toggles.
- **Drag and drop** between any two of ground, backpack, chest and equipment.
  Slots preview green or red using the real validator. A ground marker shows
  where a drop will land. Shift-drag moves one item from a stack.
- **Tooltips**: parchment, showing name, description, equip slot, stack size
  and uid.
- **Feedback**: floating text and a journal. Refused drops flash the slot red.
- **Sounds**: 13 placeholder events (door, chest, pickup, place, coins, equip,
  unequip, invalid, window, click), remappable in
  `game/data/audio_events.json`.
- **Equipped weapon on the character**: a per-animation overlay layer that is
  occluded correctly in all 8 facings, at both resolutions.
- **UI scale**: F2 cycles 1×, 1.5×, 2×.

**Art (forge)**:

- Cottage with hollow walls, a carved doorway and a plank floor.
- 4-frame door swing and 4-frame chest lid.
- Iron sword, gold coins, red apple and healing potion, as ground sprites and
  as inventory icons.
- Unarmed body sheets plus an iron-sword overlay.
- Procedural UI art (`ui_art.py`) and synthesised sounds (`sfx.py`). No
  third-party assets.

**Test scene**: the existing homestead map, extended with the working cottage
door, a chest inside the cottage (25 gold coins, 3 apples, 1 potion), the
iron sword on the grass near the path, the backpack and the equipment panel.

**Starting state changed**: the player now starts **unarmed**. The magic blue
blade from Slice 001 is a reusable effect; press E to preview it on a held
weapon.

## Verification

Everything below was **run**, not just written.

| Suite | How | Result |
|---|---|---|
| Sim / transfer invariants | `godot --headless --path game --script res://tests/run_tests.gd` | **79 checks, 0 failures**. 12 tests, including a 3,000-step random-transfer fuzz with stale requests |
| Acceptance via real input, 64×32 | `--scenario=acceptance` under Xvfb (synthetic mouse/keyboard → GUI → commands) | **43 checks, 0 failures** ([log](docs/images/slice002/acceptance_t64.log)) |
| Acceptance via real input, 96×48 | same, `--set=t96` | **43 checks, 0 failures** ([log](docs/images/slice002/acceptance_t96.log)) |

Directive tests and how they were covered:

| Test | Sim tests | UI scenario | Screenshots |
|---|---|---|---|
| 01 Door (open, walk through, close, collision) | ✓ | ✓ | `t64_01_door_hover`, `t64_02_door_open` |
| 02 Item pickup (enters backpack, leaves world) | ✓ | ✓ (drag from ground) | `t64_06_sword_on_ground` |
| 03 Equip (inventory, slot, on-character) | ✓ | ✓ | `t64_07_equipped`, `t96_07_equipped` |
| 04 Chest transfer both ways, no loss | ✓ | ✓ | `t64_04_apples_in_backpack` |
| 05 Distant chest / invalid destination | ✓ | ✓ (too far, reserved slot, wrong slot) | `t64_05_too_far`, `t64_08_invalid_drop` |
| 06 Rapid input, no duplication | ✓ (25× resubmit, stale drops, fuzz) | ✓ (6× double-click, repeated drags) | n/a |
| 07 Windows move, close, reopen without interrupting the character | n/a | ✓ (the character kept walking during a window drag) | `t64_10_ui_scale_1_5` |
| Definition of Done path | ✓ | ✓ | `t64_09_dropped` |

Screenshots: `docs/images/slice002/`.

## Known limitations and issues

- **Real mouse, sound and GPU playback are untested.** The verification
  above used synthesised input under software rendering (Xvfb + llvmpipe,
  20–30 FPS). Placeholder sounds were triggered, but nobody has listened to
  them. A human play-test is the next step.
- **Interiors**:
  - Walking into the cottage fades the whole building to about 32%. There is
    no roof removal and no interior art yet, so the inside reads as murky.
  - The chest is hard to see from inside. Picking still works, and the name
    appears on click.
- **Stacks**: Shift-drag moves exactly one item. There is no "move how many?"
  prompt.
- **Weapon presentation**: only the iron sword has an overlay. Each new
  weapon needs an overlay sheet from the forge. That is automatic given a
  model.
- **Off hand**: present but reserved. It shows a hatched slot and refuses
  items.
- **Drops into the void**: dropping an item onto HUD text or the help panel
  cancels the drag. The item stays where it was, so nothing can be lost.
- **Sounds**: synthesised placeholders, non-positional except for distance
  attenuation. Replace them with recorded effects.
- **Floating names**: single-click names also go to the journal, which is a
  little noisy.
- **Fractional UI scale**: 1.5× draws slightly uneven pixels; 1× and 2× are
  crisp.
- **Window positions** are not persisted between runs.
- **Single actor**: the sim is written per actor (`actor` on every command,
  per-actor open containers), but only `player` exists today.

## Next decisions for the director

1. **Native resolution:** 64×32, 96×48, or trial 80×40.
2. **Interior presentation:** roof cut-away or a separate interior view.
3. **Real audio:** recordings to replace the placeholders.
