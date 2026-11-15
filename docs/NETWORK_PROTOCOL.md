# Multiplayer: Protocol, Authority and Replication (Slices 003–004)

> **Protocol version 2 (Slice 004).** Version 2 adds the persistent-realm
> messages below and DTLS on every connection. A v1 client is rejected with a
> `bad_version` error. Persistence and accounts are covered in
> [PERSISTENCE.md](PERSISTENCE.md).

Code lives in `game/scripts/net/`. The protocol constants and message schemas
are in `protocol.gd`, and that file is the single source of truth: keep this
document in sync with it.

## Topology

```
                 ┌───────────────────── dedicated server (headless Godot) ──────────────────────┐
 client A ──ENet─┤ GameServer ── WorldSim (authoritative) ── InteractionSystem ── ItemStore      │
 client B ──ENet─┤   sessions · 30 Hz tick · input queues · interest filter · result cache        │
                 └───────────────────────────────────────────────────────────────────────────────┘
 each client:  NetClient ── replica WorldSim (only changed by server messages + movement prediction)
               └─ WorldView / GameUI / WorldSurface: unchanged Slice 001/002 presentation
```

- **Transport:** ENet through Godot's `SceneMultiplayer`. `server_relay` is
  off, so clients can only talk to the server, and object decoding is off.
- **Process layout:** `GameServer` and `NetClient` each own a
  `SceneMultiplayer` branch whose `NetChannel` child is named `Net`. This
  keeps RPC paths identical on both sides, and lets the tests run a real
  server and two real clients in one process.
- **Binding:** the server binds to **127.0.0.1 by default**. LAN play needs an
  explicit `--bind=0.0.0.0` (or a LAN IP). It has not been hardened for
  public deployment.
- **Encryption:** client traffic is **DTLS**, with a certificate the client
  pins (`.dev/tls/server.crt` in development). A persistent server refuses
  non-loopback binds without TLS.

## State ownership

| Owned by the server (authoritative) | Owned by the client (presentation only) |
|---|---|
| Player positions and facing, movement legality | Camera, zoom, asset set |
| Door and chest open state, collision | Cursor, hover, selection, drag previews |
| Container contents, item ownership, quantities | Window placement, UI scale, tooltips |
| Ground items, equipped items | Interpolation and prediction smoothing, animation clocks |
| Who has which container open | Name labels, journal, sounds, particles |
| Session identity (`session`, `actor`) | Sheep (ambient, not gameplay state) |

A client never sends a position, an inventory, a quantity it owns, or an
object state. The only things it sends are **movement intent** and
**commands**.

## Persistent realms (v2)

When the server runs with `--persistent`:
1. The server answers `hello` with `realm` instead of `welcome`.
2. The client logs in.
3. It lists or creates characters.
4. It enters with a character id. `welcome` then follows exactly as in Slice
   003; the actor is `c<character id>`.
5. `chars leave` returns to character selection with a `left` message. After
   that, movement and commands are not accepted until the client enters again.

| t | Direction | Fields |
|---|---|---|
| `realm` | S→C | `persistent`, `realm`, `max_characters`, `secure` (DTLS active) |
| `auth` | C→S | `rid`, `op`, `args`. Ops: `register {username, password}`, `login {username, password}`, `resume {token}`, `logout {}` |
| `auth_res` | S→C | `rid`, `ok`, `code`, `message`, `data`. `login` returns `{username, token}`. |
| `chars` | C→S | `rid`, `op`, `args`. Ops: `list {}`, `create {name, appearance: {cloth}}`, `enter {character_id}`, `leave {}` |
| `chars_res` | S→C | `rid`, `ok`, `code`, `message`, `data`. `list` returns `{characters, max}`; `create` returns `{character}`; `enter` returns `{character_id, takeover?}`. |
| `left` | S→C | `reason` |

`P` records gain a 7th field, `appearance`.

Argument names and types are validated exactly by `Protocol.validate_op()`.
Ownership always comes from the server-side account of the connection.

## Envelope

