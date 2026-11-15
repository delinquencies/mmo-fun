#!/usr/bin/env python3
"""Keeper: the trusted persistence + authentication process for the game server.

Why a separate process: Godot 4 has no PostgreSQL driver and no Argon2id. Keeper
uses vetted libraries for both (psycopg 3, argon2-cffi) and is reachable only by
the dedicated game server: it binds to 127.0.0.1 and requires a shared secret.
Clients never talk to Keeper or PostgreSQL.

Protocol: newline-delimited JSON over TCP.
  first line  {"op": "hello", "secret": "..."}          -> {"ok": true}
  then        {"id": n, "op": "<name>", "args": {...}}  -> {"id": n, "ok": bool, "code": str, "data": {...}}
Requests run concurrently on a thread pool (slow Argon2 hashing never blocks
item commits); each request is one database transaction.

Usage:
  keeper.py migrate            apply db/migrations/*.sql
  keeper.py serve              run the service
Configuration (environment only - never committed):
  KEEPER_DSN      PostgreSQL connection string        (required)
  KEEPER_SECRET   shared secret with the game server  (required, >= 24 chars)
  KEEPER_BIND     default 127.0.0.1    KEEPER_PORT  default 24700
  KEEPER_ITEMS    path to game/data/items.json
  KEEPER_ENV      'development' | 'production' (production refuses non-loopback binds without TLS termination)
"""
import hashlib
import hmac
import json
import logging
import os
import re
import secrets
import socket
import sys
import threading
import time
import uuid
from collections import defaultdict, deque
from concurrent.futures import ThreadPoolExecutor

import psycopg
from psycopg.types.json import Jsonb
from argon2 import PasswordHasher
from argon2.exceptions import VerificationError, InvalidHashError

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
log = logging.getLogger("keeper")

USERNAME_RE = re.compile(r"^[a-z0-9_]{3,24}$")
CHARNAME_RE = re.compile(r"^[A-Za-z][A-Za-z' ]{1,14}[A-Za-z]$")
RESERVED_NAMES = {"admin", "administrator", "gm", "gamemaster", "system", "server", "moderator"}
MAX_CHARACTERS = 3
SESSION_HOURS = 12
LOCK_STALE_SECONDS = 30
APPEARANCE_CLOTH = {"olive", "crimson", "azure", "umber", "plum"}

ph = PasswordHasher()                       # Argon2id, RFC 9106 low-memory defaults
_DUMMY_HASH = ph.hash(secrets.token_hex(16))


class Fail(Exception):
    def __init__(self, code, detail=""):
        super().__init__(code)
        self.code = code
        self.detail = detail


# ---------------------------------------------------------------------------
# database helpers
# ---------------------------------------------------------------------------

_local = threading.local()


def conn():
    c = getattr(_local, "conn", None)
    if c is None or c.closed or c.broken:
        try:
            c = psycopg.connect(os.environ["KEEPER_DSN"], autocommit=False, connect_timeout=3)
        except psycopg.OperationalError as e:
            raise Fail("storage_unavailable", str(e).splitlines()[0])
        _local.conn = c
    return c


def tx(fn):
    """Run fn(cur) in one transaction; map database failures to safe codes."""
    c = conn()
    try:
        with c.transaction():
            with c.cursor() as cur:
                return fn(cur)
    except Fail:
        raise
    except psycopg.errors.UniqueViolation as e:
        raise Fail("conflict", e.diag.constraint_name or "unique")
    except (psycopg.errors.CheckViolation, psycopg.errors.ForeignKeyViolation,
            psycopg.errors.NotNullViolation, psycopg.errors.RaiseException) as e:
        raise Fail("constraint", e.diag.constraint_name or e.diag.message_primary or "check")
    except psycopg.OperationalError as e:
        _local.conn = None
        raise Fail("storage_unavailable", str(e).splitlines()[0] if str(e) else "connection lost")
    except psycopg.Error as e:
        _local.conn = None
        raise Fail("storage_error", type(e).__name__)


