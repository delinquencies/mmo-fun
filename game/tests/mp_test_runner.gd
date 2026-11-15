extends Node

const PORT := 24711

var server: GameServer
var A: NetClient
var B: NetClient
var checks := 0
var fails := 0
var current := ""
var baseline_totals := {}


func _ready() -> void:
	_run.call_deferred()


func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
	print("   %s [%s] %s" % ["ok  " if cond else "FAIL", current, what])


func frames(n := 1) -> void:
	for i in n:
		await get_tree().process_frame


func seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout


func until(cond: Callable, timeout := 5.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t0 > timeout * 1000.0:
			return false
		await get_tree().process_frame
	return true


func make_client(n: String) -> NetClient:
	var c := NetClient.new()
	c.name = n
	get_tree().root.add_child(c)
	return c


func connect_client(c: NetClient, nm: String) -> bool:
	c.connect_to("127.0.0.1", PORT, nm)
	return await until(func(): return c.state == "connected", 6.0)


## Walk a client toward a target using real inputs (prediction + server authority).
func walk(c: NetClient, target: Vector2, timeout := 8.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while server.sim.actor_pos(c.actor).distance_to(target) > 0.12:
		if Time.get_ticks_msec() - t0 > timeout * 1000.0:
			c.set_input(Vector2.ZERO, false)
			return false
		var here := c.local_state().pos
		var d := target - here
		c.set_input(d if d.length() > 0.08 else Vector2.ZERO, false)
		await get_tree().process_frame
	c.set_input(Vector2.ZERO, false)
	await seconds(0.25)
	return true


## Enter/leave the cottage through the doorway centre line.
func through_door(c: NetClient, inward: bool, lane := 0.0) -> bool:
	var d: Vector2 = server.sim.entities["cottage_door"].pos
	var outside := d + Vector2(1.0, lane)
	var inside := d + Vector2(-0.85, lane)
	var ok := await walk(c, outside if inward else inside)
	ok = ok and await walk(c, d + Vector2(0.2, lane) if inward else d + Vector2(-0.4, lane))
	ok = ok and await walk(c, inside if inward else outside)
	return ok


func cmd(c: NetClient, type: String, args: Dictionary) -> Dictionary:
	var rid := c.next_rid()
	c.send_raw_command(rid, type, args)
	await until(func(): return c.last_result.get("rid", -1) == rid, 4.0)
	return c.last_result if c.last_result.get("rid", -1) == rid else {}


func totals() -> Dictionary:
	var t := {}
	for d in server.sim.items.defs:
		t[d] = server.sim.items.total_quantity(d)
	return t


func find(def_id: String) -> int:
	for uid in server.sim.items.items:
		if server.sim.items.items[uid].def_id == def_id:
			return uid
	return 0


## Every item the server lets `c` see must match the replica exactly, and the
## replica must hold nothing else.
func replica_consistent(c: NetClient) -> bool:
	var ok := true
	var seen := {}
	for uid in server.sim.items.items:
		var loc := server.sim.items.location(uid)
		if server._visible(c.actor, loc):
			seen[uid] = true
			var r := c.sim.items.item(uid)
			if r == null or r.quantity != server.sim.items.item(uid).quantity \
					or not ItemLocation.same(c.sim.items.location(uid), loc):
				print("      replica mismatch uid %d: server %s / client %s" % [uid, ItemLocation.describe(loc), ItemLocation.describe(c.sim.items.location(uid))])
				ok = false
	for uid in c.sim.items.items:
		if not seen.has(uid):
			print("      replica holds invisible/stale uid %d" % uid)
			ok = false
	return ok


func server_ok() -> bool:
	var e := server.sim.items.check_invariants()
	if not e.is_empty():
		print("      server invariants: ", e)
	return e.is_empty() and totals() == baseline_totals


# ------------------------------------------------------------------------------

func _run() -> void:
	server = GameServer.new()
	server.name = "Server"
	server.verbose = false
	server.linger = 1.0
	get_tree().root.add_child(server)
	if server.start(PORT) != OK:
		print("could not start server")
		get_tree().quit(2)
		return
	baseline_totals = totals()
	A = make_client("ClientA")
	B = make_client("ClientB")
	for t in ["t01_two_clients", "t02_shared_door", "t03_shared_chest", "t04_simultaneous_pickup",
			"t05_equipment_replication", "t06_invalid_movement", "t09_repeated_mutations",
			"t08_latency", "t07_disconnect", "t10_stability", "t11_protocol_garbage"]:
		current = t
		var before := fails
		await call(t)
		print("%s %s" % ["PASS" if fails == before else "FAIL", t])
	print("\n%d checks, %d failures" % [checks, fails])
	print("server stats: %s" % JSON.stringify(server.stats))
	get_tree().quit(1 if fails else 0)


func t01_two_clients() -> void:
	check(await connect_client(A, "Alice"), "Alice connected")
	check(await connect_client(B, "Bob"), "Bob connected")
	check(A.session_id != "" and A.session_id != B.session_id, "distinct server-assigned sessions (%s / %s)" % [A.session_id, B.session_id])
	check(await until(func(): return A.sim.players.has(B.actor) and B.sim.players.has(A.actor)), "each client knows the other player")
	check(B.sim.players[A.actor].display_name == "Alice", "names replicated")
	var start := server.sim.actor_pos(A.actor)
	A.set_input(Vector2(1, -1), false)     # screen-right
	await seconds(0.8)
	A.set_input(Vector2.ZERO, false)
	await seconds(0.4)
	var sp := server.sim.actor_pos(A.actor)
	check(sp.distance_to(start) > 1.5, "server moved Alice by her intent (%.2f tiles)" % sp.distance_to(start))
	check(await until(func(): return B.sim.players[A.actor].render_pos.distance_to(sp) < 0.05, 2.0), "Bob sees Alice where the server says")
	check(B.sim.players[A.actor].render_facing == Iso.dir_index(Vector2(1, -1)), "Bob sees Alice's facing (E)")
	check(A.local_state().render_pos.distance_to(sp) < 0.05, "Alice's predicted position agrees with the server")


func _door_spot(off: Vector2) -> Vector2:
	return server.sim.entities["cottage_door"].pos + off


func t02_shared_door() -> void:
	var door: Interactable = server.sim.entities["cottage_door"]
	check(await walk(A, _door_spot(Vector2(0.95, -0.3))), "Alice reached the door")
	check(await walk(B, _door_spot(Vector2(1.0, 0.55))), "Bob reached the door")
	var r := await cmd(A, "use", {"entity": "cottage_door"})
	check(r.get("ok", false) and door.open, "Alice opens the door (server state)")
	check(await until(func(): return B.sim.entities["cottage_door"].open), "Bob sees the door open")
	check(not B.sim.is_blocked(door.pos + Vector2(-0.15, 0), 0.24), "Bob's collision reflects the open door")
	r = await cmd(B, "set_door", {"entity": "cottage_door", "open": false})
	check(r.get("ok", false) and not door.open, "Bob closes the door")
	check(await until(func(): return not A.sim.entities["cottage_door"].open), "Alice sees it close")
	check(server.sim.is_blocked(door.pos + Vector2(-0.15, 0), 0.24) and A.sim.is_blocked(door.pos + Vector2(-0.15, 0), 0.24), "closed collision on server and Alice's replica")
	r = await cmd(B, "set_door", {"entity": "cottage_door", "open": false})
	check(not r.get("ok", true), "closing an already-closed door is rejected (idempotent)")
	r = await cmd(A, "use", {"entity": "cottage_door"})
	check(r.get("ok", false), "Alice reopens it for the next test")


func t03_shared_chest() -> void:
	var chest: Interactable = server.sim.entities["cottage_chest"]
	check(await through_door(A, true, -0.05), "Alice walks in")
	check(await walk(A, chest.pos + Vector2(0.8, 0.45)), "Alice at the chest")
	check(await through_door(B, true, 0.05), "Bob walks in")
	check(await walk(B, chest.pos + Vector2(1.05, -0.1)), "Bob at the chest")
	check((await cmd(A, "use", {"entity": "cottage_chest"})).get("ok", false), "Alice opens the chest")
	check((await cmd(B, "use", {"entity": "cottage_chest"})).get("ok", false), "Bob opens the same chest")
	var cid := chest.container_id
	check(await until(func(): return A.sim.items.containers[cid].used() == 3 and B.sim.items.containers[cid].used() == 3), "both see the 3 items")
	var apples := find("red_apple")
	var r := await cmd(A, "transfer", {"uid": apples, "from": ItemLocation.to_wire(server.sim.items.location(apples)), "to": ItemLocation.to_wire(ItemLocation.container(A.actor + ".backpack")), "qty": 0})
	check(r.get("ok", false), "Alice takes the apples")
	check(await until(func(): return B.sim.items.containers[cid].used() == 2 and B.sim.items.item(apples) == null), "Bob's chest view updates (apples gone, not visible in Alice's pack)")
	check(A.sim.items.location(apples).get("container", "") == A.actor + ".backpack", "apples in Alice's replica backpack")
	check(replica_consistent(A) and replica_consistent(B) and server_ok(), "replicas consistent, totals conserved")


func t04_simultaneous_pickup() -> void:
	var sword := find("iron_sword")
	var spos: Vector2 = server.sim.items.location(sword)["pos"]
	check(await through_door(A, false, -0.05), "Alice walks out")
	await walk(A, _door_spot(Vector2(1.4, -0.6)))
	check(await through_door(B, false, 0.05), "Bob walks out")
	check(await walk(A, spos + Vector2(0.7, -0.4)), "Alice beside the sword")
	check(await walk(B, spos + Vector2(-0.3, 0.75)), "Bob beside the sword")
	var ra := A.next_rid()
	var rb := B.next_rid()
	var got := {}
	A.command_resolved.connect(func(res): got["A"] = res)
	B.command_resolved.connect(func(res): got["B"] = res)
	A.send_raw_command(ra, "pick_up", {"uid": sword})
	B.send_raw_command(rb, "pick_up", {"uid": sword})
	check(await until(func(): return got.has("A") and got.has("B")), "both got a result")
	var oks := int(got["A"]["ok"]) + int(got["B"]["ok"])
	check(oks == 1, "exactly one pickup succeeded (%s / %s)" % [got["A"]["code"], got["B"]["code"]])
	var loser: Dictionary = got["B"] if got["A"]["ok"] else got["A"]
	check(loser["code"] == "stale" and loser["message"] != "", "the other got a clear failure: '%s'" % loser["message"])
	var winner: NetClient = A if got["A"]["ok"] else B
	var other: NetClient = B if winner == A else A
	check(server.sim.items.location(sword).get("container", "") == winner.actor + ".backpack", "sword in the winner's backpack on the server")
	check(await until(func(): return other.sim.items.item(sword) == null and other.sim.items.world_items().is_empty()), "the other client sees it vanish from the ground")
	check(server_ok(), "item total unchanged")
	_winner = winner


var _winner: NetClient


func t05_equipment_replication() -> void:
	var w: NetClient = _winner
	var o: NetClient = B if w == A else A
	var sword := find("iron_sword")
	var r := await cmd(w, "equip", {"uid": sword, "from": ItemLocation.to_wire(server.sim.items.location(sword))})
	check(r.get("ok", false), "%s equips the sword" % w.player_name)
	check(await until(func(): return o.sim.items.equipped(w.actor, "main_hand") == sword), "%s sees the sword in %s's main hand" % [o.player_name, w.player_name])
	var d := o.sim.items.def(o.sim.items.item(sword).def_id)
	check(d.paperdoll_layer == "iron_sword", "observer has the weapon layer to draw")
	r = await cmd(w, "unequip", {"slot": "main_hand"})
	check(r.get("ok", false), "unequip")
	check(await until(func(): return o.sim.items.equipped(w.actor, "main_hand") == 0 and o.sim.items.item(sword) == null), "observer sees the hand empty again (sword back in a private backpack)")
	r = await cmd(w, "equip", {"uid": sword, "from": ItemLocation.to_wire(server.sim.items.location(sword))})
	check(r.get("ok", false), "re-equip for later tests")
	check(replica_consistent(A) and replica_consistent(B), "replicas consistent")


func t06_invalid_movement() -> void:
	var p0 := server.sim.actor_pos(A.actor)
	var rej0: int = server.stats["rejected_inputs"]
	var bad := [[999999, 50.0, 0.0, true], [999998, NAN, 1.0, false], [999997, 0.0, INF, false], ["x", 1, 0, false], [1, 2]]
	A.net.send(1, Protocol.make(Protocol.INPUT, {"inputs": bad}), false)
	A.net.send(1, {"v": Protocol.VERSION, "t": Protocol.INPUT, "inputs": [], "pos": [5.0, 5.0]}, false)
	await seconds(0.4)
	check(server.stats["rejected_inputs"] >= rej0 + 5, "oversized / NaN / malformed inputs rejected (%d)" % (server.stats["rejected_inputs"] - rej0))
	check(server.sim.actor_pos(A.actor).distance_to(p0) < 0.01, "no movement and no teleport from bad inputs")
	var tp := await cmd(A, "teleport", {"pos": [5.0, 5.0]})
	check(not tp.get("ok", true) and tp.get("code", "") == "invalid", "a 'teleport' command does not exist (%s)" % tp.get("code", ""))
	# speed hack: flood 200 valid run inputs in one burst, ahead of the client's own sequence
	var start_seq := A._seq + 10
	var flood := []
	for i in 200:
		flood.append([start_seq + i, 1.0, 0.0, true])
	var t0 := server.time
	for chunk in range(0, 200, 5):
		A.net.send(1, Protocol.make(Protocol.INPUT, {"inputs": flood.slice(chunk, chunk + 5)}), false)
	A._seq = start_seq + 200
	var jump := 0.0
	var last: Vector2 = B.sim.players[A.actor].render_pos
	var w0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - w0 < 1000:
		await frames(1)
		var now: Vector2 = B.sim.players[A.actor].render_pos
		jump = maxf(jump, now.distance_to(last))
		last = now
	var moved := server.sim.actor_pos(A.actor).distance_to(p0)
	var elapsed := server.time - t0
	check(moved <= WorldSim.RUN_SPEED * elapsed + 0.2, "flooded inputs cannot exceed run speed (%.2f tiles in %.2fs, cap %.2f)" % [moved, elapsed, WorldSim.RUN_SPEED * elapsed])
	check(server.stats["excess_inputs"] > 100, "excess inputs dropped (%d)" % server.stats["excess_inputs"])
	check(jump < 0.4, "Bob never sees Alice jump (max %.3f tiles/frame)" % jump)
	await walk(A, server.sim.spawn_point + Vector2(1.2, 1.4))


func t09_repeated_mutations() -> void:
	var w: NetClient = _winner
	var chest: Interactable = server.sim.entities["cottage_chest"]
	check(await through_door(w, true, 0.0), "back inside")
	check(await walk(w, chest.pos + Vector2(0.8, 0.45)), "at the chest")
	await cmd(w, "use", {"entity": "cottage_chest"})
	var coins := find("gold_coins")
	var from := ItemLocation.to_wire(server.sim.items.location(coins))
	var to := ItemLocation.to_wire(ItemLocation.container(w.actor + ".backpack"))
	var dup0: int = server.stats["duplicates"]
	var rid := w.next_rid()
	for i in 10:   # identical message, identical request id
		w.send_raw_command(rid, "transfer", {"uid": coins, "from": from, "to": to, "qty": 0})
	await seconds(0.5)
	check(server.stats["duplicates"] - dup0 == 9, "same request id executed once, 9 duplicates answered from cache")
	var oks := 0
	var results := []
	w.command_resolved.connect(func(res): results.append(res))
	for i in 10:   # same business operation, fresh request ids (replay attack)
		w.send_raw_command(w.next_rid(), "transfer", {"uid": coins, "from": from, "to": to, "qty": 0})
	await until(func(): return results.size() >= 10)
	for res in results:
		oks += int(res["ok"])
	check(oks == 0, "replays with new ids all rejected as stale (%d ok)" % oks)
	check(server.sim.items.item(coins).quantity == 25 and server_ok(), "coins not duplicated, totals conserved")
	# move them back, so later tests start from a known state
	var r := await cmd(w, "transfer", {"uid": coins, "from": ItemLocation.to_wire(server.sim.items.location(coins)), "to": from, "qty": 0})
	check(r.get("ok", false), "coins returned to the chest")
	check(replica_consistent(w), "replica consistent")


func t08_latency() -> void:
	A.net.configure(120.0, 40.0, 0.1, 7)
	server.net.configure(80.0, 30.0, 0.1, 9)
	if server.sim.actor_pos(A.actor).x < server.sim.entities["cottage_door"].pos.x:
		check(await through_door(A, false, 0.0), "walk out under 120ms+jitter, 10% loss")
	check(await walk(A, _door_spot(Vector2(1.6, 0.4)), 12.0), "walk under 120ms+jitter, 10% loss")
	var maxjump := 0.0
	var last: Vector2 = B.sim.players[A.actor].render_pos
	var target := A.local_state().pos + Vector2(2.5, -2.5)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 1800:
		var d := target - A.local_state().pos
		A.set_input(d if d.length() > 0.1 else Vector2.ZERO, false)
		await frames(1)
		var now: Vector2 = B.sim.players[A.actor].render_pos
		maxjump = maxf(maxjump, now.distance_to(last))
		last = now
	A.set_input(Vector2.ZERO, false)
	check(maxjump < 0.6, "remote movement stays coherent (max %.3f tiles/frame)" % maxjump)
	await seconds(1.0)
	var sp := server.sim.actor_pos(A.actor)
	check(await until(func(): return B.sim.players[A.actor].render_pos.distance_to(sp) < 0.05, 3.0), "Bob converges to the authoritative position")
	check(await until(func(): return A.local_state().render_pos.distance_to(sp) < 0.1, 3.0), "Alice's prediction converges (corrections so far: %d, max %.2f)" % [A.corrections, A.max_correction])
	var r := await cmd(A, "set_door", {"entity": "cottage_door", "open": false})
	check(not r.is_empty(), "commands still resolve under latency (answer: %s)" % (r.get("code", "") if not r.get("ok", false) else "ok"))
	var pre := await cmd(A, "pick_up", {"uid": find("iron_sword")})
	check(not pre.is_empty() and server_ok(), "item command under latency resolves without corrupting state (%s)" % pre.get("code", "ok"))
	check(await until(func(): return B.sim.entities["cottage_door"].open == server.sim.entities["cottage_door"].open, 3.0), "door state agrees everywhere")
	A.net.configure(0, 0, 0)
	server.net.configure(0, 0, 0)
	await seconds(0.5)
	check(replica_consistent(A) and replica_consistent(B) and server_ok(), "no state corruption under latency/loss")


func t07_disconnect() -> void:
	var sword := find("iron_sword")
	var holder: NetClient = _winner
	var watcher: NetClient = B if holder == A else A
	var holder_actor: String = holder.actor
	var old_session: String = holder.session_id
	holder.drop_connection()       # no goodbye: like a crash or a pulled cable
	check(await until(func(): return server.sessions.values().any(func(s): return s["actor"] == holder_actor and s["state"] == "linkdead"), 8.0), "server marks the character link-dead")
	check(await until(func(): return watcher.sim.players.has(holder_actor) and watcher.sim.players[holder_actor].linkdead, 3.0), "the other player sees the link-dead state")
	check(await until(func(): return not server.sim.players.has(holder_actor), 4.0), "character removed after the linger timeout")
	check(await until(func(): return not watcher.sim.players.has(holder_actor), 3.0), "removal replicated")
	check(server.sim.items.location(sword).get("kind", "") == "world", "the sword they carried was left on the ground, not lost")
	check(await until(func(): return watcher.sim.items.world_items().has(sword), 3.0), "the remaining player sees the dropped sword")
	check(server_ok(), "totals conserved through the disconnect")
	check(watcher.state == "connected" and server.active_count() == 1, "server keeps running with the other player")
	var r := await cmd(watcher, "set_door", {"entity": "cottage_door", "open": not server.sim.entities["cottage_door"].open})
	check(r.get("ok", false) or r.get("code", "") == "too_far", "remaining player can still act (%s)" % r.get("code", "ok"))
	check(await connect_client(holder, holder.player_name), "the dropped client reconnects")
	check(holder.session_id != old_session, "and gets a fresh temporary session")
	check(await until(func(): return replica_consistent(holder) and replica_consistent(watcher), 3.0), "both replicas consistent after reconnect")


func t10_stability() -> void:
	var nodes0 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var objs0 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var mem0 := Performance.get_monitor(Performance.MEMORY_STATIC)
	var items0 := server.sim.items.items.size()
	var door_spot_a := _door_spot(Vector2(0.95, -0.3))
	var door_spot_b := _door_spot(Vector2(1.0, 0.55))
	check(await walk(A, door_spot_a), "A at door")
	check(await walk(B, door_spot_b), "B at door")
	var sword := find("iron_sword")
	for i in 30:
		await cmd(A if i % 2 == 0 else B, "use", {"entity": "cottage_door"})
		var c: NetClient = A if i % 3 == 0 else B
		if server.sim.items.location(sword).get("kind", "") == "world":
			var spos: Vector2 = server.sim.items.location(sword)["pos"]
			if server.sim.actor_pos(c.actor).distance_to(spos) <= 2.0:
				await cmd(c, "pick_up", {"uid": sword})
		else:
			var loc := server.sim.items.location(sword)
			var owner: NetClient = A if loc.get("container", loc.get("owner", "")).begins_with(A.actor) else B
			var p := server.sim.actor_pos(owner.actor) + Vector2(0.5, 0.4)
			await cmd(owner, "drop", {"uid": sword, "from": ItemLocation.to_wire(loc), "pos": [p.x, p.y]})
		A.set_input(Vector2(1, 0) if i % 2 == 0 else Vector2(-1, 0), false)
		await frames(3)
		A.set_input(Vector2.ZERO, false)
	# session churn: a third client joins and leaves repeatedly
	var C := make_client("ClientC")
	for i in 6:
		check(await connect_client(C, "Churn"), "churn connect %d" % i) if i == 0 else await connect_client(C, "Churn")
		C.disconnect_from_server()
		await until(func(): return C.state == "disconnected", 3.0)
		await seconds(0.15)
	await until(func(): return server.sessions.size() == 2 and server.sim.players.size() == 2, 5.0)
	C.queue_free()
	await seconds(0.5)
	check(server.sessions.size() == 2 and server.sim.players.size() == 2, "no orphaned sessions or players (%d / %d)" % [server.sessions.size(), server.sim.players.size()])
	check(server.sim.items.items.size() == items0, "no accumulating item instances (%d -> %d)" % [items0, server.sim.items.items.size()])
	var nodes1 := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var objs1 := Performance.get_monitor(Performance.OBJECT_COUNT)
	var mem1 := Performance.get_monitor(Performance.MEMORY_STATIC)
	check(nodes1 <= nodes0 + 2, "node count stable (%d -> %d)" % [nodes0, nodes1])
	check(objs1 < objs0 + 400, "object count stable (%d -> %d)" % [objs0, objs1])
	print("      static memory %.1f MB -> %.1f MB" % [mem0 / 1048576.0, mem1 / 1048576.0])
	check(mem1 < mem0 + 16 * 1048576.0, "no runaway memory")
	check(replica_consistent(A) and replica_consistent(B) and server_ok(), "consistent after %d interaction cycles" % 30)


func t11_protocol_garbage() -> void:
	var inv0: int = server.stats["invalid_messages"]
	A.net.send(1, {"v": 99, "t": "cmd", "rid": 1, "cmd": {}})
	A.net.send(1, {"v": Protocol.VERSION, "t": "welcome"})
	A.net.send(1, {"v": Protocol.VERSION, "t": "cmd", "rid": "x", "cmd": {}})
	A.net.send(1, {"v": Protocol.VERSION, "t": "cmd", "rid": A.next_rid(), "cmd": {"type": "transfer", "args": {"uid": -5, "from": {"kind": "world", "pos": [1, 2]}, "to": {}, "qty": 1}}})
	A.net._r.rpc_id(1, "just a string")
	var r := await cmd(A, "transfer", {"uid": 1, "from": {"kind": "container", "container": B.actor + ".backpack", "slot": 0}, "to": {"kind": "container", "container": A.actor + ".backpack", "slot": -1}, "qty": 0})
	check(not r.get("ok", true), "cannot take from another player's backpack (%s)" % r.get("code", ""))
	await seconds(0.3)
	check(server.stats["invalid_messages"] >= inv0 + 4, "malformed messages counted and ignored (%d)" % (server.stats["invalid_messages"] - inv0))
	check(A.state == "connected" and server_ok(), "server and client unaffected")
