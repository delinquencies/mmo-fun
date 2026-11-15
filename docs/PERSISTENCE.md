# Persistence, Accounts and Recovery (Slice 004)

## 1. Audit summary: what existed and what changed

| Found in Slices 001–003 | Persistence decision |
|---|---|
| `GameServer` + `WorldSim` are the only authority (Slice 003). | Unchanged. PostgreSQL is the **durable record**; the server stays the gameplay authority. |
| Every item change goes through `ItemTransferService.plan()` then `commit()`. | Added a **durable gate** between them: `persist_plan()` must commit to the database first. If it can't, memory is not touched and the player is told "nothing was changed". |
| Door state changes in `InteractionSystem._use()`. | The same gate covers **permanent** doors (`persist_world`). |
| Sessions were temporary (`pc_<random>`); carried items were dropped on disconnect. | **Persistent mode** (`--persistent`): an account, then a character with stable id `c<character id>`. Items stay with the character in the database; nothing is dropped. **Temporary mode** still exists for development and the Slice 003 tests. |
| Item uids came from an in-memory counter. | Uids are database primary keys. The counter starts above `max(id)` at boot; the server is the only writer for its region. |
| Map-defined chest contents and the ground sword were recreated on every start. | Each world object and spawn has a **stable id** and an explicit **policy** (see §4). |

**Transient** (never stored):
- input queues, prediction state and interpolation buffers;
- open-container viewers and chest lid state;
- hover and selection;
- link-dead timers;
- RID caches;
- sheep;
- client UI layout.

**Durable**: accounts, auth sessions, characters (identity, appearance,
attributes, position, facing), item instances and their single location,
containers, equipment, and world-object state for permanent objects.

## 2. Process boundaries

```
 game client ──DTLS/ENet──► dedicated server (Godot) ──loopback TCP + shared secret──► Keeper (Python) ──► PostgreSQL
                            gameplay authority                                         auth + storage         durable record
```

**Why Keeper exists.** Godot 4 has no PostgreSQL driver and no Argon2id
implementation. Rather than hand-roll either, one small trusted process uses
vetted libraries: **psycopg 3** and **argon2-cffi**.
- It is not a public service: it binds to loopback only and refuses to start
  otherwise.
- It requires `KEEPER_SECRET` on its first line.
- It never talks to clients.

Clients never receive database credentials and never connect to PostgreSQL.

**New external dependencies** (in `tools/keeper/requirements.txt`):

| Dependency | Role |
|---|---|
| `psycopg[binary]` 3.x | PostgreSQL driver: parameterised queries, transactions |
| `argon2-cffi` | Argon2id password hashing (RFC 9106 low-memory defaults) |
| PostgreSQL 16 | Durable storage. Run locally via `tools/db/dev_db.sh` or `docker-compose.yml`. |

## 3. Schema (`db/migrations/001_init.sql`)

Migrations are versioned. `keeper.py migrate` applies `db/migrations/NNN_*.sql`
in order and records each one in `schema_migrations`.

| Table | Holds | Integrity |
|---|---|---|
| `accounts` | Username (lower-case, `^[a-z0-9_]{3,24}$`), Argon2id hash, status, failed-login counter, lockout | Unique username |
| `auth_sessions` | **SHA-256 of** the session token, account, expiry (12 h), revocation | FK to account |
| `characters` | Stable `id`, `account_id`, name, appearance, attributes, region, spawn point, x/y/z, facing, created and last-played times, `locked_by`/`lock_heartbeat` | Name rule (CHECK) + case-insensitive unique index; FK to account |
| `item_defs` | Item definitions, upserted from `game/data/items.json` at server start | Referenced by items |
| `containers` | Backpacks (`c<id>.backpack`, owned by a character) and world containers (owned by a world object), with capacity | Exactly one owner kind (CHECK) |
| `items` | **One row per item instance = its single authoritative location**: container + slot, character + equip slot, or region + x/y. Also quantity, `version`, and `spawn_id` | CHECKs on location shape and positive quantity; trigger for stack limits and slot < capacity; deferred-unique `(container_id, slot)` and `(character_id, equip_slot)`; FKs |
| `item_ops` | Every committed item operation, keyed by a server-generated `op_id` | Primary key: idempotency and crash resolution |
| `world_objects` | Stable map ids, policy, durable state (e.g. `{"open": true}`), `orphaned` flag | — |

Because an item *is* one row, it cannot be in two places, and no ownership
state is duplicated across tables. A character's inventory is not a separate
list: it is "the rows whose location is my backpack or my equipment".

## 4. World-object persistence policies

Policies are declared per object in `game/data/maps/homestead.json`, generated
by `tools/forge/mapgen.py`.

| Policy | Meaning | In this map |
|---|---|---|
| **permanent** | Durable until gameplay or an admin changes it. Created from map defaults exactly once, the first time the world is loaded. | `cottage_door` (open/closed); `cottage_chest` and its contents (seeded once with 25 coins, 3 apples, 1 potion); `spawn_iron_sword` (the sword appears once, ever; afterwards it is wherever players put it) |
| **resettable** | Restored to its default by the **world-reset rule**, which runs on every server start. For a spawn, that means: if no item from that spawn is still lying on the ground, a new one appears. | `spawn_trough_apples` (2 apples by the trough). Taken apples stay with whoever took them. |
| **temporary** | Not stored: exists only while the server runs. | Chest lid animation, viewers of open containers, sheep, every object without a policy |

**When the map changes:**
- **Object removed from the map:** its row is flagged `orphaned`, not loaded,
  and **not deleted**. A container's contents are preserved for an admin to
  resolve, and the server logs a warning at start.
