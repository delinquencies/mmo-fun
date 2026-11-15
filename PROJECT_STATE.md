# Project State

_Last updated: Slice 004, "The World Remembers"_

| Slice | Theme | Status |
|---|---|---|
| 001 | Isometric visual lab: world, movement, sorting, camera, zoom, 64/96 resolution comparison | Done ([report](docs/PROTOTYPE_STATUS.md)) |
| 002 | Interaction: door, chest, ground items, inventory, equipment, tactile UI | Done. Still passes all 43 UI checks after Slice 003. |
| 003 | Multiplayer: dedicated authoritative server, two-player shared world | Done. Still passes all 93 multiplayer checks after Slice 004. |
| 004 | Persistence: accounts, characters, PostgreSQL, durable inventory and world | **Done**. See below. |

Native resolution (64×32 vs 96×48) is **still an open director decision**.
Everything in Slice 002 works with both sets.

## Slice 004: what was built

Architecture, schema, policies, save and recovery rules, and security are in
[docs/PERSISTENCE.md](docs/PERSISTENCE.md). Setup and launch are in
[docs/MULTIPLAYER_TESTING.md](docs/MULTIPLAYER_TESTING.md).

- **PostgreSQL schema with versioned migrations** (`db/migrations/`).
  - One row per item instance, so an item has exactly one location.
  - Constraints enforce single location, slot and equip uniqueness (deferred,
    so swaps work), positive quantities, stack limits and capacity.
  - Character-ownership foreign keys; an `item_ops` idempotency log; world
    objects with policies.
- **Keeper** (`tools/keeper/keeper.py`): the trusted loopback-only process
  for database and authentication work. It uses psycopg 3 and argon2-cffi.
  - It exists because Godot has no PostgreSQL driver and no Argon2id.
  - It requires a shared secret and uses parameterised SQL in one transaction
    per operation.
  - Rate limits and account lockout; tokens are stored only as SHA-256.
  - Dev cluster and secrets via `tools/db/dev_db.sh`, plus `docker-compose.yml`.
- **Accounts**
  - Register, log in, log out, and resume after a dropped connection with an
    in-memory token.
  - Generic login errors, timing-equalised for unknown users.
  - Passwords hashed with Argon2id.
- **DTLS on every client connection.** The client pins the server
  certificate (generated for development in `.dev/tls`).
  - The server refuses non-loopback binds without TLS.
  - The client won't send a password unencrypted to a non-loopback host.
- **Characters**
  - Up to 3 per account: stable id, documented name rule (unique,
    case-insensitive), cloth-colour appearance via a shader (5 variants, no
    new art), basic attributes, timestamps.
  - Login window, character selection and creation windows, "Leave world"
    and "Log out", all in the existing leather/parchment UI.
- **World entry.** In order:
  1. authenticate;
  2. claim the character (ownership check plus an exclusive lock);
  3. load it, with spawn validation and a documented safe fallback;
  4. load its inventory and equipment;
  5. spawn and replicate it.

  Duplicate login is refused while the first session is active; a new
  session takes over a link-dead character.
- **Durable gameplay**
  - Every item change commits to PostgreSQL *before* it's applied. On failure
    nothing changes and the player is told so.
  - The permanent door state is gated the same way.
  - Positions are checkpointed every 10 s and saved on leave and on graceful
    shutdown.
  - Stale locks are cleared at restart.
  - An unknown commit outcome is resolved by `op_id`, never re-sent.
- **World policies:**
  - **Permanent:** the door, the chest and its contents, the iron sword spawn.
  - **Resettable:** the apples at the trough, restored at each server start.
  - **Temporary:** everything else.
- **Minimal changes to Slices 002–003:**
  - Durable-gate hooks in `ItemTransferService` and `InteractionSystem`.
  - Item versions; `ItemStore.load_rows()` and `unload_actor()`.
  - `PlayerState` gains a character id and appearance.
  - Protocol v2 (realm, auth, chars and left messages; appearance in player
    records).
  - Persistent mode in `GameServer`, behind `--persistent`; temporary mode is
    unchanged.

### Slice 004 verification (all executed)

| Suite | Result |
|---|---|
| `tests/keeper/run.sh`: Keeper against real PostgreSQL | **41/41** |
| `tests/persist/run.sh`: real Keeper and server processes (restarted and `kill -9`ed), PostgreSQL stopped and started mid-test, DTLS clients | **113/113** ([log](docs/images/slice004/persist_tests.log)) |
| `tests/persist/dod_gui.sh`: Definition of Done with two GUI clients over two sessions, server and Keeper restarted in between | **38/38**, twice ([log](docs/images/slice004/dod_gui_run.log), screenshots in `docs/images/slice004/`) |
| Regression: rules, multiplayer, single-player UI | **79/79**, **93/93**, **43/43** |

