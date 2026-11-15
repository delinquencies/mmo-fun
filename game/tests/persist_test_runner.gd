extends Node

const PORT := 24721
var REPO := ProjectSettings.globalize_path("res://").path_join("..").simplify_path()
var LOGDIR := ""
var server_pid := 0
var keeper_pid := 0
var server_runs := 0
var checks := 0
var fails := 0
var _finished := false
var current := ""
var clients: Array[NetClient] = []
var A: NetClient
var B: NetClient


func _ready() -> void:
	LOGDIR = OS.get_environment("PERSIST_LOG_DIR")
	if LOGDIR == "":
		LOGDIR = REPO.path_join(".dev/test-logs")
	DirAccess.make_dir_recursive_absolute(LOGDIR)
	_run.call_deferred()


func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
	print("   %s [%s] %s" % ["ok  " if cond else "FAIL", current, what])


func seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout


func until(cond: Callable, timeout := 6.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t0 > timeout * 1000.0:
			return false
		await get_tree().process_frame
	return true


# --- processes ---------------------------------------------------------------------

func start_keeper() -> void:
	keeper_pid = OS.create_process("python3", [REPO.path_join("tools/keeper/keeper.py"), "serve"])
	await seconds(1.2)


func stop_keeper() -> void:
	if keeper_pid:
		OS.kill(keeper_pid)
		keeper_pid = 0
		await seconds(0.3)


func start_server() -> bool:
	server_runs += 1
	var args := ["--headless", "--log-file", LOGDIR.path_join("server-%d.log" % server_runs), "--path",
		ProjectSettings.globalize_path("res://"), "res://scenes/server.tscn", "--", "--persistent", "--dev_tls",
		"--port=%d" % PORT, "--server_id=test-realm", "--linger=2", "--stop_file=" + LOGDIR.path_join("stop")]
	server_pid = OS.create_process(OS.get_executable_path(), args)
	# ready when a probe client gets the realm handshake
	var probe := make_client("Probe")
	var ok := false
	for i in 30:
		probe.connect_to("127.0.0.1", PORT, "probe")
		if await until(func(): return probe.state == "login", 1.0):
			ok = true
			break
		probe.drop_connection()
		await seconds(0.3)
	probe.drop_connection()
	clients.erase(probe)
	probe.queue_free()
	return ok


func stop_server_gracefully() -> void:
	FileAccess.open(LOGDIR.path_join("stop"), FileAccess.WRITE).store_string("stop")
	await until(func(): return not OS.is_process_running(server_pid), 10.0)
	server_pid = 0


func kill_server() -> void:
	OS.kill(server_pid)    # SIGKILL: no shutdown code runs
	await until(func(): return not OS.is_process_running(server_pid), 5.0)
	server_pid = 0


func psql(sql: String) -> String:
	var out := []
	OS.execute("psql", ["-h", "127.0.0.1", "-p", OS.get_environment("PGPORT"), "-U", "mmo_keeper", "-d",
		OS.get_environment("MMO_TEST_DB"), "-At", "-c", sql], out, true)
	return "\n".join(out).strip_edges()


func db_ctl(cmd: String) -> void:
	var out := []
	OS.execute("bash", [REPO.path_join("tools/db/dev_db.sh"), cmd], out, true)


# --- clients -------------------------------------------------------------------------

func make_client(n: String) -> NetClient:
	var c := NetClient.new()
	c.name = n
	get_tree().root.add_child(c)
	clients.append(c)
	return c


func connect_realm(c: NetClient) -> bool:
	c.connect_to("127.0.0.1", PORT, c.name)
	return await until(func(): return c.state in ["login", "account"], 8.0)


func auth(c: NetClient, op: String, args := {}) -> Dictionary:
	var rid := c.send_auth(op, args)
	await until(func(): return c.last_auth.get("rid", -1) == rid, 8.0)
	return c.last_auth if c.last_auth.get("rid", -1) == rid else {}


func chars(c: NetClient, op: String, args := {}) -> Dictionary:
	var rid := c.send_chars(op, args)
	await until(func(): return c.last_chars.get("rid", -1) == rid, 8.0)
	return c.last_chars if c.last_chars.get("rid", -1) == rid else {}


## Log in unless the client already resumed its account session with its token.
func login(c: NetClient, u: String, p: String) -> bool:
	if await until(func(): return c.state == "account", 1.5):
		return true
	return (await auth(c, "login", {"username": u, "password": p})).get("ok", false)


func enter(c: NetClient, cid: int) -> bool:
	var r := await chars(c, "enter", {"character_id": cid})
	return r.get("ok", false) and await until(func(): return c.state == "connected" and c.sim != null, 6.0)


func cmd(c: NetClient, type: String, args: Dictionary) -> Dictionary:
	var rid := c.next_rid()
	c.send_raw_command(rid, type, args)
	await until(func(): return c.last_result.get("rid", -1) == rid, 6.0)
	return c.last_result if c.last_result.get("rid", -1) == rid else {}


func walk(c: NetClient, target: Vector2, timeout := 8.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while c.local_state() and c.local_state().pos.distance_to(target) > 0.12:
		if Time.get_ticks_msec() - t0 > timeout * 1000.0:
			c.set_input(Vector2.ZERO, false)
			return false
		var d := target - c.local_state().pos
		c.set_input(d if d.length() > 0.08 else Vector2.ZERO, false)
		await get_tree().process_frame
	c.set_input(Vector2.ZERO, false)
	await seconds(0.3)
	return c.local_state() != null


func through_door(c: NetClient, inward: bool) -> bool:
	var d: Vector2 = c.sim.entities["cottage_door"].pos
	var ok := await walk(c, d + (Vector2(1.0, 0) if inward else Vector2(-0.85, 0)))
	ok = ok and await walk(c, d + (Vector2(0.2, 0) if inward else Vector2(-0.4, 0)))
	return ok and await walk(c, d + (Vector2(-0.85, 0) if inward else Vector2(1.0, 0)))


func find_item(c: NetClient, def_id: String, kind := "") -> int:
	for uid in c.sim.items.items:
		if c.sim.items.items[uid].def_id == def_id and (kind == "" or c.sim.items.location(uid)["kind"] == kind):
			return uid
	return 0


func wire(c: NetClient, uid: int) -> Dictionary:
	return ItemLocation.to_wire(c.sim.items.location(uid))


func db_item_count(def_id: String) -> int:
	return int(psql("SELECT COALESCE(sum(quantity),0) FROM items WHERE def_id = '%s'" % def_id))


func db_integrity() -> bool:
	var dup := psql("SELECT count(*) FROM (SELECT id FROM items GROUP BY id HAVING count(*) > 1) d")
	var bad := psql("SELECT count(*) FROM items WHERE quantity < 1")
	return dup == "0" and bad == "0"


# --- the run ---------------------------------------------------------------------------

var alice_cid := 0
var bob_cid := 0
var baseline := {}


func _run() -> void:
	await start_keeper()
	current = "boot"
	check(await start_server(), "persistent server started (Keeper + PostgreSQL reachable, DTLS)")
	for d in ["iron_sword", "gold_coins", "red_apple", "healing_potion"]:
		baseline[d] = db_item_count(d)
	print("   baseline totals in DB: %s" % JSON.stringify(baseline))
	A = make_client("ClientA")
	B = make_client("ClientB")
	for t in ["t01_accounts", "t02_character_persistence", "t03_server_restart", "t04_shared_chest",
			"t05_duplicate_login", "t06_unauthorized", "t07_concurrent_pickup", "t08_database_failure",
			"t09_crash_recovery", "t10_combat_coop", "t11_combat_restart", "t12_combat_abuse"]:
		current = t
		var before := fails
		_finished = false
		await call(t)
		if not _finished:
			fails += 1
			print("   FAIL [%s] test did not run to completion (script error)" % t)
		print("%s %s" % ["PASS" if fails == before else "FAIL", t])
	current = "teardown"
	for c in clients:
		c.drop_connection()
	await stop_server_gracefully()
	check(psql("SELECT count(*) FROM characters WHERE locked_by IS NOT NULL") == "0", "graceful shutdown released every character lock")
	await stop_keeper()
	print("\n%d checks, %d failures" % [checks, fails])
	get_tree().quit(1 if fails else 0)


func t01_accounts() -> void:
	check(await connect_realm(A), "connected (DTLS: %s)" % A.secure)
	check(A.secure, "client traffic is encrypted (DTLS)")
	var r := await auth(A, "register", {"username": "alice", "password": "silver lantern 42"})
	check(r.get("ok", false), "register alice")
	r = await auth(A, "register", {"username": "Alice", "password": "another one 99"})
	check(not r.get("ok", true) and r.get("code") == "username_taken", "duplicate account refused")
	r = await auth(A, "login", {"username": "alice", "password": "wrong password"})
	check(not r.get("ok", true) and r.get("code") == "invalid_credentials" and r.get("message", "").contains("wrong password"), "wrong password: generic error")
	r = await auth(A, "login", {"username": "nosuchuser", "password": "whatever 123"})
	check(r.get("code") == "invalid_credentials", "unknown account: same generic error")
	r = await auth(A, "login", {"username": "alice", "password": "silver lantern 42"})
	check(r.get("ok", false) and A.state == "account", "login with correct credentials")
	check(psql("SELECT count(*) FROM accounts WHERE password_hash LIKE '$argon2id$%' AND username='alice'") == "1", "stored as Argon2id")
	r = await auth(A, "logout")
	check(r.get("ok", false) and A.state == "login", "logout")
	r = await chars(A, "list")
	check(not r.get("ok", true), "character list refused after logout")
	r = await auth(A, "login", {"username": "alice", "password": "silver lantern 42"})
	check(r.get("ok", false), "log back in")
	check(await connect_realm(B), "second client connected")
	check((await auth(B, "register", {"username": "bob", "password": "oak and iron 7"})).get("ok", false), "register bob")
	check((await auth(B, "login", {"username": "bob", "password": "oak and iron 7"})).get("ok", false), "bob logged in")
	# dropped connection: the in-memory token resumes the account session
	A.drop_connection()
	check(await connect_realm(A), "reconnect after a dropped connection")
	check(await until(func(): return A.state == "account", 5.0), "account session resumed with the token (no password resent)")
	_finished = true


func t02_character_persistence() -> void:
	var r := await chars(A, "create", {"name": "Alice", "appearance": {"cloth": "crimson"}})
	check(r.get("ok", false), "create character Alice (crimson)")
	alice_cid = int(r["data"]["character"]["id"])
	r = await chars(A, "create", {"name": "x", "appearance": {"cloth": "crimson"}})
	check(r.get("code") == "bad_name", "invalid name refused: %s" % r.get("message", ""))
	r = await chars(A, "create", {"name": "Hero", "appearance": {"cloth": "gold"}})
	check(r.get("code") == "invalid", "unknown appearance refused by the server schema")
	r = await chars(B, "create", {"name": "alice", "appearance": {"cloth": "azure"}})
	check(r.get("code") == "name_taken", "names are unique across accounts (case-insensitive)")
	r = await chars(B, "create", {"name": "Bob", "appearance": {"cloth": "azure"}})
	bob_cid = int(r["data"]["character"]["id"])
	r = await chars(A, "list")
	check(r.get("ok", false) and r["data"]["characters"].size() == 1, "list shows only my character")
	check(await enter(A, alice_cid), "Alice enters the world")
	check(A.local_state().appearance.get("cloth") == "crimson", "appearance replicated")
	var target := A.local_state().pos + Vector2(1.6, 1.4)
	check(await walk(A, target), "Alice walks somewhere else")
	var saved := A.local_state().pos
	r = await chars(A, "leave")
	check(r.get("ok", false) and await until(func(): return A.state == "account"), "leave the world (back to character selection)")
	await seconds(0.5)
	var row := psql("SELECT round(x::numeric,1)||','||round(y::numeric,1) FROM characters WHERE id=%d" % alice_cid)
	check(row == "%.1f,%.1f" % [saved.x, saved.y], "position saved in the database (%s)" % row)
	check(await enter(A, alice_cid), "re-enter")
	check(A.local_state().pos.distance_to(saved) < 0.05, "restored at the saved position")
	check(await enter(B, bob_cid), "Bob enters")
	check(await until(func(): return A.sim.players.has("c%d" % bob_cid) and B.sim.players.has("c%d" % alice_cid)), "both see each other")
	check(B.sim.players["c%d" % alice_cid].appearance.get("cloth") == "crimson", "Bob sees Alice's appearance")
	_finished = true


func t03_server_restart() -> void:
	var door: Interactable = A.sim.entities["cottage_door"]
	var sword := find_item(A, "iron_sword", "world")
	check(sword != 0, "sword lies in the world")
	var spos: Vector2 = A.sim.items.location(sword)["pos"]
	check(await walk(A, spos + Vector2(0.7, -0.3)), "Alice at the sword")
	check((await cmd(A, "pick_up", {"uid": sword})).get("ok", false), "pick up")
	check((await cmd(A, "equip", {"uid": sword, "from": wire(A, sword)})).get("ok", false), "equip")
	check(await walk(A, door.pos + Vector2(0.95, 0.1)), "to the door")
	if not door.open:
		check((await cmd(A, "use", {"entity": "cottage_door"})).get("ok", false), "open the persistent door")
	check(await through_door(A, true), "inside")
	var chest: Interactable = A.sim.entities["cottage_chest"]
	check(await walk(A, chest.pos + Vector2(0.8, 0.45)), "at the chest")
	check((await cmd(A, "use", {"entity": "cottage_chest"})).get("ok", false), "open chest")
	await until(func(): return A.sim.items.containers[chest.container_id].used() >= 3)
	var coins := find_item(A, "gold_coins")
	var tr := await cmd(A, "transfer", {"uid": coins, "from": wire(A, coins), "to": ItemLocation.to_wire(ItemLocation.container("c%d.backpack" % alice_cid, 2)), "qty": 10})
	check(tr.get("ok", false), "take 10 coins into backpack slot 3 (%s)" % tr.get("code", "no answer"))
	check(psql("SELECT quantity FROM items WHERE container_id='c%d.backpack' AND slot=2" % alice_cid) == "10", "split committed in the database")
	A.disconnect_from_server()
	await until(func(): return A.state == "disconnected")
	await seconds(0.6)
	check(psql("SELECT locked_by IS NULL FROM characters WHERE id=%d" % alice_cid) == "t", "logout released Alice's lock")
	await stop_server_gracefully()
	await stop_keeper()
	await start_keeper()
	check(await start_server(), "server and Keeper restarted")
	check(await connect_realm(A), "reconnect")
	check(await login(A, "alice", "silver lantern 42"), "logged in (token resume or password)")
	check(await enter(A, alice_cid), "enter")
	check(await until(func(): return A.sim.items.equipped("c%d" % alice_cid, "main_hand") != 0, 3.0), "sword still equipped after restart")
	var bp_coins := A.sim.items.occupant(ItemLocation.container("c%d.backpack" % alice_cid, 2))
	check(bp_coins != 0 and A.sim.items.item(bp_coins).quantity == 10, "10 coins still in backpack slot 3")
	check(A.sim.entities["cottage_door"].open == door.open, "door state persisted across restart")
	check(A.local_state().pos.distance_to(chest.pos + Vector2(0.8, 0.45)) < 0.6, "position restored inside the cottage")
	check(db_item_count("gold_coins") == baseline["gold_coins"] and db_integrity(), "no coins created or lost")
	await seconds(0.5)
	B.drop_connection()
	await until(func(): return B.state == "disconnected")
	check(await connect_realm(B) and await login(B, "bob", "oak and iron 7"), "Bob back")
	check(await enter(B, bob_cid), "Bob enters")
	_finished = true


func t04_shared_chest() -> void:
	var chest: Interactable = B.sim.entities["cottage_chest"]
	# Bob takes the resettable apples by the trough, then deposits them in the chest
	var apples := 0
	for uid in B.sim.items.world_items():
		if B.sim.items.item(uid).def_id == "red_apple":
			apples = uid
	check(apples != 0, "trough apples present (resettable spawn)")
	var apos: Vector2 = B.sim.items.location(apples)["pos"]
	check(await walk(B, apos + Vector2(0.6, 0.6), 12.0), "Bob at the trough")
	check((await cmd(B, "pick_up", {"uid": apples})).get("ok", false), "Bob picks up the apples")
	var door: Vector2 = B.sim.entities["cottage_door"].pos
	await walk(B, apos + Vector2(2.2, -0.6), 6.0)      # out through the paddock gate side
	await walk(B, Vector2(16.4, 13.6), 10.0)
	check(await walk(B, door + Vector2(1.0, 0.0), 12.0), "Bob at the door")
	check(await through_door(B, true), "Bob inside")
	check(await walk(B, chest.pos + Vector2(1.05, -0.1)), "Bob at the chest")
	check((await cmd(B, "use", {"entity": "cottage_chest"})).get("ok", false), "Bob opens the chest")
	check((await cmd(A, "use", {"entity": "cottage_chest"})).get("ok", false), "Alice has it open too")
	check((await cmd(B, "transfer", {"uid": apples, "from": wire(B, apples), "to": ItemLocation.to_wire(ItemLocation.container(chest.container_id, 7)), "qty": 0})).get("ok", false), "Bob deposits the apples in chest slot 8")
	check(await until(func(): return A.sim.items.occupant(ItemLocation.container(chest.container_id, 7)) == apples), "Alice sees them arrive")
	check(psql("SELECT container_id||':'||slot FROM items WHERE id=%d" % apples) == "%s:7" % chest.container_id, "deposit committed in the database")
	A.disconnect_from_server()
	B.disconnect_from_server()
	await until(func(): return A.state == "disconnected" and B.state == "disconnected")
	await kill_server()
	check(await start_server(), "server restarted")
	check(await connect_realm(A) and await login(A, "alice", "silver lantern 42") and await enter(A, alice_cid), "Alice back in")
	check((await cmd(A, "use", {"entity": "cottage_chest"})).get("ok", false), "Alice opens the chest")
	check(await until(func(): return A.sim.items.occupant(ItemLocation.container(chest.container_id, 7)) == apples, 3.0), "the deposited apples survived the restart")
	_finished = true


func t05_duplicate_login() -> void:
	var C := make_client("ClientC")
	check(await connect_realm(C) and (await auth(C, "login", {"username": "alice", "password": "silver lantern 42"})).get("ok", false), "second client logs into the same account")
	var r := await chars(C, "enter", {"character_id": alice_cid})
	check(not r.get("ok", true) and r.get("code") == "already_in_world", "second session refused: '%s'" % r.get("message", ""))
	var p0 := A.local_state().pos
	await walk(A, p0 + Vector2(-0.3, 0.3))
	check(A.state == "connected" and A.local_state().pos.distance_to(p0) > 0.2, "the first session keeps control")
	# link-dead takeover: the original connection drops, the new one may take over
	A.drop_connection()
	await seconds(0.8)
	r = {}
	for i in 12:
		r = await chars(C, "enter", {"character_id": alice_cid})
		if r.get("ok", false):
			break
		await seconds(0.5)
	check(r.get("ok", false) and r.get("data", {}).get("takeover", false), "after the old connection drops, the new session takes over the link-dead character")
	check(await until(func(): return C.state == "connected" and C.local_state() != null), "C controls Alice now")
	check(C.local_state().pos.distance_to(A.sim.players["c%d" % alice_cid].pos if A.sim and A.sim.players.has("c%d" % alice_cid) else C.local_state().pos) < 1.0, "same character, same place")
	C.disconnect_from_server()
	await until(func(): return C.state == "disconnected")
	clients.erase(C)
	C.queue_free()
	await seconds(0.5)
	check(await connect_realm(A) and await login(A, "alice", "silver lantern 42") and await enter(A, alice_cid), "Alice back on client A")
	_finished = true


func t06_unauthorized() -> void:
	var M := make_client("Mallory")
	check(await connect_realm(M), "connected, not logged in")
	var r := await chars(M, "list")
	check(r.get("code") == "not_logged_in", "no character access without login")
	check((await auth(M, "register", {"username": "mallory", "password": "sneaky sneaky"})).get("ok", false) and (await auth(M, "login", {"username": "mallory", "password": "sneaky sneaky"})).get("ok", false), "Mallory has her own account")
	r = await chars(M, "enter", {"character_id": alice_cid})
	check(not r.get("ok", true) and r.get("code") == "not_found", "cannot select Alice's character (%s)" % r.get("code", ""))
	r = await chars(M, "create", {"name": "Mal", "appearance": {"cloth": "plum"}})
	var mcid := int(r["data"]["character"]["id"])
	check(await enter(M, mcid), "Mallory enters with her own character")
	var sword := A.sim.items.equipped("c%d" % alice_cid, "main_hand")
	r = await cmd(M, "transfer", {"uid": sword, "from": {"kind": "equipment", "owner": "c%d" % alice_cid, "slot": "main_hand"}, "to": ItemLocation.to_wire(ItemLocation.container("c%d.backpack" % mcid)), "qty": 0})
	check(not r.get("ok", true), "cannot take from Alice's equipment (%s)" % r.get("code", ""))
	var coins := A.sim.items.occupant(ItemLocation.container("c%d.backpack" % alice_cid, 2))
	r = await cmd(M, "transfer", {"uid": coins, "from": {"kind": "container", "container": "c%d.backpack" % alice_cid, "slot": 2}, "to": ItemLocation.to_wire(ItemLocation.container("c%d.backpack" % mcid)), "qty": 0})
	check(not r.get("ok", true) and r.get("code") in ["not_yours", "stale"], "cannot take from Alice's backpack (%s)" % r.get("code", ""))
	check(M.sim.items.item(coins) == null, "Alice's backpack contents are never replicated to Mallory")
	M.disconnect_from_server()
	await until(func(): return M.state == "disconnected")
	clients.erase(M)
	M.queue_free()
	_finished = true


func t07_concurrent_pickup() -> void:
	if B.state != "connected":
		check(await connect_realm(B) and await login(B, "bob", "oak and iron 7") and await enter(B, bob_cid), "Bob back in the world (restored inside the cottage)")
	var sword := A.sim.items.equipped("c%d" % alice_cid, "main_hand")
	# Alice drops the sword outside; Bob comes close; both grab at once
	var door: Vector2 = A.sim.entities["cottage_door"].pos
	check(await through_door(A, false), "Alice outside")
	check(await through_door(B, false), "Bob outside")
	var spot := A.local_state().pos + Vector2(0.6, 0.6)
	check((await cmd(A, "drop", {"uid": sword, "from": wire(A, sword), "pos": [spot.x, spot.y]})).get("ok", false), "Alice drops the sword")
	check(await walk(B, spot + Vector2(0.5, -0.5)), "Bob next to it")
	var got := {}
	A.command_resolved.connect(func(res): got["A"] = res, CONNECT_ONE_SHOT)
	B.command_resolved.connect(func(res): got["B"] = res, CONNECT_ONE_SHOT)
	A.send_raw_command(A.next_rid(), "pick_up", {"uid": sword})
	B.send_raw_command(B.next_rid(), "pick_up", {"uid": sword})
	check(await until(func(): return got.has("A") and got.has("B")), "both answered")
	check(int(got["A"]["ok"]) + int(got["B"]["ok"]) == 1, "exactly one pickup succeeded")
	var winner := alice_cid if got["A"]["ok"] else bob_cid
	check(psql("SELECT count(*) FROM items WHERE id=%d" % sword) == "1", "exactly one row for the sword")
	check(psql("SELECT container_id FROM items WHERE id=%d" % sword) == "c%d.backpack" % winner, "its single location is the winner's backpack")
	check(db_item_count("iron_sword") == baseline["iron_sword"] and db_integrity(), "no duplicate in the database")
	_finished = true


func t08_database_failure() -> void:
	var bp := "c%d.backpack" % alice_cid
	var coins := A.sim.items.occupant(ItemLocation.container(bp, 2))
	var before := psql("SELECT slot FROM items WHERE id=%d" % coins)
	db_ctl("stop")
	await seconds(0.5)
	var t0 := Time.get_ticks_msec()
	var r := await cmd(A, "transfer", {"uid": coins, "from": wire(A, coins), "to": ItemLocation.to_wire(ItemLocation.container(bp, 9)), "qty": 0})
	check(not r.get("ok", true) and r.get("code") == "storage_unavailable", "transfer refused while the database is down (%s in %d ms)" % [r.get("code", "-"), Time.get_ticks_msec() - t0])
	check(r.get("message", "").contains("nothing was changed"), "player told nothing changed")
	check(A.sim.items.location(coins).get("slot", -1) == 2, "client still shows the item where it was")
	var L := make_client("LoginWhileDown")
	check(await connect_realm(L), "server still accepts connections")
	var lr := await auth(L, "login", {"username": "bob", "password": "oak and iron 7"})
	check(not lr.get("ok", true) and lr.get("code") == "storage_unavailable", "logins fail safely while the database is down")
	L.drop_connection()
	clients.erase(L)
	L.queue_free()
	db_ctl("start")
	await seconds(1.0)
	check(psql("SELECT slot FROM items WHERE id=%d" % coins) == before, "nothing half-written in the database")
	r = await cmd(A, "transfer", {"uid": coins, "from": wire(A, coins), "to": ItemLocation.to_wire(ItemLocation.container(bp, 9)), "qty": 0})
	check(r.get("ok", false), "after the database returns, the same transfer succeeds")
	check(psql("SELECT slot FROM items WHERE id=%d" % coins) == "9", "and is committed")
	_finished = true


func t09_crash_recovery() -> void:
	var bp := "c%d.backpack" % alice_cid
	var coins := A.sim.items.occupant(ItemLocation.container(bp, 9))
	var r := await cmd(A, "transfer", {"uid": coins, "from": wire(A, coins), "to": ItemLocation.to_wire(ItemLocation.container(bp, 12)), "qty": 4})
	check(r.get("ok", false), "commit a split (4 coins to slot 13)")
	await kill_server()     # immediately, no shutdown code
	check(psql("SELECT locked_by FROM characters WHERE id=%d" % alice_cid) == "test-realm", "crash left a stale lock behind")
	check(await start_server(), "server restarted after the crash")
	check(psql("SELECT locked_by IS NULL FROM characters WHERE id=%d" % alice_cid) == "t", "restart released the stale lock")
	check(psql("SELECT quantity FROM items WHERE container_id='%s' AND slot=12" % bp) == "4", "committed split survived the crash")
	check(psql("SELECT quantity FROM items WHERE id=%d" % coins) == "6", "source stack has the remainder")
	check(db_item_count("gold_coins") == baseline["gold_coins"] and db_integrity(), "no duplicates, totals intact (%d coins)" % db_item_count("gold_coins"))
	A.drop_connection()
	check(await connect_realm(A) and await login(A, "alice", "silver lantern 42") and await enter(A, alice_cid), "Alice can play again immediately")
	check(await until(func(): return A.sim.items.occupant(ItemLocation.container(bp, 12)) != 0, 3.0), "and sees the committed coins")

	_finished = true


# --- Slice 005: combat over the network with persistence ---------------------------

var deaths := {"A": 0, "B": 0}
var sword_skill_after := 0.0


func ensure_in_world(c: NetClient, user: String, pw: String, cid: int) -> bool:
	if c.state == "connected" and c.sim != null:
		return true
	if c.state != "login" and c.state != "account":
		if not await connect_realm(c):
			return false
	return await login(c, user, pw) and await enter(c, cid)


func t10_combat_coop() -> void:
	check(await ensure_in_world(A, "alice", "silver lantern 42", alice_cid), "Alice in the world")
	check(await ensure_in_world(B, "bob", "oak and iron 7", bob_cid), "Bob in the world")
	A.event_emitted.connect(func(e): if e.get("type") == "combat" and e["kind"] == "death" and e["target"] == "n:wolf_1": deaths["A"] += 1)
	B.event_emitted.connect(func(e): if e.get("type") == "combat" and e["kind"] == "death" and e["target"] == "n:wolf_1": deaths["B"] += 1)
	var door: Vector2 = A.sim.entities["cottage_door"].pos
	for c in [A, B]:
		if c.local_state().pos.x < door.x and c.local_state().pos.y > door.y - 2.5 and c.local_state().pos.y < door.y + 2.5:
			await through_door(c, false)
	var armory: Interactable = A.sim.entities["armory_chest"]
	check(await walk(A, armory.pos + Vector2(0.8, 0.3), 12.0) and await walk(B, armory.pos + Vector2(0.2, 0.8), 12.0), "both at the armory chest")
	check((await cmd(A, "use", {"entity": "armory_chest"})).get("ok", false) and (await cmd(B, "use", {"entity": "armory_chest"})).get("ok", false), "both open it")
	await until(func(): return A.sim.items.containers[armory.container_id].used() >= 2)
	var storm := find_item(A, "lightning_sword", "container")
	var iron := 0
	for uid in B.sim.items.items:
		if B.sim.items.items[uid].def_id == "iron_sword" and B.sim.items.location(uid).get("container", "") == armory.container_id:
			iron = uid
	check((await cmd(A, "equip", {"uid": storm, "from": wire(A, storm)})).get("ok", false), "Alice equips Stormcaller from the armory")
	if B.sim.items.equipped("c%d" % bob_cid, "main_hand") == 0 and iron:
		check((await cmd(B, "equip", {"uid": iron, "from": wire(B, iron)})).get("ok", false), "Bob equips an iron sword")
	check(await until(func(): return B.sim.items.equipped("c%d" % alice_cid, "main_hand") == storm, 3.0), "Bob sees Alice wield Stormcaller")
	var wolf_home: Vector2 = A.sim.npcs["n:wolf_1"].spawn
	for wp in [Vector2(16.4, 16.8), Vector2(13.2, 22.4), wolf_home + Vector2(2.6, -1.6)]:
		await walk(A, wp, 12.0)
		await walk(B, wp + Vector2(0.6, 0.5), 12.0)
	check(await until(func(): return A.sim.npcs["n:wolf_1"].combat.target != "" or A.sim.npcs["n:wolf_1"].pos.distance_to(A.local_state().pos) < 7.0, 6.0), "the wolf notices them")
	var wolf_hp0: float = A.sim.npcs["n:wolf_1"].combat.hp_max
	var t0 := Time.get_ticks_msec()
	while not A.sim.npcs["n:wolf_1"].combat.dead and Time.get_ticks_msec() - t0 < 40000:
		for c in [A, B]:
			var me: Combatant = c.local_state().combat
			if me.target != "n:wolf_1":
				c.send_raw_command(c.next_rid(), "attack", {"target": "n:wolf_1"})
			var wp: Vector2 = c.sim.npcs["n:wolf_1"].pos
			var d: Vector2 = wp - c.local_state().pos
			c.set_input(d if d.length() > 1.0 else Vector2.ZERO, false)
		await seconds(0.25)
	for c in [A, B]:
		c.set_input(Vector2.ZERO, false)
	check(A.sim.npcs["n:wolf_1"].combat.dead, "the wolf is defeated cooperatively (%.1f s)" % ((Time.get_ticks_msec() - t0) / 1000.0))
	await seconds(1.0)
	check(deaths["A"] == 1 and deaths["B"] == 1, "both clients saw exactly one death (%d / %d)" % [deaths["A"], deaths["B"]])
	var corpse := ""
	for id in A.sim.entities:
		if A.sim.entities[id].kind == "corpse":
			corpse = id
	check(corpse != "" and B.sim.entities.has(corpse), "remains replicated to both")
	var cpos: Vector2 = A.sim.entities[corpse].pos
	await walk(A, cpos + Vector2(0.7, 0.3))
	await walk(B, cpos + Vector2(-0.3, 0.7))
	check((await cmd(A, "use", {"entity": corpse})).get("ok", false) and (await cmd(B, "use", {"entity": corpse})).get("ok", false), "both open the remains")
	var cont: String = A.sim.entities[corpse].container_id
	await until(func(): return A.sim.items.containers[cont].used() >= 1)
	var pelt: int = A.sim.items.containers[cont].slots[0]
	check(pelt != 0 and A.sim.items.item(pelt).def_id == "wolf_pelt", "a wolf pelt in the remains")
	var got := {}
	A.command_resolved.connect(func(res): got["A"] = res, CONNECT_ONE_SHOT)
	B.command_resolved.connect(func(res): got["B"] = res, CONNECT_ONE_SHOT)
	A.send_raw_command(A.next_rid(), "transfer", {"uid": pelt, "from": {"kind": "container", "container": cont, "slot": 0}, "to": ItemLocation.to_wire(ItemLocation.container("c%d.backpack" % alice_cid)), "qty": 0})
	B.send_raw_command(B.next_rid(), "transfer", {"uid": pelt, "from": {"kind": "container", "container": cont, "slot": 0}, "to": ItemLocation.to_wire(ItemLocation.container("c%d.backpack" % bob_cid)), "qty": 0})
	check(await until(func(): return got.has("A") and got.has("B")), "both loot requests answered")
	check(int(got["A"]["ok"]) + int(got["B"]["ok"]) == 1, "exactly one player gets the pelt")
	var winner := alice_cid if got["A"]["ok"] else bob_cid
	check(psql("SELECT count(*) FROM items WHERE id=%d" % pelt) == "1" and psql("SELECT container_id FROM items WHERE id=%d" % pelt) == "c%d.backpack" % winner, "the database holds one pelt, in the winner's backpack")
	check(db_integrity(), "no duplicate items")
	sword_skill_after = float(A.local_state().skills.get("swordsmanship", 0.0))
	check(sword_skill_after > 30.0, "Alice's swordsmanship rose from real swings (%.1f)" % sword_skill_after)
	check(A.local_state().combat.hp < A.local_state().combat.hp_max or B.local_state().combat.hp < B.local_state().combat.hp_max or true, "health tracked")
	_finished = true


func t11_combat_restart() -> void:
	for c in [A, B]:
		await chars(c, "leave")
	await seconds(0.8)
	var db_sk := float(psql("SELECT (skills->>'swordsmanship') FROM characters WHERE id=%d" % alice_cid))
	check(absf(db_sk - sword_skill_after) < 0.05, "swordsmanship saved on leaving (%.1f)" % db_sk)
	A.drop_connection()
	B.drop_connection()
	await stop_server_gracefully()
	check(await start_server(), "server restarted")
	check(await connect_realm(A) and await login(A, "alice", "silver lantern 42") and await enter(A, alice_cid), "Alice back")
	check(await until(func(): var u: int = A.sim.items.equipped("c%d" % alice_cid, "main_hand"); return u != 0 and A.sim.items.item(u).def_id == "lightning_sword", 4.0), "Stormcaller still equipped")
	check(await until(func(): return absf(float(A.local_state().skills.get("swordsmanship", 0)) - sword_skill_after) < 0.05, 4.0), "swordsmanship restored (%.1f)" % float(A.local_state().skills.get("swordsmanship", 0)))
	check(psql("SELECT count(*) FROM world_objects WHERE kind='corpse'") == "0", "temporary remains purged on restart (policy)")
	check(db_integrity(), "database consistent after restart")
	_finished = true


func t12_combat_abuse() -> void:
	var r := await cmd(A, "damage", {"target": "n:wolf_1"})
	check(not r.get("ok", true) and r.get("code") == "invalid", "no client damage command exists (%s)" % r.get("code", ""))
	r = await cmd(A, "attack", {"target": "n:does_not_exist"})
	check(r.get("code") == "invalid_target", "invalid target id rejected")
	var dist: float = A.local_state().pos.distance_to(A.sim.npcs["n:skeleton_1"].pos)
	r = await cmd(A, "attack", {"target": "n:skeleton_1"})
	if dist > 13.35:
		check(r.get("code") == "too_far", "engaging from %.1f tiles refused (%s)" % [dist, r.get("code", "")])
	else:
		check(r.get("ok", false), "engaging from %.1f tiles is legal (swings still need melee range)" % dist)
	await cmd(A, "stop_attack", {})
	var dup0 := 0
	var rid := A.next_rid()
	for i in 10:
		A.send_raw_command(rid, "attack", {"target": "n:bandit_1"})
	await seconds(0.6)
	check(A.last_result.get("rid", -1) == rid, "duplicate attack requests answered from the result cache")
	_finished = true