def migrate():
    c = psycopg.connect(os.environ["KEEPER_DSN"], autocommit=True)
    c.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version int PRIMARY KEY, name text NOT NULL,"
              " applied_at timestamptz NOT NULL DEFAULT now())")
    done = {r[0] for r in c.execute("SELECT version FROM schema_migrations")}
    d = os.path.join(ROOT, "db", "migrations")
    for fn in sorted(os.listdir(d)):
        m = re.match(r"^(\d+)_.*\.sql$", fn)
        if not m or int(m.group(1)) in done:
            continue
        sql = open(os.path.join(d, fn)).read()
        with c.transaction():
            c.execute(sql)
            c.execute("INSERT INTO schema_migrations (version, name) VALUES (%s, %s)", (int(m.group(1)), fn))
        print(f"applied {fn}")
    print("migrations up to date")


# ---------------------------------------------------------------------------
# rate limiting (in memory; per client address)
# ---------------------------------------------------------------------------

_attempts = defaultdict(deque)
_attempts_lock = threading.Lock()


def rate_limit(key, limit=10, window=60.0):
    now = time.monotonic()
    with _attempts_lock:
        q = _attempts[key]
        while q and now - q[0] > window:
            q.popleft()
        if len(q) >= limit:
            raise Fail("rate_limited")
        q.append(now)


# ---------------------------------------------------------------------------
# operations
# ---------------------------------------------------------------------------

def op_health(a):
    return tx(lambda cur: {"db": cur.execute("SELECT 1").fetchone()[0] == 1})


def op_register(a):
    username = str(a.get("username", "")).strip().lower()
    password = str(a.get("password", ""))
    rate_limit("register:" + str(a.get("ip", "?")), limit=5, window=300)
    if not USERNAME_RE.match(username):
        raise Fail("bad_username")
    if not (8 <= len(password) <= 128):
        raise Fail("bad_password")
    pw_hash = ph.hash(password)

    def run(cur):
        cur.execute("INSERT INTO accounts (username, password_hash) VALUES (%s, %s)"
                    " ON CONFLICT (username) DO NOTHING RETURNING id", (username, pw_hash))
        row = cur.fetchone()
        if row is None:
            raise Fail("username_taken")
        return {"account_id": row[0], "username": username}
    out = tx(run)
    log.info("account registered id=%s", out["account_id"])
    return out


def _new_session(cur, account_id):
    token = secrets.token_urlsafe(32)
    cur.execute("INSERT INTO auth_sessions (token_hash, account_id, expires_at)"
                " VALUES (%s, %s, now() + make_interval(hours => %s))",
                (hashlib.sha256(token.encode()).digest(), account_id, SESSION_HOURS))
    return token


def op_login(a):
    username = str(a.get("username", "")).strip().lower()
    password = str(a.get("password", ""))
    rate_limit("login:" + str(a.get("ip", "?")), limit=10, window=60)

    def lookup(cur):
        cur.execute("SELECT id, password_hash, status, locked_until > now(), failed_logins"
                    " FROM accounts WHERE username = %s", (username,))
        return cur.fetchone()
    row = tx(lookup) if USERNAME_RE.match(username) else None
    if row is None:
        try:   # equalise timing so unknown usernames are not distinguishable
            ph.verify(_DUMMY_HASH, password)
        except VerificationError:
            pass
        raise Fail("invalid_credentials")
    acct_id, pw_hash, status, locked, failed = row
    if locked:
        raise Fail("locked")
    try:
        ph.verify(pw_hash, password)
        ok = True
    except (VerificationError, InvalidHashError):
        ok = False
    if not ok or status != "active":
        def fail_count(cur):
            n = failed + 1
            lock_s = 0 if n < 5 else min(900, 30 * 2 ** (n - 5))
            cur.execute("UPDATE accounts SET failed_logins = %s, locked_until = CASE WHEN %s > 0"
                        " THEN now() + make_interval(secs => %s) ELSE locked_until END WHERE id = %s",
                        (n, lock_s, lock_s, acct_id))
        tx(fail_count)
        log.info("login failed account=%s", acct_id)
        raise Fail("invalid_credentials" if status == "active" else "disabled")

    def success(cur):
        new_hash = ph.hash(password) if ph.check_needs_rehash(pw_hash) else pw_hash
        cur.execute("UPDATE accounts SET failed_logins = 0, locked_until = NULL, last_login_at = now(),"
                    " password_hash = %s WHERE id = %s", (new_hash, acct_id))
        return {"account_id": acct_id, "username": username, "token": _new_session(cur, acct_id)}
    out = tx(success)
    log.info("login ok account=%s", acct_id)
    return out