Every message is a `Dictionary`: `{"v": 1, "t": "<type>", ...fields}`.

- `Protocol.validate()` checks the version, type, direction, field types and
  that there are no unexpected fields.
- On the server, an invalid message from a connection that has not yet said
  hello gets it kicked. After that, invalid messages are counted and ignored,
  and a connection is kicked after 50.

## Messages

**Client → server, reliable**

| t | Fields | Meaning |
|---|---|---|
| `hello` | `name` | First message. The name is sanitised (letters, digits, space, `-`, `_`; 2–16 characters) and made unique. |
| `cmd` | `rid: int`, `cmd: {type, args}` | An `InteractionCommand` (see below). `rid` is the request id, unique per session. |
| `ping` | `time` | Answered with `pong`, used to measure RTT. |
| `bye` | n/a | Leave cleanly: the character is removed immediately. |

**Client → server, unreliable ordered**

| t | Fields | Meaning |
|---|---|---|
| `input` | `inputs: [[seq, dx, dy, run], …]` | Movement intent: one entry per client tick (30 Hz), with each packet repeating the last 3 inputs to cover packet loss. `|(dx, dy)| ≤ 1`. |

**Server → client, reliable**

| t | Fields |
|---|---|
| `welcome` | `session`, `actor`, `name`, `tick_rate`, `state_rate`, `time`, `players: [P]`, `entities: [[id, open]]` (the initial snapshot) |
| `reject` | `reason` |
| `join` | `player: P` |
| `leave` | `actor`, `reason` |
| `status` | `actor`, `linkdead` |
| `entity` | `id`, `open`: a door or chest state change |
| `items` | `up: [[uid, def, qty, location]]`, `rm: [uid]`: an item diff, filtered by interest |
| `event` | `e`: an interaction event in wire form (sounds, failures, opened/closed, item_moved for the journal) |
| `result` | `rid`, `ok`, `code`, `message`: the answer to one `cmd` |
| `pong` | `time`, `server_time` |

**Server → client, unreliable ordered (12 Hz)**

| t | Fields |
|---|---|
| `state` | `tick`, `time`, `ack` (the last input seq applied for *this* client), `players: [[actor, x, y, facing, moving, running]]` |

`P` is `[actor, name, x, y, facing, linkdead]`. A location in wire form is
`{"kind":"container","container":id,"slot":n}`,
`{"kind":"world","pos":[x,y]}` or
`{"kind":"equipment","owner":actor,"slot":name}`.

## Commands (`cmd.type`)

All of these are validated twice:
- `Protocol.validate_command()` checks the shape: argument names and types,
  location shapes, and finite numbers.
- `InteractionSystem` checks the rules: range, ownership, open containers,
  slot rules, and the current location of the item.

The actor is always taken **from the session**; any actor in the payload is
ignored.

| type | args | Directive category |
|---|---|---|
| `use` | `entity` | Interact: toggles a door, opens a chest, picks up `item:<uid>` |
| `set_door` | `entity`, `open` | Open or close a door explicitly. Idempotent: a no-op fails with `no_change`. |
| `close_container` | `container` | Close a container |
| `transfer` | `uid`, `from`, `to`, `qty` | Transfer an item (any location to any location) |
| `pick_up` | `uid` | Ground item into own backpack |
| `drop` | `uid`, `from`, `pos` | Item onto the ground |
| `equip` | `uid`, `from` | Into the item's equip slot (swaps with the main hand if occupied) |
| `unequip` | `slot` | Equipped item into own backpack |
| `use_item` | `uid`, `from` | Double-click convenience: equip, unequip, or take |

Failure codes are listed in `docs/INTERACTION_SYSTEMS.md`. Two codes are
network-specific:
- `invalid`: the payload failed schema validation.
- `offline`: a client-side refusal while disconnected.

## Movement authority

1. Every client tick (30 Hz) the client samples input, assigns
   `seq = seq + 1`, **predicts** locally with the same rule the server uses
   (`WorldSim.step_actor`), and sends the input.
