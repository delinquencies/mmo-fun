class_name CombatSystem
extends RefCounted
## Server-authoritative combat (also runs offline). The only place that changes
## health, stamina, mana, death and skills.
##
##   attack request (command) -> validate actor/target -> engage
##   update(): when ready, in range, in sight and with stamina -> swing (windup)
##             -> resolve at windup end (hit/miss, damage, effects, skill gain)
##             -> events -> clients present animation / sound / numbers
##
## Damage is never computed from animation frames or client data. Events go out
## through InteractionSystem.event_emitted (the same pipe as every other change).

const HOSTILE_PREFIX := "n:"

var sim: WorldSim
var data: Dictionary
var rng := RandomNumberGenerator.new()
var time := 0.0
var seq := 0
var _think_acc := 0.0
var _regen_acc := 0.0
## Optional durable gates (persistent server): create / remove loot containers.
var persist_loot: Callable       # (corpse: Dictionary, items: Array) -> ""|code
var unpersist_loot: Callable     # (corpse id) -> ""|code
var corpses: Dictionary = {}     # entity id -> {until, npc}
var _corpse_n := 0
var stats := {"swings": 0, "hits": 0, "misses": 0, "kills": 0, "player_deaths": 0, "skill_gains": 0, "loot_items": 0}


func _init(p_sim: WorldSim) -> void:
	sim = p_sim
	data = JSON.parse_string(FileAccess.get_file_as_string("res://data/combat.json"))
	rng.seed = 5051


func _emit(e: Dictionary) -> void:
	seq += 1
	e["seq"] = seq
	sim.interaction.event_emitted.emit(e)


# --- entities ------------------------------------------------------------------

func new_player_combatant(actor: String) -> Combatant:
	var a: Dictionary = data["attributes"]
	var c := Combatant.new(actor)
	c.hp_max = a["hp_max"]
	c.hp = c.hp_max
	c.st_max = a["stamina_max"]
	c.st = c.st_max
	c.mn_max = a["mana_max"]
	c.mn = c.mn_max
	c.attack = a["attack"]
	c.defense = a["defense"]
	return c


func default_skills() -> Dictionary:
	var out := {}
	for k in data["skills"]:
		out[k] = float(data["skills"][k]["start"])
	return out


func combatant(id: String) -> Combatant:
	if id.begins_with(HOSTILE_PREFIX):
		var n: NpcState = sim.npcs.get(id)
		return n.combat if n else null
	var ps: PlayerState = sim.players.get(id)
	return ps.combat if ps else null


func pos_of(id: String) -> Vector2:
	if id.begins_with(HOSTILE_PREFIX):
		var n: NpcState = sim.npcs.get(id)
		return n.pos if n else Vector2.INF
	return sim.actor_pos(id)


func radius_of(id: String) -> float:
	if id.begins_with(HOSTILE_PREFIX):
		var n: NpcState = sim.npcs.get(id)
		return float(n.def.get("radius", 0.3)) if n else 0.3
	return WorldSim.PLAYER_RADIUS


func weapon_of(actor: String) -> Dictionary:
	var uid := sim.items.equipped(actor, "main_hand")
	var wid := "unarmed"
	if uid:
		var it := sim.items.item(uid)
		if it and data["weapons"].has(it.def_id):
			wid = it.def_id
	var w: Dictionary = data["weapons"][wid].duplicate()
	w["id"] = wid
	return w


# --- commands --------------------------------------------------------------------

func handle(cmd: InteractionCommand) -> CommandResult:
	var me := combatant(cmd.actor)
	if me == null:
		return CommandResult.failure(cmd, "no_actor", "")
	match cmd.type:
		"attack":
			if me.dead:
				return CommandResult.failure(cmd, "dead", "You cannot fight while defeated.")
			var tid := str(cmd.args.get("target", ""))
			var tc := combatant(tid)
			if tc == null or tid == cmd.actor:
				return CommandResult.failure(cmd, "invalid_target", "That is not a valid target.")
			if not tid.begins_with(HOSTILE_PREFIX):
				return CommandResult.failure(cmd, "not_hostile", "You cannot attack that.")
			if tc.dead:
				return CommandResult.failure(cmd, "invalid_target", "That is already dead.")
			if pos_of(cmd.actor).distance_to(pos_of(tid)) > float(weapon_of(cmd.actor)["range"]) + 12.0:
				return CommandResult.failure(cmd, "too_far", "That is too far away.")
			me.target = tid
			return CommandResult.success(cmd, [{"type": "combat", "kind": "engage", "source": cmd.actor, "target": tid}])
		"stop_attack":
			me.target = ""
			me.pending = {}
			return CommandResult.success(cmd, [])
		"respawn":
			if not me.dead:
				return CommandResult.failure(cmd, "not_dead", "")
			_respawn_player(cmd.actor)
			return CommandResult.success(cmd, [])
	return CommandResult.failure(cmd, "unknown", "")