def op_resume(a):
    token = str(a.get("token", ""))
    rate_limit("resume:" + str(a.get("ip", "?")), limit=20, window=60)

    def run(cur):
        cur.execute("SELECT s.account_id, a.username FROM auth_sessions s JOIN accounts a ON a.id = s.account_id"
                    " WHERE s.token_hash = %s AND s.revoked_at IS NULL AND s.expires_at > now()"
                    " AND a.status = 'active'", (hashlib.sha256(token.encode()).digest(),))
        row = cur.fetchone()
        if row is None:
            raise Fail("session_invalid")
        return {"account_id": row[0], "username": row[1]}
    return tx(run)


def op_logout(a):
    token = str(a.get("token", ""))
    tx(lambda cur: cur.execute("UPDATE auth_sessions SET revoked_at = now() WHERE token_hash = %s"
                               " AND revoked_at IS NULL", (hashlib.sha256(token.encode()).digest(),)))
    return {}


def _char_row(r):
    return {"id": r[0], "name": r[1], "appearance": r[2], "attributes": r[3], "region": r[4],
            "x": r[5], "y": r[6], "z": r[7], "facing": r[8],
            "last_played_at": r[9].isoformat() if r[9] else None, "created_at": r[10].isoformat(),
            "vitals": r[11] if len(r) > 11 else {}, "skills": r[12] if len(r) > 12 else {}}


CHAR_COLS = "id, name, appearance, attributes, region, x, y, z, facing, last_played_at, created_at, vitals, skills"


def op_char_list(a):
    acct = int(a["account_id"])
    def run(cur):
        cur.execute(f"SELECT {CHAR_COLS} FROM characters WHERE account_id = %s ORDER BY id", (acct,))
        return {"characters": [_char_row(r) for r in cur.fetchall()], "max": MAX_CHARACTERS}
    return tx(run)


def op_char_create(a):
    acct = int(a["account_id"])
    name = " ".join(str(a.get("name", "")).split())
    if not CHARNAME_RE.match(name) or name.lower() in RESERVED_NAMES:
        raise Fail("bad_name")
    appearance = a.get("appearance", {})
    if not isinstance(appearance, dict) or appearance.get("cloth") not in APPEARANCE_CLOTH or len(appearance) != 1:
        raise Fail("bad_appearance")
    spawn = a["spawn"]

    def run(cur):
        cur.execute("SELECT id FROM accounts WHERE id = %s FOR UPDATE", (acct,))   # serialise per account
        if cur.fetchone() is None:
            raise Fail("not_found")
        cur.execute("SELECT count(*) FROM characters WHERE account_id = %s", (acct,))
        if cur.fetchone()[0] >= MAX_CHARACTERS:
            raise Fail("too_many_characters")
        attrs = {"strength": 10, "dexterity": 10, "intelligence": 10}
        cur.execute("INSERT INTO characters (account_id, name, appearance, attributes, region, spawn_x, spawn_y, x, y)"
                    " VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s) ON CONFLICT DO NOTHING RETURNING " + CHAR_COLS,
                    (acct, name, Jsonb(appearance), Jsonb(attrs), spawn["region"], spawn["x"], spawn["y"],
                     spawn["x"], spawn["y"]))
        row = cur.fetchone()
        if row is None:
            raise Fail("name_taken")
        cur.execute("INSERT INTO containers (id, kind, capacity, owner_character_id) VALUES (%s, 'backpack', 15, %s)",
                    (f"c{row[0]}.backpack", row[0]))
        return {"character": _char_row(row)}
    out = tx(run)
    log.info("character created id=%s account=%s", out["character"]["id"], acct)
    return out