- **Object moved in the map:** position comes from the map; state comes from
  the database.
- **New object in the map:** created with its default state, and seeded if
  it's a container.

Items players drop on the ground are permanent rows with a world location.
They stay until someone picks them up. No decay rule exists yet.

## 5. Save strategy

| What | When | How |
|---|---|---|
| Item ownership, location, quantity (pickup, drop, move, split, merge, equip, unequip, swap) | **Every change, before it is applied** | One transaction per operation via `commit_items`. Optimistic concurrency: each row's expected `version`; any mismatch aborts the whole operation. A server-generated `op_id` is recorded in `item_ops`. |
| Permanent door state | Every change, before it is applied | `world_state` |
| Character position and facing | Every **10 s** (checkpoint), on leaving the world, on logout, on graceful shutdown | `checkpoint`, `char_release` |
| Account, character creation | Immediately | Transactions; character creation is serialised per account with a row lock (maximum 3) |

Position is the only state that can be lost: at most the last 10 s, on a
crash. Item state is never "saved later".

## 6. Failure behaviour

| Situation | Behaviour (all tested unless marked) |
|---|---|
| Normal logout / leave world | Position saved, lock released, items unloaded from memory (they stay in the database). |
| Unexpected client disconnect | The character stays **link-dead** for `--linger` seconds (default 8). Reconnecting to the same character within that window takes it over. Then save and unload as above. Nothing is dropped. |
| Graceful server shutdown (Ctrl+C or SIGTERM via `tools/net/run_server.sh`, which writes a stop file) | Everyone saved, all locks released. |
| Server crash (`kill -9`) | Committed item operations are intact; positions roll back to the last checkpoint. Locks are left behind but are **released by the next start of the same `--server_id`**, or treated as stale after 30 s by any other server. |
| Database or Keeper down | Item and door commands fail with `storage_unavailable` ("nothing was changed") and memory is untouched. Logins and character loads fail with a clear message. Movement continues. When storage returns, the same operations succeed. |
| Unknown commit outcome (connection lost after sending) | Never resent. The server asks `op_status(op_id)`. If storage can't answer, **all item commands pause** (`storage_unavailable`) until it can. Then the op is applied in memory if it committed, or dropped if it did not. *(Code path implemented; not exercised by a test.)* |
| Failed transaction (constraint or version conflict) | Fully rolled back; the player is told nothing changed; the server logs a warning, since this means memory and database disagree. |
| Repeated or duplicate requests | The RID cache (Slice 003) answers repeats without running them again. Replays with new ids fail as `stale` (location check) or `version_conflict` (database). |
| Duplicate login (same character, second session) | Refused with "That character is already in the world." The first session keeps authority. |
| Stale active-session locks | See "Server crash" above. |

## 7. Accounts and security

**Passwords**
- Argon2id via argon2-cffi; never stored or logged in plain text.
- Hashes are rehashed on login when the parameters change.
- Unknown usernames still run a dummy verification, so timing doesn't reveal
  whether an account exists. Error text is the same in both cases: "Unknown
  account or wrong password."

**Rate limiting**
- Keeper: 10 logins/min and 5 registrations per 5 min per client address.
- Account lockout after 5 failures: 30 s, doubling, capped at 15 min.
- Server: at most 8 account/character requests per 10 s per connection, one at
  a time.

**Sessions**
- The account session token comes from `secrets.token_urlsafe(32)`. Only its
  SHA-256 is stored. It expires after 12 h and is revoked on logout.
- The client keeps the token **in memory only**, to resume after a dropped
  connection without resending the password.
- An authenticated account and a world session are different things: you can
  be logged in and on the character screen without controlling a character.

**Ownership**
- Account and character ids are **never** taken from the client as proof.
- The server uses the account id of the authenticated connection; Keeper's
  `char_claim` requires `character.account_id = session account`.
- Selecting another account's character returns `not_found`, so other
  accounts' characters can't be discovered by probing.
- Item access rules from Slice 003 still apply: another player's backpack is
  neither visible nor accessible.

**Exclusive control.** `char_claim` sets `locked_by = server_id` inside a
row-locked transaction. The server allows one active session per character.

**Transport**
- Client traffic is **DTLS** (ENet + Godot TLS). Clients pin the server
  certificate: the dev certificate is generated in `.dev/tls/`; production uses
  `--tls_cert`/`--tls_key`.
- A persistent server **refuses to start** on a non-loopback bind without TLS.
- A client **refuses to send a password** over an unencrypted connection to a
  non-loopback host.
- Keeper ↔ PostgreSQL uses SCRAM-SHA-256 on loopback.

**Secrets**
- Everything is in environment variables generated into `.dev/env`, which is
  gitignored. Nothing is committed.
- Logs contain account and character ids and result codes; never passwords,
  hashes or tokens.

**SQL.** Parameterised queries only.

**Administrative endpoints.** There are none.

## 8. Known limitations

- **Blocking commits:** item commits block the server's main loop for the
  duration of one localhost transaction (typically a few ms; bounded by a 2 s
  timeout). This is a deliberate simplicity trade-off: strict ordering with no
  interleaving. Under database distress the whole region stalls for up to the
  timeout. A queued, asynchronous commit pipeline is the next step if load
  requires it.
- **One server per region (`server_id`):** multiple servers sharing a database
  would need the stale-lock window (30 s) tuned, and are untested.
- **No admin tools:** there is no character deletion, account recovery, email
  or password change yet.
- **Orphaned objects:** these are only flagged; resolving them needs a manual
  SQL query.
- **Keeper's rate limits** are in memory and reset when Keeper restarts.
