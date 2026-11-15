extends SceneTree
## Rough server-side cost of the combat simulation (headless, one core).
##   godot --headless --path game --script res://tests/bench_combat.gd

func bench(extra_wolves: int) -> Dictionary:
	var s := WorldSim.new()
	s.load_map("res://data/maps/homestead.json")
	var base: NpcState = s.npcs["n:wolf_1"]
	for i in extra_wolves:
		var n := NpcState.new()
		n.id = "n:bench_%d" % i
		n.archetype = "wolf"
		n.def = base.def
		n.spawn = base.spawn + Vector2((i % 6) * 0.9 - 2.5, (i / 6) * 0.9 - 2.0)
		n.pos = n.spawn
		n.combat = Combatant.new(n.id)
		n.combat.hp_max = 1e9
		n.combat.hp = 1e9
		s.npcs[n.id] = n
	s.players["player"].combat.hp_max = 1e9
	s.players["player"].combat.hp = 1e9
	s.player_pos = base.spawn + Vector2(1.5, 0)    # every creature active and fighting
	var ticks := 900
	var t0 := Time.get_ticks_usec()
	for i in ticks:
		s.step_player(1.0 / 30.0, Vector2.ZERO, false)
		s.step_combat(1.0 / 30.0)
	var us := float(Time.get_ticks_usec() - t0) / ticks
	return {"npcs": s.npcs.size(), "us_per_tick": us, "swings": s.combat.stats["swings"]}


func _init() -> void:
	var m0 := Performance.get_monitor(Performance.MEMORY_STATIC)
	for n in [0, 30]:
		var r := bench(n)
		print("npcs=%d  %.0f us per 30 Hz tick (%.1f%% of the 33 ms budget), %d swings in 30 s" % [r["npcs"], r["us_per_tick"], r["us_per_tick"] / 333.33, r["swings"]])
	print("static memory: %.1f MB" % (Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0))
	# bandwidth estimate: one STATE message with 3 creatures + 2 players
	var msg := Protocol.make(Protocol.STATE, {"tick": 1000, "time": 33.3, "ack": 990,
		"players": [["c1", 17.5, 10.6, 3, true, false, 100, false], ["c2", 18.5, 11.6, 5, false, false, 87, false]],
		"npcs": [["n:wolf_1", 8.5, 26.5, 2, true, 100, false], ["n:skeleton_1", 12.6, 33.2, 0, false, 100, false], ["n:bandit_1", 6.2, 33.4, 4, true, 60, false]]})
	var b := var_to_bytes(msg).size()
	print("state message: %d bytes -> %.1f KB/s per client at 12 Hz (before ENet overhead)" % [b, b * 12 / 1024.0])
	quit()