def _item_row(r):
    # id, def_id, quantity, loc_kind, container_id, slot, character_id, equip_slot, region, x, y, version, spawn_id
    if r[3] == "container":
        loc = {"kind": "container", "container": r[4], "slot": r[5]}
    elif r[3] == "equipment":
        loc = {"kind": "equipment", "owner": f"c{r[6]}", "slot": r[7]}
    else:
        loc = {"kind": "world", "pos": [r[9], r[10]]}
    return {"uid": r[0], "def": r[1], "qty": r[2], "loc": loc, "version": r[11], "spawn_id": r[12]}


ITEM_COLS = "id, def_id, quantity, loc_kind, container_id, slot, character_id, equip_slot, region, x, y, version, spawn_id"


def op_char_claim(a):
    """Exclusive control of a character by this server + full load."""
    acct, cid, server = int(a["account_id"]), int(a["character_id"]), str(a["server_id"])

    def run(cur):
        cur.execute(f"SELECT {CHAR_COLS}, locked_by, lock_heartbeat > now() - make_interval(secs => %s)"
                    " FROM characters WHERE id = %s AND account_id = %s FOR UPDATE",
                    (LOCK_STALE_SECONDS, cid, acct))
        r = cur.fetchone()
        if r is None:
            raise Fail("not_found")          # also for other accounts' characters: no enumeration
        locked_by, fresh = r[13], r[14]
        if locked_by and locked_by != server and fresh:
            raise Fail("locked_elsewhere")
        cur.execute("UPDATE characters SET locked_by = %s, lock_heartbeat = now(), last_played_at = now()"
                    " WHERE id = %s", (server, cid))
        cur.execute(f"SELECT {ITEM_COLS} FROM items WHERE container_id = %s OR (loc_kind = 'equipment' AND character_id = %s)",
                    (f"c{cid}.backpack", cid))
        return {"character": _char_row(r[:13]), "items": [_item_row(x) for x in cur.fetchall()]}
    return tx(run)


def _progress(a):
    """Validated vitals/skills from the game server (numbers only, bounded)."""
    vit = {k: float(v) for k, v in (a.get("vitals") or {}).items() if k in ("hp", "st", "mn") and 0 <= float(v) <= 10000}
    if "dead" in (a.get("vitals") or {}):
        vit["dead"] = bool(a["vitals"]["dead"])
    sk = {k: round(float(v), 1) for k, v in (a.get("skills") or {}).items()
          if re.match(r"^[a-z_]{2,32}$", k) and 0 <= float(v) <= 100}
    return Jsonb(vit), Jsonb(sk)


def op_char_release(a):
    cid, server = int(a["character_id"]), str(a["server_id"])
    vit, sk = _progress(a)
    tx(lambda cur: cur.execute(
        "UPDATE characters SET x = %s, y = %s, facing = %s, locked_by = NULL, lock_heartbeat = NULL,"
        " last_played_at = now(), vitals = CASE WHEN %s::jsonb = '{}' THEN vitals ELSE %s END,"
        " skills = skills || %s WHERE id = %s AND locked_by = %s",
        (float(a["x"]), float(a["y"]), int(a["facing"]), vit, vit, sk, cid, server)))
    return {}