# --- simulation ---------------------------------------------------------------------

func update(dt: float) -> void:
	time += dt
	_think_acc += dt
	var think := _think_acc >= float(data["ai"]["think_interval"])
	if think:
		_think_acc = 0.0
	for a in sim.players.keys():
		var ps: PlayerState = sim.players.get(a)
		if ps and ps.combat:
			_update_attacker(a, ps.combat)
			_update_statuses(a, ps.combat)
	for id in sim.npcs.keys():
		var n: NpcState = sim.npcs[id]
		if n.combat.dead:
			if time >= n.respawn_at:
				_respawn_npc(n)
			continue
		if not _active(n):
			continue
		if think:
			_think(n)
		_move(n, dt)
		_update_attacker(id, n.combat)
		_update_statuses(id, n.combat)
	_regen_acc += dt
	if _regen_acc >= 0.5:
		_regen(_regen_acc)
		_regen_acc = 0.0
	for cid in corpses.keys():
		if time >= corpses[cid]["until"]:
			remove_corpse(cid)


func _active(n: NpcState) -> bool:
	var r := float(data["ai"]["activation_radius"])
	for a in sim.players:
		if sim.players[a].pos.distance_to(n.pos) < r:
			return true
	return n.state != "idle" and n.state != "wander"


## Start a swing when everything is valid; resolve it when its windup ends.
func _update_attacker(id: String, c: Combatant) -> void:
	if c.dead:
		return
	if not c.pending.is_empty():
		if time >= c.pending["resolve_at"]:
			var p := c.pending
			c.pending = {}
			_resolve(id, c, p)
		return
	if c.target == "":
		return
	var tc := combatant(c.target)
	if tc == null or tc.dead:
		c.target = ""
		return
	if time < c.next_attack_at:
		return
	var w := weapon_of(id) if not id.begins_with(HOSTILE_PREFIX) else _npc_weapon(sim.npcs[id])
	var dist := pos_of(id).distance_to(pos_of(c.target)) - radius_of(c.target)
	if dist > float(w["range"]):
		return
	if w["kind"] == "ranged" and not sim.line_clear(pos_of(id), pos_of(c.target)):
		return
	if c.st < float(w.get("stamina", 0)):
		return
	c.st -= float(w.get("stamina", 0))
	var slow := 1.0 + (0.25 if c.has_status("shocked") else 0.0)
	c.next_attack_at = time + float(w["interval"]) * slow
	c.pending = {"resolve_at": time + float(w["windup"]), "target": c.target, "weapon": w}
	c.last_combat_at = time
	_face(id, pos_of(c.target))
	stats["swings"] += 1
	_emit({"type": "combat", "kind": "swing", "source": id, "target": c.target, "weapon": w["id"],
		"windup": w["windup"], "pos": pos_of(id)})


