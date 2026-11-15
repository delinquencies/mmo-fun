extends SceneTree
## Slice 005 combat tests on the authoritative simulation (offline, deterministic).
##   godot --headless --path game --script res://tests/combat_tests.gd

const P := "player"
var failures := 0
var checks := 0
var current := ""
var _finished := false
var events: Array = []


func _init() -> void:
	for t in ["c01_targeting", "c02_melee", "c03_ranged", "c04_lightning", "c05_npc_behaviour",
			"c06_death_and_loot", "c07_cooperative", "c08_player_death", "c09_skills", "c10_abuse"]:
		current = t
		var before := failures
		_finished = false
		call(t)
		if not _finished:
			failures += 1
			print("   x [%s] test did not run to completion" % t)
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
	s.load_map("res://data/maps/homestead.json")
	events.clear()
	s.interaction.event_emitted.connect(func(e): events.append(e))
	return s


func give(s: WorldSim, def_id: String, equip := true) -> int:
	var uid := s.items.spawn(def_id, 1, ItemLocation.container("player.backpack"))
	if equip:
		s.interaction.submit(InteractionCommand.make("equip", P, {"uid": uid, "from": s.items.location(uid)}))
	return uid


## Freeze a creature in place (no detection, no movement) for geometry tests.
func pin(s: WorldSim, id: String, at: Vector2) -> NpcState:
	var n: NpcState = s.npcs[id]
	n.def = n.def.duplicate(true)
	n.def["speed"] = 0.0
	n.def["walk_speed"] = 0.0
	n.def["detect"] = 0.0
	n.def["damage"] = [0, 0]
	n.def["interval"] = 999.0
	n.pos = at
	n.spawn = at
	n.goal = Vector2.INF
	return n


func run(s: WorldSim, seconds: float, dir := Vector2.ZERO) -> void:
	var t := 0.0
	while t < seconds:
		s.step_player(1.0 / 30.0, dir, false)
		s.step_combat(1.0 / 30.0)
		s.interaction.update(1.0 / 30.0)
		t += 1.0 / 30.0


func attack(s: WorldSim, target: String, actor := P) -> CommandResult:
	return s.interaction.submit(InteractionCommand.make("attack", actor, {"target": target}))


func ev(kind: String, src := "", tgt := "") -> Array:
	return events.filter(func(e): return e.get("type") == "combat" and e["kind"] == kind and (src == "" or e["source"] == src) and (tgt == "" or e["target"] == tgt))


# -------------------------------------------------------------------------------------

func c01_targeting() -> void:
	var s := new_sim()
	check(attack(s, "n:nonexistent").code == "invalid_target", "unknown target id rejected")
	check(attack(s, P).code == "invalid_target", "cannot target yourself")
	s.add_player("other", "Other", s.spawn_point + Vector2(1, 0))
	check(attack(s, "other").code == "not_hostile", "players are not attackable (no PvP in this slice)")
	var w := pin(s, "n:wolf_1", s.player_pos + Vector2(1.0, 0))
	var r := attack(s, "n:wolf_1")
	check(r.ok and s.players[P].combat.target == "n:wolf_1", "valid hostile target engaged")
	w.combat.dead = true
	check(attack(s, "n:wolf_1").code == "invalid_target", "dead creature cannot be targeted")
	_finished = true


func c02_melee() -> void:
	var s := new_sim()
	give(s, "iron_sword")
	var w := pin(s, "n:wolf_1", s.player_pos + Vector2(1.1, 0))
	w.combat.hp = 1000.0
	w.combat.hp_max = 1000.0
	attack(s, "n:wolf_1")
	run(s, 10.0)
	var swings := ev("swing", P)
	check(swings.size() >= 4 and swings.size() <= 6, "iron sword swings every 2.0 s (%d swings in 10 s)" % swings.size())
	var dmg := 0.0
	for e in ev("damage", P, "n:wolf_1"):
		dmg += float(e["amount"])
	check(dmg > 0 and is_equal_approx(1000.0 - w.combat.hp, dmg), "health change equals the server's damage events (%d)" % dmg)
	check(ev("damage", P).size() + ev("miss", P).size() == swings.size(), "every swing resolves exactly once (hit or miss)")
	w.pos = s.player_pos + Vector2(2.5, 0)
	var before := ev("swing", P).size()
	run(s, 4.0)
	check(ev("swing", P).size() == before, "no swing when the target is out of melee range")
	_finished = true


