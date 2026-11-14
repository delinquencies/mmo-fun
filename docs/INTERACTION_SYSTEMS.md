# Interaction, Items and Inventory (Slice 002)

How the player affects the world: data structures, the command contract, and
the invariants the transfer service guarantees. Code lives in
`game/scripts/sim/` (authoritative), `game/scripts/ui/` and
`game/scripts/view/` (presentation).

## Layers

```
 player input ──► WorldSurface / ItemSlot / GameUI   (client: intent only)
                        │  InteractionCommand (plain data, to_wire() → JSON)
                        ▼
                 InteractionSystem.submit()          (authority boundary)
                   ├─ validate: range, open containers, ownership, slot rules
                   ├─ ItemTransferService.plan()  → no side effects
                   ├─ ItemTransferService.commit() → ItemStore mutation
                   └─ events ──► event_emitted signal
                        ▼
      WorldView (sprites, door/chest frames, ground items, weapon layer)
      GameUI (windows refresh, feedback text) · AudioEvents (sounds)
```

The four stages map directly to the directive's split:

1. **Intent**: an `InteractionCommand`.
2. **Validation**: `InteractionSystem` access rules plus
   `ItemTransferService.plan()`.
3. **Mutation**: `ItemTransferService.commit()` and door/chest state.
4. **Presentation**: everything that listens to `event_emitted` or reads
   state each frame.

Nothing in `ui/` or `view/` writes to `ItemStore`, `Interactable` or
`WorldSim` item state. The UI's live drop preview (green or red slot frames,
the ground marker) calls `plan()`, which validates without mutating.

**Path to multiplayer:** run `InteractionSystem`, `ItemStore` and
`ItemTransferService` on the server. Clients send `cmd.to_wire()`, and the
server broadcasts events. `test_wire_roundtrip` checks that commands survive
JSON serialisation.

## Commands (`InteractionCommand`)

| type | args | Effect |
|---|---|---|
| `use` | `entity`: entity id or `item:<uid>` | Door: toggle open/closed. Chest: open it and show its contents. Ground item: pick up into the backpack. |
| `transfer` | `uid`, `from`, `to`, `qty` (0 = whole stack) | Any item move: ground ↔ backpack ↔ chest ↔ equipment. |
| `use_item` | `uid`, `from` | Double-click. Equippable in a container: equip. Equipped: unequip to the backpack. Ground or chest item: move to the backpack. |
| `close_container` | `container` | Close a chest window. The lid closes when nobody has it open. |

Each command carries `seq`, `type`, `actor` and `args`. `submit()` returns a
`CommandResult` with `ok`, `code`, `message` and `events`. When `ok` is false,
**nothing was mutated**.

### Failure codes

| code | Meaning |
|---|---|
| `too_far` | Outside use range (doors and chests 1.8 tiles; ground items 2.0; an open chest stays usable to 2.6) |
| `stale` | The item is not where the request says it is: a double submit or an outdated drag |
| `no_item` | Unknown uid |
| `not_open` | Chest contents accessed without opening the chest |
| `full` | No free slot and no stack to merge into |
| `stack_full` | Target stack would exceed `max_stack` |
| `cannot_equip` | Item is not made for that slot |
| `reserved` | Slot exists but isn't enabled (off hand) |
| `occupied` | Equip slot full and no source slot to swap into |
| `blocked` | Ground drop point is inside an obstacle, water, or off the map |
| `obstructed` | Door can't close while you stand in it |
| `invalid_dest`, `not_yours`, `bad_qty`, `no_change` | Malformed or no-op requests |

Every failure emits a `failed` event. The client shows the message as
floating text plus a journal line, and plays the `invalid` sound.

### Events (`InteractionSystem.event_emitted`)