func _resolve(id: String, c: Combatant, p: Dictionary) -> void:
	var tid: String = p["target"]
	var tc := combatant(tid)
	var w: Dictionary = p["weapon"]
	if tc == null or tc.dead:
		return
	var dist := pos_of(id).distance_to(pos_of(tid)) - radius_of(tid)
	var reach := float(w["range"]) + 0.35       # small grace for movement during the windup
	if dist > reach or (w["kind"] == "ranged" and not sim.line_clear(pos_of(id), pos_of(tid))):
		_emit({"type": "combat", "kind": "miss", "source": id, "target": tid, "reason": "out_of_reach", "pos": pos_of(tid)})
		stats["misses"] += 1
		return
	var att_skill := _skill(id, str(w.get("skill", "")))
	var def_skill := _skill(tid, "defense")
	var chance := clampf(0.55 + (c.attack + att_skill * 0.3 - tc.defense - def_skill * 0.25) / 100.0, 0.15, 0.95)
	var hit := rng.randf() < chance
	var travel := 0.0
	if w["kind"] == "ranged":
		travel = pos_of(id).distance_to(pos_of(tid)) / float(w.get("projectile_speed", 14.0))
		_emit({"type": "combat", "kind": "projectile", "source": id, "target": tid, "travel": travel, "hit": hit, "pos": pos_of(id)})
	# skill gains only from swings the server itself resolved against living foes
	if not id.begins_with(HOSTILE_PREFIX) and str(w.get("skill", "")) != "" and tid.begins_with(HOSTILE_PREFIX):
		_try_gain(id, str(w["skill"]))
	if tid.begins_with("n:") == false and id.begins_with(HOSTILE_PREFIX):
		_try_gain(tid, "defense")
	if not hit:
		stats["misses"] += 1
		_emit({"type": "combat", "kind": "miss", "source": id, "target": tid, "delay": travel, "pos": pos_of(tid)})
		return
	stats["hits"] += 1
	var dmg := float(rng.randi_range(int(w["damage"][0]), int(w["damage"][1])))
	var mit: Dictionary = data["mitigation"]
	dmg = maxf(1.0, round(dmg * (1.0 + att_skill / 200.0) - tc.defense * float(mit["defense_factor"]) - def_skill * float(mit["defense_skill_factor"])))
	var effects := []
	var electric := 0.0
	if w.has("electric") and not id.begins_with(HOSTILE_PREFIX) and c.mn >= float(w["electric"]["mana"]):
		c.mn -= float(w["electric"]["mana"])
		electric = float(rng.randi_range(int(w["electric"]["damage"][0]), int(w["electric"]["damage"][1])))
		effects.append("lightning")
	apply_damage(id, tid, dmg, "physical", effects, travel)
	if electric > 0.0 and not tc.dead:
		apply_damage(id, tid, electric, "electrical", ["lightning"], travel)
		_add_status(tid, tc, str(w["electric"]["status"]), id)


## The single damage path for every source (weapons, creatures, status ticks).
func apply_damage(src: String, tid: String, amount: float, category: String, effects: Array, delay := 0.0) -> void:
	var tc := combatant(tid)
	if tc == null or tc.dead or time < tc.invulnerable_until:
		return
	tc.hp = maxf(0.0, tc.hp - amount)
	tc.last_combat_at = time
	_emit({"type": "combat", "kind": "damage", "source": src, "target": tid, "amount": amount, "category": category,
		"effects": effects, "hp": roundi(tc.hp), "hp_max": roundi(tc.hp_max), "delay": delay, "pos": pos_of(tid)})
	if tid.begins_with(HOSTILE_PREFIX):
		var n: NpcState = sim.npcs[tid]
		if n.combat.target == "" and not src.begins_with(HOSTILE_PREFIX):
			n.combat.target = src     # retaliate
			n.state = "chase"
	if tc.hp <= 0.0:
		_die(tid, src)


func _die(tid: String, killer: String) -> void:
	var tc := combatant(tid)
	if tc.dead:
		return          # death happens exactly once
	tc.dead = true
	tc.target = ""
	tc.pending = {}
	tc.statuses.clear()
	for a in sim.players:   # everyone attacking it stops
		var pc: Combatant = sim.players[a].combat
		if pc and pc.target == tid:
			pc.target = ""
			pc.pending = {}
	for nid in sim.npcs:
		var nc: Combatant = sim.npcs[nid].combat
		if nc.target == tid:
			nc.target = ""
			nc.pending = {}
	_emit({"type": "combat", "kind": "death", "source": killer, "target": tid, "pos": pos_of(tid)})
	if tid.begins_with(HOSTILE_PREFIX):
		var n: NpcState = sim.npcs[tid]
		n.state = "dead"
		n.moving = false
		n.respawn_at = time + float(n.def.get("respawn", 60))
		stats["kills"] += 1
		_spawn_corpse(n)
	else:
		stats["player_deaths"] += 1
		var ps: PlayerState = sim.players[tid]
		ps.moving = false
		sim.interaction.close_all_for(tid)


