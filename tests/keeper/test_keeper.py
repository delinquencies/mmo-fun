#!/usr/bin/env python3
"""Keeper operation tests against a real PostgreSQL database (KEEPER_DSN must
point at a disposable database, e.g. mmo_test). Run: tests/keeper/run.sh"""
import json
import os
import sys
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "tools", "keeper"))
import keeper as K  # noqa: E402

fails = 0
checks = 0


def check(cond, what):
    global fails, checks
    checks += 1
    if not cond:
        fails += 1
    print(("  ok   " if cond else "  FAIL ") + what)


def expect_fail(code, fn, *a):
    try:
        fn(*a)
        return False
    except K.Fail as e:
        # deferred uniqueness is reported at COMMIT as a conflict: equally a refusal
        return e.code == code or (code == "constraint" and e.code == "conflict")


ITEMS = json.load(open(os.path.join(K.ROOT, "game", "data", "items.json")))
DEFS = {k: {"stackable": v.get("stackable", False), "max_stack": v.get("max_stack", 1000 if v.get("stackable") else 1),
            "equip_slot": v.get("equip_slot", "")} for k, v in ITEMS.items()}
OBJECTS = [
    {"id": "cottage_door", "kind": "door", "policy": "permanent", "default_state": {"open": False}},
    {"id": "cottage_chest", "kind": "chest", "policy": "permanent", "default_state": {},
     "container": {"id": "cottage_chest.contents", "capacity": 8, "seed": [["gold_coins", 25], ["red_apple", 3], ["healing_potion", 1]]}},
]
SPAWNS = [{"spawn_id": "spawn_iron_sword", "def": "iron_sword", "qty": 1, "x": 18.4, "y": 12.2, "policy": "permanent"},
          {"spawn_id": "spawn_trough_apples", "def": "red_apple", "qty": 2, "x": 11.4, "y": 16.4, "policy": "resettable"}]


def world_load():
    return K.op_world_load({"region": "homestead", "item_defs": DEFS, "objects": OBJECTS, "spawns": SPAWNS})


def q(sql, *args):
    return K.tx(lambda cur: cur.execute(sql, args if args else None).fetchall())


print("accounts")
a = K.op_register({"username": "Alice_1", "password": "correct horse", "ip": "t"})
check(a["username"] == "alice_1", "usernames are case-folded")
check(expect_fail("username_taken", K.op_register, {"username": "ALICE_1", "password": "another pw!", "ip": "t"}), "duplicate username refused")
check(expect_fail("bad_password", K.op_register, {"username": "shorty", "password": "short", "ip": "t"}), "short password refused")
check(expect_fail("bad_username", K.op_register, {"username": "a!", "password": "longenough", "ip": "t"}), "bad username refused")
h = q("SELECT password_hash FROM accounts WHERE username='alice_1'")[0][0]
check(h.startswith("$argon2id$") and "correct horse" not in h, "password stored as Argon2id hash only")
s = K.op_login({"username": "alice_1", "password": "correct horse", "ip": "t2"})
check(len(s["token"]) >= 40, "login returns an unpredictable session token")
check(q("SELECT count(*) FROM auth_sessions WHERE token_hash = sha256(%s::bytea)", s["token"].encode())[0][0] == 1, "only the token's SHA-256 is stored")
check(K.op_resume({"token": s["token"], "ip": "t"})["account_id"] == a["account_id"], "session resumes")
check(expect_fail("invalid_credentials", K.op_login, {"username": "alice_1", "password": "wrong", "ip": "t3"}), "wrong password refused")
check(expect_fail("invalid_credentials", K.op_login, {"username": "nobody", "password": "whatever1", "ip": "t3"}), "unknown user gets the same answer")
K.op_logout({"token": s["token"]})
check(expect_fail("session_invalid", K.op_resume, {"token": s["token"], "ip": "t"}), "logged-out session no longer valid")
b = K.op_register({"username": "bob", "password": "bobs password", "ip": "t"})
for i in range(5):
    K.op_login({"username": "bob", "password": "nope", "ip": f"x{i}"}) if False else expect_fail("invalid_credentials", K.op_login, {"username": "bob", "password": "nope", "ip": f"x{i}"})
check(expect_fail("locked", K.op_login, {"username": "bob", "password": "bobs password", "ip": "x9"}), "5 failures lock the account temporarily")
K.tx(lambda cur: cur.execute("UPDATE accounts SET locked_until = NULL WHERE username='bob'"))
for i in range(10):
    try:
        K.op_login({"username": "bob", "password": "bobs password", "ip": "flood"})
    except K.Fail:
        pass