| Directive test | Result |
|---|---|
| 01 Account creation | ✓ Register, duplicate refused, wrong password and unknown user give the same generic error, logout revokes, log back in, token resume after a drop |
| 02 Character persistence | ✓ Position saved on leave and restored on re-entry; appearance restored and replicated to others |
| 03 Server restart | ✓ Server and Keeper restarted: sword still equipped, 10 coins still in backpack slot 3, door state kept, position restored inside the cottage, coin total unchanged |
| 04 Shared chest | ✓ Bob deposits; Alice sees it live; after a `kill -9` and restart the apples are still in slot 8. Also done through the UI in the GUI run |
| 05 Duplicate login | ✓ Second session refused ("already in the world"); the first keeps control; link-dead takeover works |
| 06 Unauthorized character | ✓ Another account's character id gets `not_found`; another player's equipment or backpack can't be taken (and isn't even replicated); no access before login |
| 07 Concurrent transfer | ✓ Exactly one pickup; the database holds one row for the sword, located in the winner's backpack |
| 08 Database failure | ✓ PostgreSQL stopped: the transfer is refused with "nothing was changed", the database is untouched, logins fail safely; after restart the same transfer succeeds |
| 09 Crash recovery | ✓ Split committed, then `kill -9`: the split survives, totals intact, no duplicates, the stale lock is cleared on restart, the player re-enters immediately |
| 10 Regression | ✓ All Slice 001–003 suites pass: movement, depth sorting, doors, containers, remote movement, equipment visibility, tactile drag-and-drop |

### Slice 004 limitations and risks

- **Not verified:**
  - LAN or two physical machines.
  - Production TLS certificates (only the pinned development certificate).
  - Docker Compose (written, not run here: no Docker daemon available).
  - Windows and macOS.
  - Human play.
  - Load beyond 2–4 clients.
  - The "unknown commit outcome" resolution path. It is implemented, but no
    test forces a Keeper disconnect mid-commit.
- **Item commits block the region's main loop for one localhost
  transaction.** That is typically a few ms, bounded at 2 s if the database
  stalls. It is a deliberate trade-off for strict ordering; an asynchronous
  commit queue is the upgrade path.
- **Positions can roll back up to 10 s on a crash.** Items never roll back.
- **Missing account features:** no account recovery, password change, email,
  character deletion or admin tools. Orphaned world objects need manual SQL.
- **Appearance is cloth colour only.** Richer options need art.
- **Keeper rate limits** live in memory and reset when Keeper restarts.
- **Temporary-session mode** (no `--persistent`) still drops carried items
  on leave, by design, for development use.

## Slice 003: what was built

**How to run:** `tools/net/run_local_mp.sh` starts a server plus Alice and
Bob. Full procedure, including LAN: [docs/MULTIPLAYER_TESTING.md](docs/MULTIPLAYER_TESTING.md).
Protocol and authority: [docs/NETWORK_PROTOCOL.md](docs/NETWORK_PROTOCOL.md).

- **Dedicated server:** `game/scenes/server.tscn` with `GameServer`. It is
  headless, uses ENet, binds to localhost by default, and runs a 30 Hz
  simulation tick with 12 Hz state replication (both configurable).
  - Assigns sessions and spawns characters.
  - Runs movement authority, processes commands, and diffs items per client by
    interest.
  - Handles link-dead and linger on disconnect, a hello timeout and an idle
    timeout.
  - Supports artificial lag, jitter and loss.
- **Client:** `NetClient`.
  - Builds a replica `WorldSim` from a welcome snapshot plus deltas.
  - Predicts local movement with input sequence numbers and reconciles
    against the server.
  - Interpolates remote players 120 ms behind.
  - Offers the same `submit()` / `event_emitted` surface as offline play, so
    the Slice 002 UI works unchanged online.
  - Has a Realm Connection window (F9): address, port, name, connect, leave,
    status and failure text.
  - Shows name labels, a link-lost indicator, an online/RTT line in the HUD,
    and system messages in the journal.
- **Protocol** (`protocol.gd`):
  - Versioned envelopes with typed schemas, validated on both sides.
  - Request ids, with duplicate requests answered from a result cache rather
    than executed again.
  - Explicit `result` messages for every command.
  - Commands: `use`, `set_door`, `close_container`, `transfer`, `pick_up`,
    `drop`, `equip`, `unequip`, `use_item`. Movement is a separate input
    stream.
- **Smallest changes to Slice 002 needed for server authority:**
  - `WorldSim` now holds any number of `PlayerState`s instead of one
    hardcoded player. `player_pos`/`player_facing` remain as aliases for the
    local player, so the offline code and tests are unchanged.
  - `load_map()` can skip item spawning, because replicas get items only from
    the server.
  - `InteractionSystem` gained the explicit command types, a check that the
    actor exists, door-closing obstruction checks against *every* player, and
    `close_all_for()`.
  - `ItemStore` gained `replica_apply()` (client mirror) and `signature()`
    (server diff).
  - `GameUI` takes an `authority` object instead of calling
    `InteractionSystem` directly.
  - `WorldView` draws every player.
  - `main.gd` can switch between the offline world and the replica.
  - **No item or transfer rule is duplicated:** the server runs the Slice 002
    `ItemTransferService` as is. The client only uses its read-only `plan()`
    for drag previews.