func _respawn_player(actor: String) -> void:
	var ps: PlayerState = sim.players[actor]
	var c := ps.combat
	var p: Array = data["player"]["respawn"]
	ps.pos = sim._free_drop_spot(Vector2(p[0], p[1]))
	ps.sync_render()
	c.dead = false
	c.hp = c.hp_max * float(data["player"]["respawn_hp_frac"])
	c.st = c.st_max * 0.5
	c.invulnerable_until = time + float(data["player"]["invulnerable_after_respawn"])
	_emit({"type": "combat", "kind": "respawn", "source": actor, "target": actor, "pos": ps.pos})
	_emit_vitals(actor)


func _respawn_npc(n: NpcState) -> void:
	n.combat.dead = false
	n.combat.hp = n.combat.hp_max
	n.combat.target = ""
	n.pos = n.spawn
	n.state = "idle"
	n.goal = Vector2.INF
	_emit({"type": "combat", "kind": "npc_respawn", "source": n.id, "target": n.id, "pos": n.pos})


# --- loot / corpses -----------------------------------------------------------------

func _spawn_corpse(n: NpcState) -> void:
	_corpse_n += 1
	var cid := "corpse_%s_%d_%d" % [n.id.substr(2), Time.get_unix_time_from_system(), _corpse_n]
	var cdef: Dictionary = data["corpse"]
	var ent := Interactable.new()
	ent.id = cid
	ent.def_id = "corpse"
	ent.def = {"kind": "corpse", "name": "Remains of %s" % n.display_name(), "use_range": 1.8, "keep_open_range": 2.6,
		"sounds": {"open": "loot_open", "close": "item_place"}, "creature": n.archetype, "facing": n.facing}
	ent.kind = "corpse"
	ent.policy = "temporary"
	ent.pos = n.pos
	ent.container_id = cid + ".contents"
	var cont := ContainerComponent.new(ent.container_id, ent.display_name(), cid, int(cdef["capacity"]), int(cdef["columns"]))
	sim.items.add_container(cont)
	sim.entities[cid] = ent
	var rolls := LootService.roll(data["loot_tables"], str(n.def.get("loot", "")), rng, sim.items.defs)
	var rows := []
	for i in rolls.size():
		rows.append({"uid": sim.items.reserve_uid(), "def": rolls[i][0], "qty": rolls[i][1],
			"loc": ItemLocation.to_wire(ItemLocation.container(cont.id, i)), "version": 1})
	var corpse := {"id": cid, "x": ent.pos.x, "y": ent.pos.y, "container": cont.id, "capacity": cont.capacity, "creature": n.archetype}
	var err := ""
	if persist_loot.is_valid():
		err = str(persist_loot.call(corpse, rows))
	if err == "":
		sim.items.load_rows(rows)
		stats["loot_items"] += rows.size()
	else:
		push_warning("loot for %s not created (%s); corpse is empty" % [cid, err])
	corpses[cid] = {"until": time + float(cdef["decay"]), "npc": n.id}
	_emit({"type": "entity_spawned", "id": cid, "kind": "corpse", "pos": ent.pos, "def": ent.def,
		"container": cont.id, "title": cont.title, "capacity": cont.capacity, "columns": cont.columns})


## Decay: the remains and anything still in them disappear (they never belonged
## to a player). Anyone looking inside has the container closed first.
func remove_corpse(cid: String) -> void:
	var ent: Interactable = sim.entities.get(cid)
	if ent == null:
		corpses.erase(cid)
		return
	if unpersist_loot.is_valid():
		var err := str(unpersist_loot.call(cid))
		if err != "":
			corpses[cid]["until"] = time + 30.0   # storage unavailable: try again later
			return
	for a in sim.interaction.open_containers.keys():
		if sim.interaction.is_open(a, ent.container_id):
			var r := sim.interaction._close_container(a, ent.container_id, null)
			for e in r.events:
				sim.interaction.event_emitted.emit(e)
	for uid in sim.items.items.keys():
		if sim.items.location(uid).get("container", "") == ent.container_id:
			sim.items._destroy(uid)
	sim.items.containers.erase(ent.container_id)
	sim.entities.erase(cid)
	corpses.erase(cid)
	sim.items.revision += 1
	sim.items.changed.emit()
	_emit({"type": "entity_removed", "id": cid})