| event | Fields |
|---|---|
| `item_moved` | `uid`, `source_uid`, `def`, `from`, `to`, `qty`, `actor` |
| `door_changed` | `id`, `open` |
| `chest_changed` | `id`, `open` |
| `container_opened` | `actor`, `container`, `entity` |
| `container_closed` | `actor`, `container` |
| `equipment_changed` | `actor` |
| `sound` | `name` (an audio event), `pos` (world) |
| `failed` | `actor`, `code`, `message`, `pos` |

## Data structures

### Item locations (`ItemLocation`)
Plain dictionaries, so they serialise directly:

```
{"kind": "container", "container": "player.backpack", "slot": 3}     # slot -1 = any
{"kind": "world",     "pos": Vector2(18.4, 12.2)}                     # [x, y] on the wire
{"kind": "equipment", "owner": "player", "slot": "main_hand"}
```

### ItemStore: the single owner of item state
- `items`: uid → `ItemInstance` (`uid`, `def_id`, `quantity`)
- `locations`: uid → location. **One per item.** Ownership is never inferred
  from UI state.
- `containers`: id → `ContainerComponent` (`capacity`, `columns`, `slots`
  holding uids, `owner_entity`)
- `equipment`: actor → `EquipmentComponent` (`main_hand`, `off_hand`;
  `reserved = ["off_hand"]`)
- `check_invariants()` returns every violation. It runs after **every
  commit**; a violation is reported with `push_error`.

### Definitions
- **Items**: `game/data/items.json`. Fields: `name`, `description`,
  `stackable`, `max_stack`, `equip_slot`, `paperdoll_layer`, `icon`,
  `world_sprite`, and `sounds` (`pickup`, `drop`, `equip`, `unequip`).
- **Interactables**: `game/data/interactables.json`. Fields: `kind` (`door` or
  `chest`), `sprite`, `use_range`, `keep_open_range`, `capacity`, `columns`,
  collision rects (doors have separate `closed_collision` and
  `open_collision`), and `sounds`.
- **Placement**: `game/data/maps/homestead.json`. `entities` lists each `id`,
  `def`, `x`, `y`, and chest `contents`; `ground_items` lists loose items.
  The map is generated by `tools/forge/mapgen.py`.
- **Audio**: `game/data/audio_events.json` maps event names to WAV files.

## Transfer invariants (guaranteed by `ItemTransferService`)

1. Every item has exactly one location, and every occupied slot points back
   to it.
2. Quantities are conserved per item type. Splitting creates a new uid with
   the moved quantity. Merging deletes the source uid only after adding its
   quantity to the target.
3. A transfer is validated against the *current* location (`from` must
   match). The same request can therefore succeed at most once; repeats fail
   as `stale`.
4. A ground item leaves the world only when the transfer commits. Dragging
   leaves it in place.
5. Equipping into an occupied main hand from a container slot swaps the two
   items atomically.

These are tested by `game/tests/run_tests.gd`, which includes a 3,000-step
random-transfer fuzz with stale requests mixed in. The UI path is tested by
`game/scripts/debug/scenario_runner.gd`.

## Presentation notes

- **Picking** is pixel-accurate against the current animation frame. Ground
  items get a 3 px margin. The top-most hit by y-sort wins.
- **Cursors**:
  - Brass arrow: default.
  - Gauntlet hand: an object in range.
  - Grey hand: an object out of range.
  - Fist: dragging.
  - Red slashed circle: forbidden.
- **The weapon on the character** is a separate overlay sheet per animation.
  The forge cuts it from a full render using a material mask, so the body
  correctly hides the blade in every facing. Any future weapon with the same
  animation set needs only a new overlay sheet and a `paperdoll_layer` entry.
- **The blade-energy effect** (`SwordEnergy`) is still separate and reusable,
  but now off by default. E previews it on whatever is held.
- **Sounds** are synthesised placeholders (`tools/forge/sfx.py`). Replace
  any WAV in `game/assets/audio/` with a real recording of the same name, or
  remap it in `audio_events.json`.