def op_checkpoint(a):
    server = str(a["server_id"])
    def run(cur):
        n = 0
        for p in a.get("positions", []):
            vit, sk = _progress(p)
            cur.execute("UPDATE characters SET x = %s, y = %s, facing = %s, lock_heartbeat = now(),"
                        " vitals = CASE WHEN %s::jsonb = '{}' THEN vitals ELSE %s END, skills = skills || %s"
                        " WHERE id = %s AND locked_by = %s",
                        (float(p["x"]), float(p["y"]), int(p["facing"]), vit, vit, sk, int(p["id"]), server))
            n += cur.rowcount
        return {"saved": n}
    return tx(run)


def op_server_start(a):
    """A (re)starting server releases locks it held before a crash, plus stale ones."""
    server = str(a["server_id"])
    def run(cur):
        cur.execute("UPDATE characters SET locked_by = NULL, lock_heartbeat = NULL WHERE locked_by = %s"
                    " OR lock_heartbeat < now() - make_interval(secs => %s)", (server, LOCK_STALE_SECONDS))
        return {"released": cur.rowcount}
    out = tx(run)
    log.info("server %s started; released %s stale character lock(s)", server, out["released"])
    return out


def op_world_load(a):
    """Upsert item definitions, reconcile map-defined world objects with stored
    state, apply spawn policies, and return the region's persistent state."""
    region = str(a["region"])
    defs = a["item_defs"]
    objects = a["objects"]
    spawns = a["spawns"]

    def run(cur):
        for d_id, d in defs.items():
            cur.execute("INSERT INTO item_defs (id, stackable, max_stack, equip_slot, data) VALUES (%s, %s, %s, %s, %s)"
                        " ON CONFLICT (id) DO UPDATE SET stackable = EXCLUDED.stackable, max_stack = EXCLUDED.max_stack,"
                        " equip_slot = EXCLUDED.equip_slot, data = EXCLUDED.data, updated_at = now()",
                        (d_id, d["stackable"], d["max_stack"], d.get("equip_slot") or None, Jsonb(d)))
        # temporary objects (creature remains) never outlive the server run
        cur.execute("DELETE FROM items WHERE container_id IN (SELECT c.id FROM containers c JOIN world_objects w"
                    " ON w.id = c.world_object_id WHERE w.region = %s AND w.policy = 'temporary')", (region,))
        cur.execute("DELETE FROM containers WHERE world_object_id IN (SELECT id FROM world_objects WHERE region = %s"
                    " AND policy = 'temporary')", (region,))
        cur.execute("DELETE FROM world_objects WHERE region = %s AND policy = 'temporary'", (region,))
        purged = cur.rowcount
        cur.execute("SELECT setval('item_id_seq', GREATEST((SELECT COALESCE(max(id), 0) FROM items), 1000))")
        known = {o["id"] for o in objects} | {s["spawn_id"] for s in spawns}
        cur.execute("UPDATE world_objects SET orphaned = NOT (id = ANY(%s)) WHERE region = %s", (list(known), region))
        cur.execute("SELECT id FROM world_objects WHERE region = %s AND orphaned", (region,))
        orphaned = [r[0] for r in cur.fetchall()]
        states = {}
        seeded = []
        for o in objects:
            cur.execute("INSERT INTO world_objects (id, region, kind, policy, state) VALUES (%s, %s, %s, %s, %s)"
                        " ON CONFLICT (id) DO NOTHING RETURNING id",
                        (o["id"], region, o["kind"], o["policy"], Jsonb(o.get("default_state", {}))))
            created = cur.fetchone() is not None
            if o.get("container"):
                cont = o["container"]
                cur.execute("INSERT INTO containers (id, kind, capacity, world_object_id) VALUES (%s, 'world', %s, %s)"
                            " ON CONFLICT (id) DO NOTHING", (cont["id"], cont["capacity"], o["id"]))
                if created:
                    for slot, (def_id, qty) in enumerate(cont.get("seed", [])):
                        cur.execute("INSERT INTO items (def_id, quantity, loc_kind, container_id, slot) VALUES"
                                    " (%s, %s, 'container', %s, %s)", (def_id, qty, cont["id"], slot))
                    seeded.append(o["id"])
            if o["policy"] == "resettable":
                cur.execute("UPDATE world_objects SET state = %s, updated_at = now() WHERE id = %s",
                            (Jsonb(o.get("default_state", {})), o["id"]))
            cur.execute("SELECT state FROM world_objects WHERE id = %s", (o["id"],))
            states[o["id"]] = cur.fetchone()[0]
        for s in spawns:
            cur.execute("INSERT INTO world_objects (id, region, kind, policy, state) VALUES (%s, %s, 'spawn', %s, '{}')"
                        " ON CONFLICT (id) DO NOTHING RETURNING id", (s["spawn_id"], region, s["policy"]))
            first = cur.fetchone() is not None
            if s["policy"] == "permanent" and not first:
                continue      # permanent spawns happen exactly once, ever
            if s["policy"] == "resettable":
                cur.execute("SELECT 1 FROM items WHERE spawn_id = %s AND loc_kind = 'world'", (s["spawn_id"],))
                if cur.fetchone() is not None:
                    continue  # still lying there: nothing to reset
            cur.execute("INSERT INTO items (def_id, quantity, loc_kind, region, x, y, spawn_id) VALUES"
                        " (%s, %s, 'world', %s, %s, %s, %s)", (s["def"], s["qty"], region, s["x"], s["y"], s["spawn_id"]))
            seeded.append(s["spawn_id"])
        cur.execute(f"SELECT {ITEM_COLS} FROM items i WHERE (loc_kind = 'world' AND region = %s)"
                    " OR container_id IN (SELECT id FROM containers WHERE kind = 'world' AND world_object_id IN"
                    " (SELECT id FROM world_objects WHERE region = %s AND NOT orphaned))", (region, region))
        items = [_item_row(r) for r in cur.fetchall()]
        cur.execute("SELECT COALESCE(max(id), 1000) FROM items")
        max_id = cur.fetchone()[0]
        return {"states": states, "items": items, "max_item_id": max_id, "orphaned": orphaned, "seeded": seeded,
                "purged_temporary": purged}
    out = tx(run)
    log.info("world %s loaded: %d items, seeded %s, orphaned %s", region, len(out["items"]), out["seeded"], out["orphaned"])
    return out