check(expect_fail("rate_limited", K.op_login, {"username": "bob", "password": "bobs password", "ip": "flood"}), "per-address login rate limit")

print("characters")
spawn = {"region": "homestead", "x": 17.5, "y": 10.6}
ca = K.op_char_create({"account_id": a["account_id"], "name": "Melanie", "appearance": {"cloth": "olive"}, "spawn": spawn})["character"]
check(ca["attributes"]["strength"] == 10 and ca["x"] == 17.5, "character created with attributes and spawn")
check(expect_fail("name_taken", K.op_char_create, {"account_id": b["account_id"], "name": "melanie", "appearance": {"cloth": "azure"}, "spawn": spawn}), "names unique case-insensitively")
check(expect_fail("bad_name", K.op_char_create, {"account_id": a["account_id"], "name": "GM", "appearance": {"cloth": "azure"}, "spawn": spawn}), "too-short name refused")
check(expect_fail("bad_name", K.op_char_create, {"account_id": a["account_id"], "name": "Admin", "appearance": {"cloth": "azure"}, "spawn": spawn}), "reserved name refused")
check(expect_fail("bad_appearance", K.op_char_create, {"account_id": a["account_id"], "name": "Hacker", "appearance": {"cloth": "gold", "x": 1}, "spawn": spawn}), "unknown appearance refused")
K.op_char_create({"account_id": a["account_id"], "name": "Second", "appearance": {"cloth": "plum"}, "spawn": spawn})
K.op_char_create({"account_id": a["account_id"], "name": "Third", "appearance": {"cloth": "umber"}, "spawn": spawn})
check(expect_fail("too_many_characters", K.op_char_create, {"account_id": a["account_id"], "name": "Fourth", "appearance": {"cloth": "umber"}, "spawn": spawn}), "max 3 characters per account")
cb = K.op_char_create({"account_id": b["account_id"], "name": "Bob", "appearance": {"cloth": "azure"}, "spawn": spawn})["character"]
check(expect_fail("not_found", K.op_char_claim, {"account_id": b["account_id"], "character_id": ca["id"], "server_id": "s1"}), "cannot claim another account's character")
cl = K.op_char_claim({"account_id": a["account_id"], "character_id": ca["id"], "server_id": "s1"})
check(cl["items"] == [], "claim loads (empty) inventory")
check(expect_fail("locked_elsewhere", K.op_char_claim, {"account_id": a["account_id"], "character_id": ca["id"], "server_id": "s2"}), "a second server cannot take a live lock")
K.op_server_start({"server_id": "s1"})
check(q("SELECT locked_by FROM characters WHERE id=%s", ca["id"])[0][0] is None, "restarting server clears its own stale locks")

print("world + items")
w = world_load()
check(len(w["items"]) == 5, "first load seeds chest (3) + sword + apples (%d)" % len(w["items"]))
w2 = world_load()
check(len(w2["items"]) == 5, "second load seeds nothing new")
sword = next(i for i in w2["items"] if i["def"] == "iron_sword")
apples_spawn = next(i for i in w2["items"] if i["spawn_id"] == "spawn_trough_apples")
K.op_char_claim({"account_id": a["account_id"], "character_id": ca["id"], "server_id": "s1"})
bp = f"c{ca['id']}.backpack"
op1 = str(uuid.uuid4())
r = K.op_commit_items({"op_id": op1, "actor": f"c{ca['id']}", "changes": [
    {"op": "upsert", "uid": sword["uid"], "def": "iron_sword", "qty": 1, "loc": {"kind": "container", "container": bp, "slot": 0}, "expect_version": 1}]})
check(not r["already"], "pickup committed")
check(K.op_commit_items({"op_id": op1, "changes": []})["already"], "same op id is idempotent (not applied twice)")
check(K.op_op_status({"op_id": op1})["committed"], "op status reports committed")
check(expect_fail("version_conflict", K.op_commit_items, {"op_id": str(uuid.uuid4()), "changes": [
    {"op": "upsert", "uid": sword["uid"], "def": "iron_sword", "qty": 1, "loc": {"kind": "world", "pos": [1, 1]}, "expect_version": 1}]}),
    "stale version refused (no second pickup)")
r = K.op_commit_items({"op_id": str(uuid.uuid4()), "changes": [
    {"op": "upsert", "uid": sword["uid"], "def": "iron_sword", "qty": 1, "loc": {"kind": "equipment", "owner": f"c{ca['id']}", "slot": "main_hand"}, "expect_version": 2}]})
