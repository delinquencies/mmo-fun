# Combat, Creatures, Loot and Skills (Slice 005)

All tuning lives in `game/data/combat.json`. Code lives in
`game/scripts/sim/combat/` (authoritative), `game/scripts/view/combat_fx.gd`
and `world_view.gd` (presentation), and `game/scripts/ui/combat_ui.gd` (UI).

## 1. Audit: what existing systems combat extends

| Existing system | How combat uses it |
|---|---|
| `InteractionSystem.submit()`, the single command entry point | New command types `attack {target}`, `stop_attack`, `respawn` go through the same path, are validated by `Protocol.validate_command`, and are deduplicated by the server's request-id cache. While a character is defeated, every non-combat command is refused (`dead`). |
| `event_emitted`, the single event pipe | Combat events (`type: "combat"`), `vitals`, `skill`, `entity_spawned` and `entity_removed` use it, so offline play, the server and replicas all see the same stream. |
| `ItemStore`, the durable gate, `ItemTransferService` | Loot is ordinary item instances in an ordinary container. Taking it is an ordinary transfer: validated, transactional, one winner. |
| `PlayerState`, `WorldSim.try_move` / `is_blocked` | Players gain a `Combatant` and skills. Creatures move with the same collision rules. |
| Slice 004 persistence | `characters` gains `vitals` and `skills` (migration 002), saved by checkpoint and on leave. Corpses are `temporary` world objects (Keeper `spawn_loot` / `despawn_loot`). |
| Art forge + overlay layers | New animation states, weapon layers per weapon, and three creature sheets. `SwordEnergy` (Slice 001) became the reusable lightning weapon effect. |

**Architectural changes:**
- Protocol v3: player and creature health in `state`, creatures in `welcome`.
- A test-runner completion guard: a script error now fails the test instead
  of passing silently. This found and fixed three latent test-fixture bugs.

No existing system was replaced.

## 2. Command and authority flow

```
client: click to select (local only) -> double-click / Space -> cmd "attack" {target}
server: CombatSystem.handle  - actor alive? target exists, hostile, alive, within engage distance?
        CombatSystem.update  - every tick, per attacker: ready (interval)? in range (+ sight for bows)? stamina?
                               -> swing event (windup) -> resolve at windup end:
                                  still valid? hit roll (attack + skill vs defence + skill) -> damage
                                  -> apply_damage(): the ONLY place health changes -> death -> loot
                               -> events (combat/vitals/skill) -> clients present them
```

**Swings are paced by the server.**
- Attack spam only re-sets the target, so swings never happen faster than
  the weapon's interval.
- There is no client damage command; any such type fails protocol
  validation.
- The client never reports hits, damage, deaths or skill gains.

**Facing is automatic:** the attacker turns toward its target when the swing
starts.

Hits **resolve when the windup ends**, not on animation frames. A target that
moves out of reach during the windup makes the swing miss (`out_of_reach`).

**Ranged attacks:**
- The bow checks range (8 tiles) and line of sight both when the swing starts
  and when it resolves.
- Line of sight samples the path every 0.2 tiles against solid obstacles,
  walls and closed doors. Water doesn't block it.
- The outcome is decided at release; the event carries the arrow's `travel`
  time, so clients show the impact when the arrow lands.
- **Ammunition is simplified:** arrows are unlimited (documented decision; no
  arrow item yet).

## 3. Attributes and resources (data-driven defaults)

| | Players | Creatures |
|---|---|---|
| Health / Stamina / Mana | 60 / 60 / 40 | health from `creatures.*.hp` |
| Attack / Defense rating | 10 / 8 | per archetype |
| Regeneration | Per second: hp 0.25, stamina 3, mana 1. Health and mana regenerate 4× out of combat (6 s after the last exchange). | 5% health/s, only when out of combat and idle or returning |

**Combat formulas:**
- **Hit chance** = clamp(0.55 + (attack + skill×0.3 − defense − defense
  skill×0.25) / 100, 0.15, 0.95).
