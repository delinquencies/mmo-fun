# Project State

_Last updated: character pipeline v2 (after art pass 1)_

| Slice | Theme | Status |
|---|---|---|
| 001 | Isometric visual lab: world, movement, sorting, camera, zoom, 64/96 resolution comparison | Done ([report](docs/PROTOTYPE_STATUS.md)) |
| 002 | Interaction: door, chest, ground items, inventory, equipment, tactile UI | Done. Still passes all 43 UI checks after Slice 003. |
| 003 | Multiplayer: dedicated authoritative server, two-player shared world | Done. Still passes all 93 multiplayer checks after Slice 004. |
| 004 | Persistence: accounts, characters, PostgreSQL, durable inventory and world | Done. Still passes all 143 persistence checks after Slice 005. |
| 005 | Combat: targeting, melee, bow, lightning sword, three creatures, death, loot, skills | **Done**. See below. |

Native resolution (64×32 vs 96×48) is **still an open director decision**.
Everything in Slice 002 works with both sets.

## Character pipeline v2

Audit, pipeline, Blender test, how to add a character, limits and
verification: [docs/CHARACTER_PIPELINE.md](docs/CHARACTER_PIPELINE.md).
Images: `docs/images/character_pipeline/`.

- **Built:** a character kit (rig, proportions, clips incl. a real run,
  costume builder), tone-ramp materials, a sprite finisher (key/fill/rim/AO
  lighting, one tone per pixel by majority vote, selective line work), and a
  sprite validator. Player and bandit use it; both sets regenerated.
- **Blender:** tested with the same character (Cycles, same camera). The
  renderer was not the limit; recommendation is a hybrid once an artist-made
  rigged model exists.
- **Verified:** validator 0 problems, deterministic; acceptance 45/45 on both
  sets, combat 16/16, display 33/33, rules 79, combat rules 60.
- **Not done:** skeleton, wolf and sheep on the new path; cloth; a stronger
  attack clip.

## Art pass 1: toward the approved homestead

Assessment, scale recommendation (stay on 64×32), prioritized plan, changes
and verification: [docs/ART_DIRECTION_PASS_1.md](docs/ART_DIRECTION_PASS_1.md).
Before/after: `docs/images/art_pass_1/`.

- **Done:** player readability, meadow and paths, trees, bushes and rocks,
  compact lighter shadows, cottage roof, stone and timber, UI trim. Both sets
  regenerated; canvas sizes, pivots, anchors and collision unchanged.
- **Verified:** acceptance 45/45 on both sets, combat 16/16, display 33/33,
  rules 79, combat 60, multiplayer 93.
- **Next:** lived-in dressing, animation polish, creature materials, water
  edge; then a decision on hand-finished or Blender hero assets.

## Corrective: game scale and readability

Full description and verification: [docs/DISPLAY_SCALING.md](docs/DISPLAY_SCALING.md).

**Cause.** The game drew in raw pixels: stretch was disabled and the
interface had no scale by default.
- Text was 10–14 px.
- Only the inventory windows could be scaled, and they were bitmap-scaled
  (`Control.scale`).
- On HiDPI (Retina or 150–200% Windows) screens, everything rendered at half
  size.
- The camera zoom was fine (2.0×); asset sizes were not the problem.

**Fix.**
- **World zoom:** the camera only, 1.0–2.0× in 0.25 steps, default 1.5×.
  Mouse wheel or Settings.
- **Interface size:** 100–200%, a single `Window.content_scale_factor` with
  canvas_items stretch.
  - The default comes from the screen: 150% at 1080p.
  - It is applied to every window, the HUD, login and character screens,
    tooltips, drag previews and name labels.
  - Fonts stay sharp, and the size is reduced automatically if the window is
    too small.
- **The world renders 1:1 in physical pixels,** so interface scaling never
  resamples it.
- Both values are in display points, so HiDPI screens get the same physical
  size.
- They are stored in `user://settings.cfg` along with help visibility, with
  Reset to default.
- The smallest text was raised from 10–11 to 12 (18 px at 150%).
- Terrain seams at fractional zoom are fixed.