def _loc_columns(loc, region):
    k = loc["kind"]
    if k == "container":
        return ("container", loc["container"], int(loc["slot"]), None, None, None, None, None)
    if k == "equipment":
        owner = str(loc["owner"])
        if not re.match(r"^c\d+$", owner):
            raise Fail("constraint", "equipment owner must be a persistent character")
        return ("equipment", None, None, int(owner[1:]), loc["slot"], None, None, None)
    if k == "world":
        return ("world", None, None, None, None, region, float(loc["pos"][0]), float(loc["pos"][1]))
    raise Fail("constraint", "bad location")


def op_commit_items(a):
    """Apply one gameplay item operation atomically. Idempotent per op_id.
    Each change carries the version the server last saw (optimistic concurrency);
    any mismatch aborts the whole operation."""
    op_id = str(uuid.UUID(str(a["op_id"])))
    region = str(a.get("region", "homestead"))
    changes = a["changes"]

    def run(cur):
        cur.execute("SELECT 1 FROM item_ops WHERE op_id = %s", (op_id,))
        if cur.fetchone():
            return {"already": True}
        for ch in changes:
            uid, ev = int(ch["uid"]), int(ch.get("expect_version", 0))
            if ch["op"] == "delete":
                cur.execute("DELETE FROM items WHERE id = %s AND version = %s", (uid, ev))
                if cur.rowcount != 1:
                    raise Fail("version_conflict", str(uid))
                continue
            kind, cont, slot, char, eslot, reg, x, y = _loc_columns(ch["loc"], region)
            qty = int(ch["qty"])
            if ev == 0:
                cur.execute("INSERT INTO items (id, def_id, quantity, loc_kind, container_id, slot, character_id,"
                            " equip_slot, region, x, y) VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s)",
                            (uid, ch["def"], qty, kind, cont, slot, char, eslot, reg, x, y))
            else:
                cur.execute("UPDATE items SET quantity = %s, loc_kind = %s, container_id = %s, slot = %s, character_id = %s,"
                            " equip_slot = %s, region = %s, x = %s, y = %s, version = version + 1, updated_at = now()"
                            " WHERE id = %s AND version = %s AND def_id = %s",
                            (qty, kind, cont, slot, char, eslot, reg, x, y, uid, ev, ch["def"]))
                if cur.rowcount != 1:
                    raise Fail("version_conflict", str(uid))
        cur.execute("INSERT INTO item_ops (op_id, actor, kind, changes) VALUES (%s, %s, %s, %s)",
                    (op_id, a.get("actor"), a.get("kind", "transfer"), Jsonb(changes)))
        return {"already": False}
    return tx(run)