func c03_ranged() -> void:
	var s := new_sim()
	give(s, "hunting_bow")
	s.player_pos = Vector2(17.0, 9.0)
	var w := pin(s, "n:wolf_1", Vector2(17.0, 15.0))   # 6 tiles, open ground
	w.combat.hp = 1000.0
	w.combat.hp_max = 1000.0
	attack(s, "n:wolf_1")
	run(s, 6.0)
	check(ev("projectile", P).size() >= 2, "bow fires projectiles at 6 tiles (%d)" % ev("projectile", P).size())
	check(ev("damage", P).size() > 0 and float(ev("damage", P)[0].get("delay", 0)) > 0.2, "damage presented after projectile travel time")
	w.pos = Vector2(17.0, 19.5)   # 10.5 tiles
	var n0 := ev("swing", P).size()
	run(s, 5.0)
	check(ev("swing", P).size() == n0, "no shot beyond 8 tiles")
	s.player_pos = Vector2(16.4, 9.0)
	w.pos = Vector2(10.8, 9.0)    # behind the cottage walls (door closed)
	check(not s.line_clear(s.player_pos, w.pos), "the cottage blocks line of sight")
	n0 = ev("swing", P).size()
	run(s, 5.0)
	check(ev("swing", P).size() == n0, "no shot through walls")
	_finished = true


func c04_lightning() -> void:
	var s := new_sim()
	var uid := give(s, "lightning_sword")
	check(s.items.equipped(P, "main_hand") == uid, "Stormcaller equipped")
	var w := pin(s, "n:skeleton_1", s.player_pos + Vector2(1.1, 0))
	w.combat.hp = 1000.0
	w.combat.hp_max = 1000.0
	var me: Combatant = s.players[P].combat
	var mana0 := me.mn
	attack(s, "n:skeleton_1")
	run(s, 8.0)
	var elec := ev("damage", P).filter(func(e): return e["category"] == "electrical" and e["effects"].has("lightning"))
	check(elec.size() > 0, "electrical damage events from the server (%d)" % elec.size())
	check(events.any(func(e): return e.get("kind") == "status" and e["status"] == "shocked"), "shocked status applied")
	check(me.mn < mana0, "each discharge costs mana (%.0f -> %.0f)" % [mana0, me.mn])
	me.mn = 0.0
	s.combat.data["attributes"]["regen"]["mana"] = 0.0
	var e0 := ev("damage", P).filter(func(e): return e["category"] == "electrical" and e["source"] == P and not e["effects"].has("shocked")).size()
	run(s, 6.0)
	var e1 := ev("damage", P).filter(func(e): return e["category"] == "electrical" and e["source"] == P and not e["effects"].has("shocked")).size()
	check(e1 - e0 <= 1, "no discharge without mana")
	_finished = true


func c05_npc_behaviour() -> void:
	var s := new_sim()
	var wolf: NpcState = s.npcs["n:wolf_1"]
	var skel: NpcState = s.npcs["n:skeleton_1"]
	s.players[P].combat.hp = 10000.0
	s.players[P].combat.hp_max = 10000.0
	s.player_pos = wolf.spawn + Vector2(5.0, -3.0)
	run(s, 0.5)
	check(wolf.state == "chase" and wolf.combat.target == P, "wolf detects a player within 7 tiles and gives chase")
	var p0 := wolf.pos
	run(s, 0.4)
	var wolf_speed := wolf.pos.distance_to(p0) / 0.4
	run(s, 3.0)
	check(ev("swing", "n:wolf_1").size() >= 1, "wolf attacks in melee")
	var blocked := false
	for i in 60:
		run(s, 1.0 / 30.0)
		blocked = blocked or s.is_blocked(wolf.pos, 0.25)
	check(not blocked, "wolf never stands inside an obstacle")
	s.player_pos = skel.spawn + Vector2(3.5, -2.0)
	run(s, 0.5)
	check(skel.state == "chase", "skeleton guard engages at 5.5 tiles")
	p0 = skel.pos
	run(s, 0.4)
	var skel_speed := skel.pos.distance_to(p0) / 0.4
	check(wolf_speed > skel_speed * 1.6, "wolves are fast, skeletons deliberate (%.1f vs %.1f tiles/s)" % [wolf_speed, skel_speed])
	s.player_pos = Vector2(30, 30)
	run(s, 8.0)
	check(skel.pos.distance_to(skel.spawn) < 0.6 and skel.state == "idle", "skeleton returns to its post when the player leaves")
	var b: NpcState = s.npcs["n:bandit_1"]
	s.player_pos = b.pos + Vector2(3.0, -2.0)
	run(s, 1.5)
	check(b.state == "chase", "bandit engages")
	b.combat.hp = b.combat.hp_max * 0.2
	var d0 := b.pos.distance_to(s.player_pos)
	run(s, 1.2)
	check(events.any(func(e): return e.get("kind") == "retreat" and e["source"] == "n:bandit_1"), "bandit retreats when badly hurt")
	check(b.pos.distance_to(s.player_pos) > d0, "and actually moves away")
	_finished = true