**Verified** (Xvfb, all automated):
- Display scenario: 33/33 at each of 1280×720, 1920×1080 and 2560×1440.
- UI acceptance: 45/45 at all three.
- Combat walkthrough: 16/16 at 1080p.
- Login, character creation and restart through the UI: 38/38 at 1080p.
- Three-process multiplayer GUI with lag at 1080p: 5/5 and 6/6.
- Headless display preferences: 17/17. Rules, multiplayer and combat: 79,
  93 and 60, all passing.

**Not verified:**
- A human eye on a real monitor.
- A HiDPI display.
- macOS and Windows builds.
- A GPU.

**Art.** At 1.5× the 64×32 character is 108 px tall on screen; there are no
blur or seam problems, so no higher-resolution export is needed for 1080p.
The 96×48 set at 1.0× gives the same framing pixel-for-pixel and is the
candidate for 1440p and 4K. It has not been switched.

## Slice 005: what was built

Full technical description: [docs/COMBAT.md](docs/COMBAT.md). All tuning
lives in `game/data/combat.json`.

- **Server-authoritative combat** (`game/scripts/sim/combat/`). It runs
  identically offline and on the dedicated server.
  - **Flow:** an `attack` command engages a target; the server paces swings,
    resolves each when its windup ends (hit or miss, damage, effects, skill
    gain), and sends events for clients to present.
  - **Validation:** target exists and is hostile and alive, engage distance,
    range, line of sight for bows, stamina, attack interval, and the actor's
    defeated state.
  - **One damage path:** `apply_damage()`.
  - **Damage categories:** physical and electrical.
  - **Status effects:** a small framework; `shocked` is the only effect so
    far.
- **Resources:** health, stamina and mana, plus attack and defense ratings,
  all data-driven. Regeneration is faster out of combat. Swings cost stamina
  and lightning discharges cost mana.
- **Weapons**
  - **Iron Sword:** melee.
  - **Hunting Bow:** 8-tile range, line of sight, arrows timed to their
    flight; ammunition simplified to unlimited (documented).
  - **Stormcaller (lightning sword):** electrical bonus damage plus
    *shocked*. Its arcs and sparks come from the reusable weapon-effect
    system rather than being baked into sprites; bolts and blue sparks on
    impact.
- **Creatures:** the **wolf** (fast wanderer that pursues), the **skeleton
  guard** (slow, long windup, returns to its post) and the **bandit**
  (patrols, strafes, retreats when badly hurt). They are built from
  reusable parts, think at 10 Hz and sleep when no player is near.
- **Death and loot**
  - A creature dies once and leaves one set of remains, whose loot comes
    from structured tables.
  - Loot is persisted *before* it appears, and is free for all (one winner
    per item). Remains decay after 180 s and are temporary across restarts.
  - Creatures respawn after 45–60 s.
  - **Player defeat:** frozen, greyed and fallen. "Return to the homestead"
    brings the character back at the shrine with 50% health. No items are
    lost.
- **Skills:** Swordsmanship and Defense. They rise only from swings the
  server itself resolved, are capped, and are persisted with vitals
  (migration 002).
- **Presentation**
  - New animations: player attack and death; weapon layers for sword, bow
    and Stormcaller; creature idle, walk, attack and death in 8 facings.
  - Hit flashes, a target ring, arcing arrows, lightning bolts and sparks.
  - Optional damage numbers (N).
  - Vitals, Target, Skills (J) and Defeated windows.
  - 16 new placeholder sounds.
  - Tree canopies now fade when they hide the player.
  - Characters and creatures get a body hit box for clicking (skeletons
    were too thin to click).
- **Woodland clearing** south-west of the cottage, with the three
  encounters. An **armory chest** by the path holds the bow, Stormcaller
  and a sword.

### Slice 005 verification (all executed)

| Suite | Result |
|---|---|
| `tests/combat_tests.gd`: combat rules, offline authority, deterministic | **60/60** |
| `tests/persist/run.sh`: Slice 004 tests plus t10–t12 over the network with real processes. t10: two players take weapons, fight the wolf together, verify one death and one loot drop, a single DB row for the pelt, skill gain. t11: restart. t12: abuse. | **143/143** |
| GUI combat walkthrough (real input, Xvfb): armory, Stormcaller, wolf kill with lightning, remains, drag loot, skills, bow vs. skeleton, defeat by the bandit, respawn | **16/16** ([log](docs/images/slice005/combat_gui.log), screenshots in `docs/images/slice005/`) |
| Regression: rules, multiplayer, single-player UI, Keeper | **79/79**, **93/93**, **43/43**, **41/41** |