- **Damage** = roll × (1 + skill/200) − defense×0.15 − defense skill×0.01,
  minimum 1.
- **Stamina** is paid per swing (sword 3, bow 2); with too little, no swing
  happens.

## 4. Weapons

| Weapon | Kind | Damage | Interval | Windup | Range | Notes |
|---|---|---|---|---|---|---|
| Iron Sword | melee | 5–9 | 2.0 s | 0.45 s | 1.35 | `durability` field reserved |
| Hunting Bow | ranged | 4–8 | 2.4 s | 0.6 s | 8.0 | line of sight; projectile 14 tiles/s; unlimited arrows |
| Stormcaller (Enchanted Lightning Sword) | melee | 5–9 + electrical 3–6 | 2.0 s | 0.45 s | 1.35 | Each hit spends 4 mana to discharge; applies **shocked** (3 s: 1–2 electrical damage per second, 25% slower attacks). No mana, no discharge. |
| Rusty Dagger (loot) | melee | 2–5 | 1.5 s | 0.3 s | 1.2 | No in-hand art yet (see §10) |
| Unarmed | melee | 1–3 | 1.6 s | 0.3 s | 1.15 | — |

**Damage categories:** `physical` and `electrical`.

**Status-effect framework** (`Combatant.statuses` plus `status_effects` in
the data): duration, tick, damage, category and attack slow. Only `shocked`
is defined.

**Weapon-effect system:** an item definition names an `effect`
(`"lightning"`), and any character holding it gets the reusable `SwordEnergy`
arcs along the blade. These are driven by per-frame blade anchors from the
forge, so the effect isn't baked into the sprites. Electrical hits add a
`CombatFX.Bolt` from the blade tip to the target, plus blue sparks.

## 5. Creatures (server-simulated; `NpcAI` components)

Components: `detect` (nearest visible player in range), `navigate` (steering
that probes ±45°, ±90° and ±135° when blocked; no per-frame pathfinding),
`face`, `wander_point`, `beyond_leash`, `flee_point` and `strafe_point`.
Brains run at 10 Hz (`ai.think_interval`); movement integrates every tick.
Creatures with no player within 24 tiles sleep (`ai.activation_radius`).

| | Wolf | Skeleton Guard | Bandit |
|---|---|---|---|
| Idle | Wanders its territory (3.5 tiles) | Stands at its post | Patrols three waypoints |
| Detect | 7 tiles | 5.5 tiles | 6.5 tiles |
| Speed (chase / walk) | 4.3 / 1.6, fast | 2.0 / 1.0, deliberate | 3.2 / 1.3 |
| Attack | 3–6 every 1.2 s, short windup | 5–9 every 2.6 s, long 0.75 s windup | 4–8 every 1.8 s |
| Special | — | Returns to its post | **Strafes** sideways between attacks; **retreats** below 30% health for 3.5 s, then disengages |
| Give up | Beyond leash (12) or target farther than 2.2× detect | Leash 8 | Leash 11 |

**Not modelled:** collision between actors (creatures and players can
overlap), and A* pathfinding. A creature stuck for 1.5 s picks a new wander
point; one stuck while returning home is placed back at its spawn.

## 6. Death, loot and remains

**When a creature dies:**
1. Its combat stops and all attackers disengage.
2. A death event is sent.
3. It's removed from targeting.
4. **One set of remains** spawns: a `corpse` interactable with an 8-slot
   container, whose contents are rolled from `loot_tables`.
5. It respawns at its spawn point after `respawn` seconds (45 s for the
   wolf, 60 s for the others).

`_die()` runs at most once per life, so loot can't be duplicated.

**Persistence:** loot rows are created by Keeper's `spawn_loot` (one
transaction, idempotent per op id) **before** the remains appear.

**Loot access policy:** free for all. Anyone in range may open the remains
and take items; simultaneous requests resolve through the transfer service,
so exactly one succeeds.