func c06_death_and_loot() -> void:
	var s := new_sim()
	give(s, "iron_sword")
	var w := pin(s, "n:wolf_1", s.player_pos + Vector2(1.1, 0))
	w.combat.hp = 1.0
	var items0 := s.items.items.size()
	attack(s, "n:wolf_1")
	run(s, 6.0)
	check(ev("death", "", "n:wolf_1").size() == 1, "wolf dies exactly once")
	s.combat.apply_damage(P, "n:wolf_1", 50.0, "physical", [])
	s.combat._die("n:wolf_1", P)
	check(ev("death", "", "n:wolf_1").size() == 1, "further damage / death calls do nothing")
	var corpses := s.entities.values().filter(func(e): return e.kind == "corpse")
	check(corpses.size() == 1, "one set of remains")
	var corpse: Interactable = corpses[0]
	var cont: ContainerComponent = s.items.containers[corpse.container_id]
	check(cont.used() >= 1 and s.items.items.size() == items0 + cont.used(), "loot generated once (%d items)" % cont.used())
	check(attack(s, "n:wolf_1").code == "invalid_target", "remains are not a combat target")
	s.player_pos = corpse.pos + Vector2(0.6, 0.4)
	check(s.interaction.submit(InteractionCommand.use_entity(P, corpse.id)).ok, "open the remains")
	var pelt := cont.slots[0]
	var r1 := s.interaction.submit(InteractionCommand.transfer(P, pelt, ItemLocation.container(cont.id, 0), ItemLocation.container("player.backpack")))
	var r2 := s.interaction.submit(InteractionCommand.transfer(P, pelt, ItemLocation.container(cont.id, 0), ItemLocation.container("player.backpack")))
	check(r1.ok and not r2.ok and s.items.location(pelt)["container"] == "player.backpack", "loot taken once; repeat refused (%s)" % r2.code)
	check(s.items.check_invariants().is_empty(), "item invariants hold")
	run(s, float(s.combat.data["corpse"]["decay"]) + 1.0)
	check(not s.entities.has(corpse.id) and not s.items.containers.has(cont.id), "remains decay after %ds" % s.combat.data["corpse"]["decay"])
	check(s.items.location(pelt)["container"] == "player.backpack", "looted items are unaffected by decay")
	check(not w.combat.dead and w.pos == w.spawn, "the wolf respawned at its spawn point")
	_finished = true


func c07_cooperative() -> void:
	var s := new_sim()
	give(s, "iron_sword")
	s.add_player("ally", "Ally", s.player_pos + Vector2(0, 0.8))
	var u := s.items.spawn("lightning_sword", 1, ItemLocation.container("ally.backpack"))
	s.interaction.submit(InteractionCommand.make("equip", "ally", {"uid": u, "from": s.items.location(u)}))
	var w := pin(s, "n:wolf_1", s.player_pos + Vector2(1.0, 0.4))
	attack(s, "n:wolf_1")
	attack(s, "n:wolf_1", "ally")
	run(s, 30.0)
	check(ev("death", "", "n:wolf_1").size() == 1, "one death even with two attackers")
	var by_me := ev("damage", P, "n:wolf_1").size()
	var by_ally := ev("damage", "ally", "n:wolf_1").size()
	check(by_me > 0 and by_ally > 0, "both contributed damage (%d / %d hits)" % [by_me, by_ally])
	check(s.entities.values().filter(func(e): return e.kind == "corpse").size() == 1, "exactly one loot container")
	check(s.players[P].combat.target == "" and s.players["ally"].combat.target == "", "both stop attacking the dead wolf")
	_finished = true