# --- status effects ----------------------------------------------------------------

func _add_status(tid: String, tc: Combatant, sid: String, src: String) -> void:
	var sd: Dictionary = data["status_effects"].get(sid, {})
	if sd.is_empty():
		return
	for s in tc.statuses:
		if s["id"] == sid:
			s["until"] = time + float(sd["duration"])   # refresh, do not stack
			return
	tc.statuses.append({"id": sid, "until": time + float(sd["duration"]), "next_tick": time + float(sd["tick"]), "source": src})
	_emit({"type": "combat", "kind": "status", "source": src, "target": tid, "status": sid, "duration": sd["duration"], "pos": pos_of(tid)})


func _update_statuses(id: String, c: Combatant) -> void:
	for s in c.statuses.duplicate():
		var sd: Dictionary = data["status_effects"][s["id"]]
		if time >= float(s["next_tick"]) and not c.dead:
			s["next_tick"] = float(s["next_tick"]) + float(sd["tick"])
			apply_damage(s["source"], id, float(rng.randi_range(int(sd["damage"][0]), int(sd["damage"][1]))), sd["category"], [s["id"]])
		if time >= float(s["until"]):
			c.statuses.erase(s)


# --- resources, skills ----------------------------------------------------------------

func _regen(dt: float) -> void:
	var r: Dictionary = data["attributes"]["regen"]
	for a in sim.players:
		var c: Combatant = sim.players[a].combat
		if c == null or c.dead:
			continue
		var before := c.vitals()
		var mult := float(r["out_of_combat_mult"]) if time - c.last_combat_at > float(r["combat_window"]) else 1.0
		c.hp = minf(c.hp_max, c.hp + float(r["hp"]) * mult * dt)
		c.st = minf(c.st_max, c.st + float(r["stamina"]) * dt)
		c.mn = minf(c.mn_max, c.mn + float(r["mana"]) * mult * dt)
		if c.vitals() != before:
			_emit_vitals(a)
	for id in sim.npcs:
		var n: NpcState = sim.npcs[id]
		if not n.combat.dead and n.state in ["idle", "wander", "return"] and time - n.combat.last_combat_at > float(r["combat_window"]):
			n.combat.hp = minf(n.combat.hp_max, n.combat.hp + n.combat.hp_max * 0.05 * dt)


func _emit_vitals(actor: String) -> void:
	var ps: PlayerState = sim.players.get(actor)
	if ps:
		_emit({"type": "vitals", "actor": actor, "v": ps.combat.vitals(), "dead": ps.combat.dead})


func _skill(id: String, skill: String) -> float:
	if skill == "" or id.begins_with(HOSTILE_PREFIX):
		return 0.0
	return float(sim.players[id].skills.get(skill, 0.0)) if sim.players.has(id) else 0.0


## Use-based gain: the closer to the cap, the rarer. Only called from the
## server's own resolution of a real swing against a living hostile creature.
func _try_gain(actor: String, skill: String) -> void:
	var ps: PlayerState = sim.players.get(actor)
	var sd: Dictionary = data["skills"].get(skill, {})
	if ps == null or sd.is_empty():
		return
	var v := float(ps.skills.get(skill, sd["start"]))
	var cap := float(sd["cap"])
	if v >= cap:
		return
	if rng.randf() < float(sd["base_chance"]) * (1.0 - v / cap):
		ps.skills[skill] = snappedf(minf(cap, v + float(sd["gain"])), 0.1)
		ps.skills_dirty = true
		stats["skill_gains"] += 1
		_emit({"type": "skill", "actor": actor, "skill": skill, "value": ps.skills[skill], "name": sd["name"]})


# --- creature brains -------------------------------------------------------------------

func _npc_weapon(n: NpcState) -> Dictionary:
	return {"id": n.archetype, "kind": "melee", "damage": n.def["damage"], "interval": n.def["interval"],
		"windup": n.def["windup"], "range": n.def["range"], "stamina": 0, "skill": ""}


func _face(id: String, at: Vector2) -> void:
	if id.begins_with(HOSTILE_PREFIX):
		NpcAI.face(sim.npcs[id], at)
	elif sim.players.has(id) and at.distance_squared_to(sim.players[id].pos) > 0.0001:
		sim.players[id].facing = Iso.dir_index(at - sim.players[id].pos)