**Despawn policy:** remains decay after 180 s, and anything left inside is
destroyed (`despawn_loot`). Remains are `temporary`: on a restart the server
purges them. Looted items are ordinary durable items.

**When a player dies:**
- The character is **defeated**: no movement, combat or interaction, and it
  is greyed out, falls over (death animation) and gets the "Defeated" window.
- Creatures disengage.
- **Return to the homestead** respawns the character at the shrine
  (`player.respawn`) with 50% health, 50% stamina and 3 s of invulnerability.
- **Nothing is lost:** no item or skill penalty, and no permanent death
  (Director approval would be needed).
- Logging out while defeated means recovering at the shrine on the next
  login.

## 7. Skills

Swordsmanship (melee weapons) and Defense. Each starts at 30.0, gains 0.1
per step and caps at 100.0.

**Gain rule:** a gain is possible only on a swing the **server itself
resolved** against a **living hostile creature** (Swordsmanship), or when a
creature's swing at you resolves (Defense). The chance is
`base_chance × (1 − value/cap)`. Nothing the client sends can trigger a
gain.

**Persistence:** saved in `characters.skills` with the 10 s checkpoint, on
leaving and on graceful shutdown. A crash can lose up to 10 s of gains,
the same rule as position (documented in `docs/PERSISTENCE.md`).

## 8. Replication

| What | How |
|---|---|
| Creature positions and health % | `state.npcs` at 12 Hz, interest-filtered; clients interpolate 120 ms behind like remote players |
| Player health % / defeated | `state.players` (fields 7–8) |
| Combat events | swing, projectile, damage, miss, status, death, respawn, aggro, retreat, disengage. Reliable `event`, to everyone within 48 tiles of the event. |
| Own vitals and skills | `vitals` / `skill` events to the owner only, sent on change. |
| Remains | `entity_spawned` / `entity_removed` broadcast; sent to late joiners after `welcome`. |

Clients play animations **when the server's swing event arrives**; they
don't predict combat. Under 120 ms of artificial latency the reaction is
visibly delayed but consistent.

## 9. Presentation

**Animation states:**
- **Player:** idle, walk, attack (6 frames; overhead swing, or bow draw and
  release) and death (4 frames, falls backwards); 8 facings.
- **Weapon layers:** iron sword, Stormcaller and bow, for every state.
- **Creatures:** idle, walk, attack and death in 8 facings each:
  - wolf: lunging bite, rolls over on death;
  - skeleton: rusty sword and shield;
  - bandit: hooded, with a sword.
- **Hit reaction:** a 0.15 s red flash. This is a placeholder; there is no
  dedicated flinch frame yet.

**Feedback:**
- target ring: red-orange for hostile, green for friendly;
- Target window: name, hostility, health bar, engaged state;
- Vitals window: health, stamina and mana bars, plus status;
- Skills window (J): live values, with gains highlighted;
- damage numbers: small and short-lived, toggled with N;
- sparks: red for physical, blue for electrical;
- arrows that arc and impact;
- lightning bolts;
- remains drawn with the creature's last death frame.

**Sounds:** sword swing, flesh and bone impacts, miss, bow release, arrow
impact, lightning discharge, wolf growl/bite/death, bone rattle/collapse,
bandit shout/death, player hurt, opening remains. All are synthesised
placeholders (`tools/forge/sfx.py`), mapped in `data/audio_events.json`.

## 10. Art and audio dependencies (unresolved)

- **Procedural art:** everything is forge-rendered stand-in art in the
  approved camera and palette. Final creature and character art is still a
  Director/art-pipeline item.
- **Rusty Dagger:** has no in-hand layer; the character looks empty-handed.
  It needs a weapon layer like the others.
- **Hit reactions:** a red flash instead of flinch frames.
- **Sounds:** synthetic; recordings are needed.
- **No arrow item or quiver art,** since ammunition is simplified.