| Directive test | Result | How |
|---|---|---|
| 01 Target selection | ✓ | Click selects (target window and ring); unknown, self, player and dead targets rejected (c01); the target clears on death or despawn (GUI) |
| 02 Melee | ✓ | Swing pacing, range check, health change equals the server's damage events, every swing resolves once (c02); GUI wolf fight |
| 03 Ranged | ✓ | Shots at 6 tiles with travel time; none beyond 8 tiles or through the cottage walls (c03); GUI arrow vs. skeleton |
| 04 Lightning sword | ✓ | Electrical damage plus shocked from the server, mana cost, no discharge without mana (c04). Arcs visible while idle and bolts on hits (GUI screenshots). Equip replicated to the other player (t10). |
| 05 NPC behaviour | ✓ | Detection, wolf faster than skeleton, no standing in obstacles, skeleton returns to its post, bandit retreat (c05) |
| 06 Death and loot | ✓ | One death, one set of remains, no duplicate loot, loot taken once, decay, respawn (c06); GUI drag-loot |
| 07 Cooperative combat | ✓ | Offline (c07) and **networked (t10): both clients saw exactly one death**, one loot container, and exactly one of two simultaneous loot requests succeeded |
| 08 Player death | ✓ | Defeated: can't move, attack or interact; creature disengages; respawn at the shrine with half health (c08); GUI defeat and respawn |
| 09 Skill advancement | ✓ | Gains only from real swings, capped (c09); persisted across a server restart (t11) |
| 10 Combat abuse | ✓ | Attack spam doesn't speed up swings, far engage refused, no damage command exists, invalid ids refused, duplicate requests answered from the cache, repeated loot refused (c10, t12, c06) |
| 11 Persistence regression | ✓ | Stormcaller equipped, the pelt and skills restored after a restart (t11) |
| 12 Multiplayer regression | ✓ | All earlier suites pass (above) |

**Performance**, measured headless (`tests/bench_combat.gd`):

| Scenario | Cost per 30 Hz tick | Share of the 33 ms budget |
|---|---|---|
| 3 creatures, all active | 46 µs | 0.1% |
| 33 creatures, all fighting | 333 µs | 1.0% |

- Server static memory is about 23 MB.
- A `state` message with 2 players and 3 creatures is 564 bytes, about
  6.6 KB/s per client at 12 Hz.
- Effects free themselves (≤ 0.6 s); remains decay, so nothing accumulates.

### Slice 005 limitations and risks

- **Art and audio dependencies:**
  - all new art is forge stand-in art in the approved camera and palette;
  - the hit reaction is a red flash (no flinch frames);
  - the Rusty Dagger has no in-hand layer;
  - no arrow or quiver item;
  - sounds are synthetic placeholders.
- **Not verified:**
  - a human feel or balance pass (numbers are first-pass and live in
    `combat.json`);
  - combat on the 96×48 set in a GUI run (the art exists; the automated GUI
    run used 64×32);
  - combat under artificial latency in a GUI run (the networked co-op test
    ran without added lag);
  - LAN and GPU, as before.
- **No client-side combat prediction.** Animations start when the server's
  swing event arrives, so swings appear about one round-trip late. This is
  deliberate: the server stays authoritative.
- **Creature navigation is steering, not pathfinding.** Creatures can be
  outmanoeuvred around large obstacles. Stuck creatures re-pick a goal, or
  are placed back at their spawn when stuck while returning home.
- **No actor-to-actor collision.** Creatures and players can overlap.
- **Engaging is allowed up to range + 12 tiles,** so you can declare an
  attack and then walk in. Swings still need real range.
- **Skill gains since the last checkpoint** (≤ 10 s) are lost on a crash,
  the same rule as position.

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
6. **Combat feel:** a balance pass, and whether the defeated state should
   cost anything (it currently costs nothing).
7. **Next candidates:**
   - Asynchronous commit pipeline.
   - Account management (password change, recovery).
   - Interiors.
   - Richer appearance art.