### Slice 003 verification (all executed)

| Suite | Result |
|---|---|
| `tests/mp_tests.gd`: real ENet server and two clients in one process | **93 checks, 0 failures** (run 4 times during development; [log](docs/images/slice003/mp_tests.log)) |
| Three separate processes (server, Alice, Bob) with UI input, 60 ms lag, 20 ms jitter, 5% loss on every process | **11/11 checks, both clients exit 0**, clean leaves logged ([log](docs/images/slice003/three_process_run.log), screenshots in `docs/images/slice003/`) |
| Slice 001/002 regression: `tests/run_tests.gd` and the UI acceptance scenario | **79/79** and **43/43** |

Directive tests:

| Test | Result | Evidence |
|---|---|---|
| 01 Two clients | ✓ Distinct sessions; each sees the other's movement at the authoritative position and facing | `t01_two_clients` + three-process run |
| 02 Shared door | ✓ A opens, B sees it; B closes, A sees it; collision agrees on the server and both replicas; repeat close rejected | `t02_shared_door`, three-process run |
| 03 Shared chest | ✓ Both open it; A takes the apples; B's view updates live; A's backpack is never visible to B | `t03_shared_chest` |
| 04 Simultaneous pickup | ✓ Exactly one succeeds; the other gets "That item is no longer there."; totals unchanged | `t04_simultaneous_pickup` |
| 05 Equipment replication | ✓ B sees A equip and unequip; the weapon layer is drawn on A in B's client | `t05_*`, `docs/images/slice003/bob_sees_alice*.png` |
| 06 Invalid movement | ✓ NaN, oversized, malformed and extra-field inputs rejected; no teleport command exists; a 200-input flood is capped at the run speed; B never sees a jump | `t06_invalid_movement` |
| 07 Disconnect | ✓ An unexpected drop leaves the character link-dead, then it is removed. Carried items are left on the ground, not lost. The server keeps running; the client reconnects with a fresh session | `t07_disconnect` |
| 08 Latency | ✓ 120 ms lag, 40 ms jitter, 10% loss: remote motion is coherent (maximum 0.21 tiles/frame), prediction converges, commands resolve, no corruption | `t08_latency`, three-process run |
| 09 Repeated mutations | ✓ The same rid sent 10× executes once; 10 replays with new rids are all rejected as stale | `t09_repeated_mutations` |
| 10 Resource stability | ✓ 30 interaction cycles plus 6 connect/disconnect cycles. No orphan sessions or players, no extra items; node count, object count and memory are flat | `t10_stability` |
| Bonus | ✓ Malformed messages, a wrong protocol version, and taking from another player's backpack are all rejected | `t11_protocol_garbage` |

### Slice 003 limitations and risks

- **Not verified:**
  - Two physical computers on a LAN. Only localhost was run; the bind and
    LAN path is implemented but untested.
  - Windows and macOS.
  - Real human play and feel.
  - GPU performance.
  - Packet loss above 10%.
- **Both players look identical.** It is the same character art; only the
  name labels distinguish them. Appearance variants need art (an art
  dependency, not code).
- **No player-to-player collision.** Characters can overlap.
- **Sheep are client-side ambient decoration.** They are not shared and can
  be in different places on different screens.
- **Temporary sessions own nothing.** A character removed after
  leaving or link-dead leaves its carried items on the ground for anyone
  to take. Persistence (Slice 004) should replace this.
- **Interest management** is a radius test plus a full item diff per change,
  which costs O(items × clients). It is fine for one small region and must be
  replaced by spatial partitioning before large worlds.
  `GameServer._visible()` is the extension point.
- **Excess inputs:** clock drift between a client's 30 Hz input and the
  server tick occasionally drops one input (counted in `excess_inputs`),
  which prediction corrects with a tiny, smoothed adjustment.
- **No authentication or encryption.** The server binds to localhost by
  default, and LAN play requires `--bind`. A session id is not an account.
- **ENet peer timeout is about 6 s,** so an unplugged client is noticed after
  that long, then stays link-dead for the linger time (8 s).

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
- ~~Single actor~~: resolved in Slice 003 (multiple `PlayerState`s).

## Next decisions for the director

1. **Native resolution:** 64×32, 96×48, or trial 80×40.
2. **Interior presentation:** roof cut-away or a separate interior view.
3. **Real audio:** recordings to replace the placeholders.
4. **Player appearance variants** (hair, cloth colours), so two players can
   be told apart without name labels.
5. ~~Slice 004 persistence~~: done.
6. **Next candidates:**
   - Asynchronous commit pipeline.
   - Account management (password change, recovery).
   - Interiors.
   - Richer appearance art.