check(q("SELECT loc_kind, equip_slot FROM items WHERE id=%s", sword["uid"])[0] == ("equipment", "main_hand"), "equip persisted")
check(expect_fail("constraint", K.op_commit_items, {"op_id": str(uuid.uuid4()), "changes": [
    {"op": "upsert", "uid": apples_spawn["uid"], "def": "red_apple", "qty": 2, "loc": {"kind": "equipment", "owner": f"c{ca['id']}", "slot": "main_hand"}, "expect_version": 1}]}),
    "two items in one equip slot refused by the database")
coins = next(i for i in w2["items"] if i["def"] == "gold_coins")
check(expect_fail("constraint", K.op_commit_items, {"op_id": str(uuid.uuid4()), "changes": [
    {"op": "upsert", "uid": coins["uid"], "def": "gold_coins", "qty": 0, "loc": coins["loc"], "expect_version": 1}]}), "zero quantity refused")
check(expect_fail("constraint", K.op_commit_items, {"op_id": str(uuid.uuid4()), "changes": [
    {"op": "upsert", "uid": coins["uid"], "def": "gold_coins", "qty": 25, "loc": {"kind": "container", "container": "cottage_chest.contents", "slot": 9}, "expect_version": 1}]}), "slot beyond capacity refused")
# split 10 coins into the backpack, then swap two chest items in one transaction
new_id = w2["max_item_id"] + 1
K.op_commit_items({"op_id": str(uuid.uuid4()), "changes": [
    {"op": "upsert", "uid": coins["uid"], "def": "gold_coins", "qty": 15, "loc": coins["loc"], "expect_version": 1},
    {"op": "upsert", "uid": new_id, "def": "gold_coins", "qty": 10, "loc": {"kind": "container", "container": bp, "slot": 3}, "expect_version": 0}]})
check(q("SELECT sum(quantity) FROM items WHERE def_id='gold_coins'")[0][0] == 25, "split conserves quantity in the database")
chest_items = [i for i in w2["items"] if i["loc"].get("container") == "cottage_chest.contents" and i["def"] != "gold_coins"]
x, y = chest_items[0], chest_items[1]
K.op_commit_items({"op_id": str(uuid.uuid4()), "changes": [
    {"op": "upsert", "uid": x["uid"], "def": x["def"], "qty": x["qty"], "loc": y["loc"], "expect_version": 1},
    {"op": "upsert", "uid": y["uid"], "def": y["def"], "qty": y["qty"], "loc": x["loc"], "expect_version": 1}]})
check(q("SELECT slot FROM items WHERE id=%s", x["uid"])[0][0] == y["loc"]["slot"], "swap inside one transaction (deferred uniqueness)")
check(expect_fail("version_conflict", K.op_commit_items, {"op_id": str(uuid.uuid4()), "changes": [
    {"op": "upsert", "uid": new_id, "def": "gold_coins", "qty": 10, "loc": {"kind": "world", "pos": [17, 11]}, "expect_version": 1},
    {"op": "upsert", "uid": coins["uid"], "def": "gold_coins", "qty": 99, "loc": coins["loc"], "expect_version": 1}]}),
    "a failing change rolls back the whole operation")
check(q("SELECT loc_kind FROM items WHERE id=%s", new_id)[0][0] == "container", "...and the first change was not applied")
# resettable spawn: take the apples, reload -> respawn; permanent sword: never respawns
K.op_commit_items({"op_id": str(uuid.uuid4()), "changes": [
    {"op": "upsert", "uid": apples_spawn["uid"], "def": "red_apple", "qty": 2, "loc": {"kind": "container", "container": bp, "slot": 5}, "expect_version": 1}]})
w3 = world_load()
check(sum(1 for i in w3["items"] if i["spawn_id"] == "spawn_trough_apples" and i["loc"]["kind"] == "world") == 1, "resettable spawn restored on world load")
check(not any(i["def"] == "iron_sword" for i in w3["items"]), "permanent spawn (sword) not recreated")
dup = q("SELECT id, count(*) FROM items GROUP BY id HAVING count(*) > 1")
check(dup == [], "no duplicate item ids")
check(K.op_char_claim({"account_id": a["account_id"], "character_id": ca["id"], "server_id": "s1"})["items"].__len__() == 3,
      "claim loads backpack + equipment (sword equipped, coins, apples)")
print(f"\n{checks} checks, {fails} failures")
sys.exit(1 if fails else 0)