## Decide (10 Hz): per-archetype composition of the NpcAI components.
func _think(n: NpcState) -> void:
	var c := n.combat
	var tpos := pos_of(c.target) if c.target != "" else Vector2.INF
	if c.target != "" and (tpos == Vector2.INF or combatant(c.target) == null or combatant(c.target).dead):
		c.target = ""
	match n.state:
		"idle", "wander":
			var seen := NpcAI.detect(sim, n, float(n.def["detect"]))
			if seen != "":
				c.target = seen
				n.state = "chase"
				_emit({"type": "sound", "name": n.def["sounds"]["aggro"], "pos": n.pos})
				_emit({"type": "combat", "kind": "aggro", "source": n.id, "target": seen, "pos": n.pos})
				return
			if n.def["behavior"] == "guard":
				n.goal = n.spawn if n.pos.distance_to(n.spawn) > 0.3 else Vector2.INF
			elif n.def["behavior"] == "bandit" and not n.patrol.is_empty():
				var wp: Array = n.patrol[n.patrol_i]
				n.goal = Vector2(wp[0], wp[1])
				if n.pos.distance_to(n.goal) < 0.3:
					n.patrol_i = (n.patrol_i + 1) % n.patrol.size()
			elif n.goal == Vector2.INF or n.pos.distance_to(n.goal) < 0.2 or rng.randf() < 0.01:
				n.goal = NpcAI.wander_point(sim, n, rng) if rng.randf() < 0.3 else Vector2.INF
			n.running = false
		"chase":
			if c.target == "" or NpcAI.beyond_leash(n) \
					or n.pos.distance_to(tpos) > float(n.def["detect"]) * float(data["ai"]["lose_target_factor"]):
				_disengage(n)    # leashed, or the target got away
				return
			if n.def["behavior"] == "bandit" and c.hp / c.hp_max < float(n.def["retreat_hp"]):
				n.state = "retreat"
				n.state_until = time + float(n.def["retreat_time"])
				n.goal = NpcAI.flee_point(n, tpos)
				c.pending = {}
				_emit({"type": "combat", "kind": "retreat", "source": n.id, "target": c.target, "pos": n.pos})
				return
			var reach := float(n.def["range"]) + radius_of(c.target) - 0.15
			if n.def["behavior"] == "bandit" and time < n.state_until:
				pass     # strafing: keep the strafe goal
			elif n.pos.distance_to(tpos) > reach:
				n.goal = tpos
			else:
				n.goal = Vector2.INF
				NpcAI.face(n, tpos)
				if n.def["behavior"] == "bandit" and c.pending.is_empty() and time > c.next_attack_at - float(n.def["interval"]) + 0.5 and rng.randf() < 0.15:
					n.strafe_dir = -n.strafe_dir
					n.goal = NpcAI.strafe_point(n, tpos)
					n.state_until = time + float(n.def["strafe_time"])
			n.running = true
		"retreat":
			if time >= n.state_until:
				_disengage(n)
		"return":
			n.goal = n.spawn
			n.running = false
			if n.pos.distance_to(n.spawn) < 0.4:
				n.state = "idle"
				n.goal = Vector2.INF


func _disengage(n: NpcState) -> void:
	n.combat.target = ""
	n.combat.pending = {}
	n.state = "return"
	n.goal = n.spawn
	_emit({"type": "combat", "kind": "disengage", "source": n.id, "target": "", "pos": n.pos})


## Move (every tick) toward the current goal at the archetype's speed.
func _move(n: NpcState, dt: float) -> void:
	if n.goal == Vector2.INF or not n.combat.pending.is_empty():
		n.moving = false
		return
	var speed := float(n.def["speed"]) if n.running or n.state in ["chase", "retreat"] else float(n.def["walk_speed"])
	NpcAI.navigate(sim, n, n.goal, speed, dt, 0.1)
	n.anim_time += dt
	if n.stuck > 1.5:
		n.stuck = 0.0
		if n.state in ["return", "retreat"]:
			n.pos = n.spawn if n.state == "return" else n.pos   # unstick: snap home (documented)
		n.goal = NpcAI.wander_point(sim, n, rng)
