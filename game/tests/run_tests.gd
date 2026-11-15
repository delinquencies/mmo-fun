extends SceneTree
## Headless test runner for the authoritative interaction / item layer.
##   godot --headless --path game --script res://tests/run_tests.gd
## Exit code 0 = all passed.

const MAP := "res://data/maps/homestead.json"
const P := "player"

var failures := 0
var _finished := false
var checks := 0
var current := ""


func _init() -> void:
	var tests := [
		"test_01_door", "test_02_pickup", "test_03_equip", "test_04_chest_transfer",
		"test_05_invalid", "test_06_rapid_duplicate", "test_06b_random_fuzz",
		"test_stack_split_merge", "test_capacity", "test_auto_close", "test_wire_roundtrip",
		"test_definition_of_done",
	]
	for t in tests:
		current = t
		var before := failures
		_finished = false
		call(t)
		if not _finished:
			failures += 1
			print("   x [%s] test did not run to completion (script error)" % t)
		print("%s %s" % ["PASS" if failures == before else "FAIL", t])
	print("\n%d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("   x [%s] %s" % [current, what])


func new_sim() -> WorldSim:
	var s := WorldSim.new()
	s.load_map(MAP)
	return s


func cmd_use(s: WorldSim, eid: String) -> CommandResult:
	return s.interaction.submit(InteractionCommand.use_entity(P, eid))


func cmd_move(s: WorldSim, uid: int, to: Dictionary, qty := 0) -> CommandResult:
	return s.interaction.submit(InteractionCommand.transfer(P, uid, s.items.location(uid), to, qty))


func find(s: WorldSim, def_id: String, kind := "") -> int:
	for uid in s.items.items:
		if s.items.items[uid].def_id == def_id and (kind == "" or s.items.location(uid)["kind"] == kind):
			return uid
	return 0


func totals(s: WorldSim) -> Dictionary:
	var t := {}
	for d in s.items.defs:
		t[d] = s.items.total_quantity(d)
	return t


func invariants_ok(s: WorldSim) -> bool:
	var e := s.items.check_invariants()
	if not e.is_empty():
		print("      invariant: ", e)
	return e.is_empty()


func walk(s: WorldSim, dir: Vector2, seconds: float) -> void:
	var t := 0.0
	while t < seconds:
		s.step_player(1.0 / 60.0, dir, false)
		s.interaction.update(1.0 / 60.0)
		t += 1.0 / 60.0


func walk_to(s: WorldSim, target: Vector2, max_s := 4.0) -> void:
	var t := 0.0
	while t < max_s and s.player_pos.distance_to(target) > 0.08:
		s.step_player(1.0 / 60.0, target - s.player_pos, false)
		s.interaction.update(1.0 / 60.0)
		t += 1.0 / 60.0


# --- acceptance tests -------------------------------------------------------

func test_01_door() -> void:
	var s := new_sim()
	var door: Interactable = s.entities["cottage_door"]
	var gap := door.pos + Vector2(-0.15, 0)
	check(s.is_blocked(gap, WorldSim.PLAYER_RADIUS), "closed door blocks the doorway")
	s.player_pos = door.pos + Vector2(0.7, 0.0)
	walk(s, Vector2(-1, 0), 1.0)
	check(s.player_pos.x > door.pos.x - 0.1, "cannot walk through a closed door")
	check(cmd_use(s, "cottage_door").ok and door.open, "door opens in range")
	check(not s.is_blocked(gap, WorldSim.PLAYER_RADIUS), "open door clears the doorway")
	s.player_pos = door.pos + Vector2(0.7, 0.0)
	walk(s, Vector2(-1, 0), 1.0)
	check(s.player_pos.x < door.pos.x - 0.6, "walked through the open door (x=%.2f)" % s.player_pos.x)
	s.player_pos = door.pos + Vector2(-0.12, 0)
	var r := cmd_use(s, "cottage_door")
	check(not r.ok and r.code == "obstructed" and door.open, "cannot close door on yourself")
	s.player_pos = door.pos + Vector2(-0.8, 0)
	check(cmd_use(s, "cottage_door").ok and not door.open, "door closes from inside")
	check(s.is_blocked(gap, WorldSim.PLAYER_RADIUS), "closed again -> blocks")
	walk(s, Vector2(1, 0), 1.0)
	check(s.player_pos.x < door.pos.x - 0.1, "inside player is held by the closed door")
	s.player_pos = door.pos + Vector2(4, 0)
	r = cmd_use(s, "cottage_door")
	check(not r.ok and r.code == "too_far" and not door.open, "door out of range fails, unchanged")
	_finished = true


func test_02_pickup() -> void:
	var s := new_sim()
	var sword := find(s, "iron_sword", "world")
	check(sword != 0, "sword starts on the ground")
	var pos: Vector2 = s.items.location(sword)["pos"]
	s.player_pos = pos + Vector2(3, 0)
	check(not cmd_use(s, "item:%d" % sword).ok, "cannot pick up from 3 tiles away")
	check(s.items.location(sword)["kind"] == "world", "still on ground after failed pickup")
	s.player_pos = pos + Vector2(0.8, 0)
	var r := cmd_use(s, "item:%d" % sword)
	check(r.ok, "pickup succeeds in range")
	var loc := s.items.location(sword)
	check(loc["kind"] == "container" and loc["container"] == "player.backpack", "sword in backpack")
	check(not s.items.world_items().has(sword), "sword removed from world")
	check(invariants_ok(s), "invariants")
	_finished = true


func test_03_equip() -> void:
	var s := new_sim()
	var sword := find(s, "iron_sword", "world")
	s.player_pos = s.items.location(sword)["pos"] + Vector2(0.5, 0)
	cmd_use(s, "item:%d" % sword)
	var r := s.interaction.submit(InteractionCommand.use_item(P, sword, s.items.location(sword)))
	check(r.ok, "equip via use_item")
	check(s.items.equipped(P, "main_hand") == sword, "main hand holds sword")
	check(s.items.containers["player.backpack"].used() == 0, "backpack no longer holds it")
	var ev_equip := false
	for e in r.events:
		ev_equip = ev_equip or e["type"] == "equipment_changed"
	check(ev_equip, "equipment_changed event for presentation")
	r = cmd_move(s, sword, ItemLocation.container("player.backpack", 4))
	check(r.ok and s.items.location(sword)["slot"] == 4, "unequip into a chosen backpack slot")
	check(s.items.equipped(P, "main_hand") == 0, "main hand empty")
	check(invariants_ok(s), "invariants")
	_finished = true


func _open_chest(s: WorldSim) -> void:
	s.player_pos = s.entities["cottage_chest"].pos + Vector2(0.9, 0.3)
	check(cmd_use(s, "cottage_chest").ok, "chest opens in range")


func test_04_chest_transfer() -> void:
	var s := new_sim()
	var before := totals(s)
	_open_chest(s)
	check(s.entities["cottage_chest"].open, "chest visual state open")
	check(s.items.containers["cottage_chest.contents"].used() == 3, "chest has three items")
	var apples := find(s, "red_apple")
	var r := cmd_move(s, apples, ItemLocation.container("player.backpack"))
	check(r.ok, "chest -> backpack")
	check(s.items.location(apples)["container"] == "player.backpack", "apples in backpack")
	r = cmd_move(s, apples, ItemLocation.container("cottage_chest.contents", 6))
	check(r.ok and s.items.location(apples)["container"] == "cottage_chest.contents", "backpack -> chest")
	check(totals(s) == before, "no items created or lost")
	check(invariants_ok(s), "invariants")
	_finished = true


func test_05_invalid() -> void:
	var s := new_sim()
	var before := totals(s)
	s.player_pos = Vector2(17.5, 10.6)
	var r := cmd_use(s, "cottage_chest")
	check(not r.ok and r.code == "too_far" and not s.entities["cottage_chest"].open, "distant chest refuses to open")
	var apples := find(s, "red_apple")
	r = cmd_move(s, apples, ItemLocation.container("player.backpack"))
	check(not r.ok and r.code == "too_far", "cannot loot a distant chest: %s" % r.code)
	s.player_pos = s.entities["cottage_chest"].pos + Vector2(0.9, 0.3)
	r = cmd_move(s, apples, ItemLocation.container("player.backpack"))
	check(not r.ok and r.code == "not_open", "cannot loot an unopened chest")
	_open_chest(s)
	r = cmd_move(s, apples, ItemLocation.equipment(P, "main_hand"))
	check(not r.ok and r.code == "cannot_equip", "apples are not a weapon")
	var potion := find(s, "healing_potion")
	r = cmd_move(s, potion, ItemLocation.equipment(P, "off_hand"))
	check(not r.ok and r.code == "reserved", "off hand is reserved")
	r = cmd_move(s, potion, ItemLocation.world(s.player_pos + Vector2(5, 0)))
	check(not r.ok and r.code == "too_far", "cannot drop far away")
	r = cmd_move(s, potion, ItemLocation.world(s.entities["cottage_chest"].pos))
	check(not r.ok and r.code == "blocked", "cannot drop inside the chest's footprint")
	r = cmd_move(s, potion, ItemLocation.container("no_such_container"))
	check(not r.ok and r.code == "invalid_dest", "unknown container")
	r = cmd_move(s, 999999, ItemLocation.container("player.backpack"))
	check(not r.ok and r.code == "no_item", "unknown item")
	var ev_failed := false
	for e in r.events:
		ev_failed = ev_failed or e["type"] == "failed"
	check(ev_failed, "failure produces a feedback event")
	check(totals(s) == before and invariants_ok(s), "failed commands changed nothing")
	_finished = true


func test_06_rapid_duplicate() -> void:
	var s := new_sim()
	_open_chest(s)
	var before := totals(s)
	var coins := find(s, "gold_coins")
	var from := s.items.location(coins)
	var cmd := InteractionCommand.transfer(P, coins, from, ItemLocation.container("player.backpack"))
	var oks := 0
	for i in 25:
		if s.interaction.submit(cmd).ok:
			oks += 1
	check(oks == 1, "same transfer submitted 25x succeeds exactly once (%d)" % oks)
	# double drop to two different slots from the same stale snapshot
	var c2 := InteractionCommand.transfer(P, coins, s.items.location(coins), ItemLocation.container("cottage_chest.contents", 7))
	var c3 := InteractionCommand.transfer(P, coins, c2.args["from"], ItemLocation.world(s.player_pos + Vector2(0.6, 0.6)))
	var a := s.interaction.submit(c2).ok
	var b := s.interaction.submit(c3).ok
	check(a and not b, "second drop of the same pickup is rejected as stale")
	check(totals(s) == before and invariants_ok(s), "no duplication after rapid input")
	_finished = true


func test_06b_random_fuzz() -> void:
	var s := new_sim()
	_open_chest(s)
	var sword := find(s, "iron_sword")
	s.player_pos = s.entities["cottage_chest"].pos + Vector2(0.9, 0.3)
	s.items._vacate(sword)
	s.items._place(sword, ItemLocation.container("player.backpack", 0))
	var before := totals(s)
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	var dests := [
		func(): return ItemLocation.container("player.backpack", rng.randi_range(-1, 14)),
		func(): return ItemLocation.container("cottage_chest.contents", rng.randi_range(-1, 7)),
		func(): return ItemLocation.equipment(P, ["main_hand", "off_hand"][rng.randi() % 2]),
		func(): return ItemLocation.world(s.player_pos + Vector2(rng.randf_range(-2.5, 2.5), rng.randf_range(-2.5, 2.5))),
		func(): return ItemLocation.container("cottage_chest.contents", 99),
	]
	var ok_count := 0
	var bad := 0
	for i in 3000:
		var uids := s.items.items.keys()
		var uid: int = uids[rng.randi() % uids.size()]
		var from := s.items.location(uid)
		if rng.randf() < 0.15:  # stale snapshot
			from = ItemLocation.container("player.backpack", rng.randi_range(0, 14))
		var to: Dictionary = dests[rng.randi() % dests.size()].call()
		var qty := 0 if rng.randf() < 0.7 else rng.randi_range(0, 4)
		var r := s.interaction.submit(InteractionCommand.transfer(P, uid, from, to, qty))
		if r.ok:
			ok_count += 1
		if totals(s) != before or not s.items.check_invariants().is_empty():
			bad += 1
			if bad == 1:
				print("      first violation at step %d: %s" % [i, JSON.stringify(r.command.to_wire())])
	check(bad == 0, "3000 random transfers keep totals and invariants (%d ok)" % ok_count)
	check(ok_count > 300, "fuzz exercised many successful transfers (%d)" % ok_count)
	_finished = true


func test_stack_split_merge() -> void:
	var s := new_sim()
	_open_chest(s)
	var coins := find(s, "gold_coins")
	var r := cmd_move(s, coins, ItemLocation.container("player.backpack", 2), 10)
	check(r.ok, "split 10 coins into backpack")
	var moved := s.items.occupant(ItemLocation.container("player.backpack", 2))
	check(moved != coins and s.items.item(moved).quantity == 10 and s.items.item(coins).quantity == 15, "10 / 15 split")
	r = cmd_move(s, moved, ItemLocation.container("cottage_chest.contents", s.items.location(coins)["slot"]))
	check(r.ok and s.items.item(coins).quantity == 25 and s.items.item(moved) == null, "merge back into one stack of 25")
	r = cmd_move(s, find(s, "healing_potion"), ItemLocation.container("player.backpack"), 1)
	check(r.ok, "moving qty 1 of a single item is the whole item")
	check(invariants_ok(s), "invariants")
	_finished = true


func test_capacity() -> void:
	var s := new_sim()
	_open_chest(s)
	for i in 5:
		s.items.spawn("healing_potion", 1, ItemLocation.container("cottage_chest.contents"))
	check(s.items.containers["cottage_chest.contents"].first_empty() == -1, "chest filled to capacity 8")
	var p := s.items.spawn("healing_potion", 1, ItemLocation.container("player.backpack"))
	var r := cmd_move(s, p, ItemLocation.container("cottage_chest.contents"))
	check(not r.ok and r.code == "full", "full chest refuses")
	check(s.items.location(p)["container"] == "player.backpack", "item stays in backpack")
	var apples := find(s, "red_apple")
	var a2 := s.items.spawn("red_apple", 1, ItemLocation.container("player.backpack"))
	r = cmd_move(s, a2, ItemLocation.container("cottage_chest.contents"))
	check(r.ok and s.items.item(apples).quantity == 4, "stackable still merges into a full chest")
	_finished = true


func test_auto_close() -> void:
	var s := new_sim()
	_open_chest(s)
	s.player_pos = Vector2(17.5, 10.6)
	s.interaction.update(0.016)
	check(not s.interaction.is_open(P, "cottage_chest.contents"), "walking away closes the chest")
	check(not s.entities["cottage_chest"].open, "lid closes")
	_finished = true


func test_wire_roundtrip() -> void:
	var s := new_sim()
	var sword := find(s, "iron_sword", "world")
	s.player_pos = s.items.location(sword)["pos"] + Vector2(0.5, 0.2)
	var c := InteractionCommand.transfer(P, sword, s.items.location(sword), ItemLocation.container("player.backpack", 3))
	var wire := JSON.stringify(c.to_wire())
	var back := InteractionCommand.from_wire(JSON.parse_string(wire))
	check(s.interaction.submit(back).ok, "command survives JSON round trip: %s" % wire)
	check(s.items.location(sword)["slot"] == 3, "applied as sent")
	_finished = true


func test_definition_of_done() -> void:
	# walk to cottage -> open door -> open chest -> transfer -> pick up sword -> equip -> drop it back
	var s := new_sim()
	var before := totals(s)
	var door: Interactable = s.entities["cottage_door"]
	s.player_pos = door.pos + Vector2(1.2, 0)
	walk(s, Vector2(-1, 0), 0.25)
	check(cmd_use(s, "cottage_door").ok, "DoD: door opened")
	walk(s, Vector2(-1, 0), 0.9)
	walk(s, Vector2(-1, -1), 0.5)
	var chest: Interactable = s.entities["cottage_chest"]
	check(s.player_pos.distance_to(chest.pos) <= chest.use_range(), "DoD: reached chest (%.2f)" % s.player_pos.distance_to(chest.pos))
	check(cmd_use(s, "cottage_chest").ok, "DoD: chest opened")
	check(cmd_move(s, find(s, "red_apple"), ItemLocation.container("player.backpack")).ok, "DoD: apples transferred")
	# leave the way we came: line up with the doorway, then walk out east
	walk_to(s, Vector2(door.pos.x - 0.7, door.pos.y))
	walk_to(s, Vector2(door.pos.x + 1.5, door.pos.y))
	check(s.player_pos.x > door.pos.x + 1.0, "DoD: walked back out (%.2f, %.2f)" % [s.player_pos.x, s.player_pos.y])
	check(not s.interaction.is_open(P, "cottage_chest.contents"), "DoD: chest auto-closed on leaving")
	var sword := find(s, "iron_sword", "world")
	var spos: Vector2 = s.items.location(sword)["pos"]
	s.player_pos = spos + Vector2(0.7, -0.3)
	check(cmd_use(s, "item:%d" % sword).ok, "DoD: sword picked up")
	check(s.interaction.submit(InteractionCommand.use_item(P, sword, s.items.location(sword))).ok, "DoD: equipped")
	check(s.items.equipped(P, "main_hand") == sword, "DoD: main hand")
	check(cmd_move(s, sword, ItemLocation.world(s.player_pos + Vector2(0.6, 0.4))).ok, "DoD: dropped from hand to ground")
	check(s.items.location(sword)["kind"] == "world" and s.items.equipped(P, "main_hand") == 0, "DoD: sword back in world")
	check(totals(s) == before and invariants_ok(s), "DoD: conservation")

	_finished = true