def op_spawn_loot(a):
    """Creature remains + generated loot, atomically, once per op_id."""
    op_id = str(uuid.UUID(str(a["op_id"])))
    region = str(a.get("region", "homestead"))
    c = a["corpse"]

    def run(cur):
        cur.execute("SELECT 1 FROM item_ops WHERE op_id = %s", (op_id,))
        if cur.fetchone():
            return {"already": True}
        cur.execute("INSERT INTO world_objects (id, region, kind, policy, state) VALUES (%s, %s, 'corpse', 'temporary', %s)",
                    (c["id"], region, Jsonb({"creature": c.get("creature", ""), "x": c["x"], "y": c["y"]})))
        cur.execute("INSERT INTO containers (id, kind, capacity, world_object_id) VALUES (%s, 'world', %s, %s)",
                    (c["container"], int(c["capacity"]), c["id"]))
        for it in a["items"]:
            loc = it["loc"]
            cur.execute("INSERT INTO items (id, def_id, quantity, loc_kind, container_id, slot) VALUES (%s, %s, %s, 'container', %s, %s)",
                        (int(it["uid"]), it["def"], int(it["qty"]), loc["container"], int(loc["slot"])))
        cur.execute("INSERT INTO item_ops (op_id, actor, kind, changes) VALUES (%s, %s, 'loot', %s)",
                    (op_id, c["id"], Jsonb(a["items"])))
        return {"already": False}
    return tx(run)


def op_despawn_loot(a):
    """Remains decayed: delete the container and anything still inside it."""
    oid = str(a["object_id"])

    def run(cur):
        cur.execute("SELECT 1 FROM world_objects WHERE id = %s AND policy = 'temporary'", (oid,))
        if cur.fetchone() is None:
            return {"removed": 0}
        cur.execute("DELETE FROM items WHERE container_id IN (SELECT id FROM containers WHERE world_object_id = %s)", (oid,))
        n = cur.rowcount
        cur.execute("DELETE FROM containers WHERE world_object_id = %s", (oid,))
        cur.execute("DELETE FROM world_objects WHERE id = %s", (oid,))
        return {"removed": n}
    return tx(run)


def op_op_status(a):
    op_id = str(uuid.UUID(str(a["op_id"])))
    return tx(lambda cur: {"committed": cur.execute("SELECT 1 FROM item_ops WHERE op_id = %s", (op_id,)).fetchone() is not None})


def op_world_state(a):
    def run(cur):
        cur.execute("UPDATE world_objects SET state = %s, updated_at = now() WHERE id = %s AND policy <> 'temporary'",
                    (Jsonb(a["state"]), str(a["object_id"])))
        return {"updated": cur.rowcount}
    return tx(run)