func c08_player_death() -> void:
	var s := new_sim()
	var me: Combatant = s.players[P].combat
	var wolf: NpcState = s.npcs["n:wolf_1"]
	s.player_pos = wolf.spawn + Vector2(2.0, 0)
	me.hp = 4.0
	run(s, 12.0)
	check(me.dead, "the wolf defeats the player")
	check(wolf.combat.target == "" and wolf.state in ["return", "idle"], "the wolf disengages")
	var p0 := s.player_pos
	run(s, 1.0, Vector2(1, 0))
	check(s.player_pos == p0, "a defeated player cannot move")
	check(attack(s, "n:skeleton_1").code == "dead", "or attack")
	check(s.interaction.submit(InteractionCommand.use_entity(P, "cottage_door")).code == "dead", "or interact")
	check(s.interaction.submit(InteractionCommand.make("respawn", P, {})).ok, "respawn")
	var rp: Array = s.combat.data["player"]["respawn"]
	check(not me.dead and s.player_pos.distance_to(Vector2(rp[0], rp[1])) < 1.0 and is_equal_approx(me.hp, me.hp_max * 0.5), "back at the homestead shrine with half health")
	check(not s.interaction.submit(InteractionCommand.make("respawn", P, {})).ok, "respawn while alive is refused")
	_finished = true


func c09_skills() -> void:
	var s := new_sim()
	give(s, "iron_sword")
	var w := pin(s, "n:wolf_1", s.player_pos + Vector2(1.1, 0))
	w.combat.hp = 100000.0
	w.combat.hp_max = 100000.0
	var ps: PlayerState = s.players[P]
	var sw0 := float(ps.skills["swordsmanship"])
	attack(s, "n:wolf_1")
	run(s, 60.0)
	check(float(ps.skills["swordsmanship"]) > sw0, "swordsmanship rises with real swings (%.1f -> %.1f)" % [sw0, ps.skills["swordsmanship"]])
	check(events.filter(func(e): return e.get("type") == "skill").size() == int(round((ps.skills["swordsmanship"] - sw0) / 0.1)), "one skill event per 0.1 gain")
	ps.skills["swordsmanship"] = 100.0
	var n := events.size()
	run(s, 10.0)
	check(not events.slice(n).any(func(e): return e.get("type") == "skill" and e["skill"] == "swordsmanship"), "no gain past the cap")
	var d0 := float(ps.skills["defense"])
	var s2 := new_sim()
	var ps2: PlayerState = s2.players[P]
	ps2.combat.hp = 10000.0
	ps2.combat.hp_max = 10000.0
	s2.player_pos = s2.npcs["n:wolf_1"].spawn + Vector2(1.5, 0)
	run(s2, 60.0)
	check(float(ps2.skills["defense"]) > d0, "defense rises from being attacked (%.1f -> %.1f)" % [d0, ps2.skills["defense"]])
	_finished = true


func c10_abuse() -> void:
	var s := new_sim()
	give(s, "iron_sword")
	var w := pin(s, "n:wolf_1", s.player_pos + Vector2(1.1, 0))
	w.combat.hp = 1000.0
	w.combat.hp_max = 1000.0
	for i in 50:
		attack(s, "n:wolf_1")      # spam in a single tick
	run(s, 4.1)
	check(ev("swing", P).size() <= 3, "spamming attack does not speed up swings (%d in 4 s)" % ev("swing", P).size())
	var far := pin(s, "n:skeleton_1", s.player_pos + Vector2(20, 0))
	check(attack(s, "n:skeleton_1").code == "too_far", "engaging from far away refused")
	var r := s.interaction.submit(InteractionCommand.make("damage", P, {"target": "n:wolf_1"}))
	check(not r.ok and r.code == "unknown", "there is no client damage command")
	check(Protocol.validate_command({"type": "damage", "args": {"target": "n:wolf_1"}}) != "", "and the protocol rejects it")
	check(Protocol.validate_command({"type": "attack", "args": {"target": 5}}) != "", "non-string target ids rejected by the protocol")
	_finished = true