2. The server queues valid inputs whose `seq` is newer than any it has seen.
   - Stale or redundant inputs are counted as `stale_inputs`.
   - Malformed inputs (NaN, magnitude above 1, wrong shape) are counted as
     `rejected_inputs` and ignored.
   - At most 4 inputs are held; anything beyond is dropped and counted as
     `excess_inputs`.
3. Each server tick applies **at most one** input per player, for exactly
   one tick (1/30 s), at walk or run speed. Speed therefore can't exceed the
   rules no matter how fast a client sends. With no input, the character
   stops.
4. The server sends `state` at 12 Hz with `ack`. The client resets its
   predicted position to the server's, re-applies the inputs that were not
   yet acknowledged, and blends any small correction away visually. A
   correction larger than 1.5 tiles snaps.
5. Remote players are drawn **120 ms in the past**, interpolated between
   buffered `state` samples, so they move smoothly and never extrapolate
   through walls.

Teleporting is impossible by construction: no message carries a position from
the client.

## Item replication and interest

After every command, and on each tick where item state changed, the server
compares what each client **is allowed to see** with what it last told that
client (a signature per uid: def, quantity and location). It sends only the
difference.

A client may see:
- ground items within 48 tiles of its character;
- its own backpack and equipment;
- containers it currently has open;
- everyone's *equipped* items, so the weapon on another character can be
  drawn.

It can never see another player's backpack.

`ItemStore.replica_apply()` applies each batch as removals first, then a
two-phase upsert, so a swap inside one batch can't clobber itself.

Players and sounds use the same 48-tile radius, through `_send_states()` and
`_on_sim_event()`. One region needs nothing more elaborate.
`GameServer._visible()` is the single place to plug in spatial interest
management later.

## Duplicate and replay protection

Two independent layers:

1. **Request ids:** the server caches the last 128 results per session. A
   repeated `rid` gets the cached `result` again and is **not executed
   again**. This covers retransmitted packets, double-clicks and replays.
2. **Business validation:** every transfer names the item's current `from`
   location. Once an item has moved, any further request built from the old
   state fails as `stale`. This covers a replay with a new rid and two
   clients racing.

Commands execute one at a time on the server's main thread, so two
simultaneous pickups are resolved in arrival order: exactly one succeeds.

## Sessions and failures

| Situation | Behaviour |
|---|---|
| Join | The client must send `hello` within 5 s. It gets a random 8-hex `session` and an actor `pc_<session>`. **Neither is proof of account ownership**: both are temporary until Slice 004 adds persistence. |
| Clean leave (`bye`) or client exit | The character is removed immediately. |
| Unexpected disconnect or timeout | ENet's peer timeout is about 6 s. The character goes **link-dead**: frozen, greyed, labelled "(link lost)", and its open containers close. After `linger` seconds (default 8) it is removed. |
| Removal | Everything the character carried is placed on the ground at its feet. Temporary sessions own nothing permanently, so items are never deleted. |
| Reconnect | A fresh session with a new actor. The old character is not recovered (that's Slice 004). |
| Server shutdown | Clients get `server_disconnected`, return to the offline world and show the reason in the connection panel. |
| Connect timeout or failure | Reported after 6 s, or immediately if the server is unreachable. |
| Idle | A character with no input for 30 s is disconnected. |
| Invalid messages | Ignored and counted; 50 gets the connection kicked. |
| Unknown or unavailable targets | The command fails with `no_target`, `no_item` or `stale`, and nothing changes. |

## Configuration

| Setting | Default | Where |
|---|---|---|
| Port | 24680 | `--port` |
| Bind address | 127.0.0.1 | `--bind` |
| Simulation tick | 30 Hz | `--tick` |
| State replication | 12 Hz | `--state_rate` |
| Link-dead linger | 8 s | `--linger` |
| Max clients | 16 | `--max_clients` |
| Artificial network conditions | off | `--lag=ms --jitter=ms --loss=0..1` (server or client) |
| Client prediction | on | `--no_predict` on the client |

All defaults are constants in `protocol.gd`.