OPS = {
    "health": op_health, "register": op_register, "login": op_login, "resume": op_resume, "logout": op_logout,
    "char_list": op_char_list, "char_create": op_char_create, "char_claim": op_char_claim,
    "char_release": op_char_release, "checkpoint": op_checkpoint, "server_start": op_server_start,
    "world_load": op_world_load, "commit_items": op_commit_items, "op_status": op_op_status,
    "world_state": op_world_state, "spawn_loot": op_spawn_loot, "despawn_loot": op_despawn_loot,
}


# ---------------------------------------------------------------------------
# server
# ---------------------------------------------------------------------------

def handle_client(sock, addr, secret, pool):
    f = sock.makefile("rwb", buffering=0)
    wlock = threading.Lock()

    def send(obj):
        data = (json.dumps(obj, separators=(",", ":"), default=str) + "\n").encode()
        with wlock:
            try:
                sock.sendall(data)
            except OSError:
                pass

    try:
        first = json.loads(f.readline() or b"{}")
        if first.get("op") != "hello" or not hmac.compare_digest(str(first.get("secret", "")).encode(), secret.encode()):
            log.warning("rejected keeper client %s (bad secret)", addr[0])
            send({"ok": False, "code": "unauthorized"})
            return
        send({"ok": True, "code": "", "data": {"version": 1}})
        log.info("game server connected from %s", addr[0])

        def work(req):
            rid = req.get("id")
            op = req.get("op")
            t0 = time.perf_counter()
            try:
                if op not in OPS:
                    raise Fail("unknown_op")
                data = OPS[op](req.get("args") or {})
                send({"id": rid, "ok": True, "code": "", "data": data})
                code = "ok"
            except Fail as e:
                send({"id": rid, "ok": False, "code": e.code, "data": {}})
                code = e.code
                if e.code in ("storage_unavailable", "storage_error", "constraint", "version_conflict"):
                    log.warning("op %s failed: %s (%s)", op, e.code, e.detail)
            except Exception as e:  # noqa: BLE001 - never crash the service on one request
                log.exception("op %s crashed", op)
                send({"id": rid, "ok": False, "code": "internal", "data": {}})
                code = "internal"
            log.debug("op %s -> %s in %.1f ms", op, code, (time.perf_counter() - t0) * 1000)

        for line in f:
            try:
                req = json.loads(line)
            except ValueError:
                continue
            pool.submit(work, req)
    finally:
        log.info("game server connection closed")
        sock.close()


def serve():
    secret = os.environ.get("KEEPER_SECRET", "")
    if len(secret) < 24:
        sys.exit("KEEPER_SECRET must be set (>= 24 characters)")
    if "KEEPER_DSN" not in os.environ:
        sys.exit("KEEPER_DSN must be set")
    bind = os.environ.get("KEEPER_BIND", "127.0.0.1")
    port = int(os.environ.get("KEEPER_PORT", "24700"))
    if bind not in ("127.0.0.1", "::1", "localhost"):
        sys.exit("Keeper only listens on loopback: it is for the co-located game server, never for clients")
    try:
        op_health({})
    except Fail as e:
        log.warning("database not reachable at startup (%s); will retry per request", e.code)
    pool = ThreadPoolExecutor(max_workers=8)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((bind, port))
    srv.listen(4)
    log.info("keeper listening on %s:%d (%s)", bind, port, os.environ.get("KEEPER_ENV", "development"))
    while True:
        s, addr = srv.accept()
        s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        threading.Thread(target=handle_client, args=(s, addr, secret, pool), daemon=True).start()


if __name__ == "__main__":
    logging.basicConfig(level=os.environ.get("KEEPER_LOG", "INFO"), format="%(asctime)s keeper %(levelname)s %(message)s")
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if cmd == "migrate":
        migrate()
    elif cmd == "serve":
        serve()
    else:
        sys.exit(__doc__)
