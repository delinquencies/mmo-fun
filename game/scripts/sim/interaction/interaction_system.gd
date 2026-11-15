class_name InteractionSystem
extends RefCounted
## Authority boundary for everything the player does to the world:
##   intent (InteractionCommand) -> validate -> mutate state -> events.
## Presentation listens to `event_emitted`; it never mutates sim state itself.
## Moving this class (plus ItemStore / ItemTransferService) server-side is the
## intended path to multiplayer: clients would send cmd.to_wire().

signal event_emitted(event: Dictionary)
signal command_resolved(result: CommandResult)

const ITEM_RANGE := 2.0          # pick up / drop on ground
const DROP_CLEARANCE := 0.12

var sim: WorldSim
var store: ItemStore
var transfers: ItemTransferService
var open_containers: Dictionary = {}   # actor -> Array[container id]
## Optional durable gate for permanent world objects: (entity id, state) -> "" or code.
var persist_world: Callable
## Optional veto checked before any item command (e.g. storage degraded) -> "" or code.
var item_guard: Callable
var log_commands := false


func _init(p_sim: WorldSim) -> void:
	sim = p_sim
	store = sim.items
	transfers = ItemTransferService.new(store, _access)


func backpack_id(actor: String) -> String:
	return "%s.backpack" % actor


func is_open(actor: String, cid: String) -> bool:
	return open_containers.get(actor, []).has(cid)


const COMMAND_TYPES: PackedStringArray = ["use", "transfer", "use_item", "close_container",
	"pick_up", "drop", "equip", "unequip", "set_door", "attack", "stop_attack", "respawn"]
const COMBAT_COMMANDS: PackedStringArray = ["attack", "stop_attack", "respawn"]


func submit(cmd: InteractionCommand) -> CommandResult:
	var r: CommandResult
	if not sim.players.has(cmd.actor):
		r = CommandResult.failure(cmd, "no_actor", "")
		command_resolved.emit(r)
		return r
	var ps: PlayerState = sim.players[cmd.actor]
	if COMBAT_COMMANDS.has(cmd.type):
		r = sim.combat.handle(cmd)
		for e in r.events:
			event_emitted.emit(e)
		if not r.ok and r.message != "":
			event_emitted.emit({"type": "failed", "actor": cmd.actor, "code": r.code, "message": r.message, "pos": sim.actor_pos(cmd.actor)})
		command_resolved.emit(r)
		return r
	if ps.combat and ps.combat.dead and cmd.type != "close_container":
		r = CommandResult.failure(cmd, "dead", "You cannot do that while defeated.")
		event_emitted.emit({"type": "failed", "actor": cmd.actor, "code": r.code, "message": r.message, "pos": sim.actor_pos(cmd.actor)})
		command_resolved.emit(r)
		return r
	match cmd.type:
		"use":
			r = _use(cmd)
		"transfer":
			r = _transfer(cmd, int(cmd.args.get("uid", 0)), cmd.args.get("from", {}), cmd.args.get("to", {}), int(cmd.args.get("qty", 0)))
		"use_item":
			r = _use_item(cmd)
		"close_container":
			r = _close_container(cmd.actor, cmd.args.get("container", ""), cmd)
		"pick_up":
			var uid := int(cmd.args.get("uid", 0))
			var loc := store.location(uid)
			if loc.get("kind", "") != "world":
				r = CommandResult.failure(cmd, "stale", ItemTransferService.MESSAGES["stale"])
			else:
				r = _transfer(cmd, uid, loc, ItemLocation.container(backpack_id(cmd.actor)), 0)
		"drop":
			var pos: Variant = cmd.args.get("pos")
			if pos is Array and pos.size() == 2:
				pos = Vector2(float(pos[0]), float(pos[1]))
			if not (pos is Vector2):
				r = CommandResult.failure(cmd, "invalid_dest", ItemTransferService.MESSAGES["invalid_dest"])
			else:
				r = _transfer(cmd, int(cmd.args.get("uid", 0)), cmd.args.get("from", {}), ItemLocation.world(pos), 0)
		"equip":
			var uid := int(cmd.args.get("uid", 0))
			var it := store.item(uid)
			var slot := store.def(it.def_id).equip_slot if it else ""
			if slot == "":
				r = CommandResult.failure(cmd, "cannot_equip", ItemTransferService.MESSAGES["cannot_equip"])
			else:
				r = _transfer(cmd, uid, cmd.args.get("from", {}), ItemLocation.equipment(cmd.actor, slot), 0)
		"unequip":
			var slot: String = str(cmd.args.get("slot", "main_hand"))
			var uid := store.equipped(cmd.actor, slot)
			if uid == 0:
				r = CommandResult.failure(cmd, "stale", "Nothing is equipped there.")
			else:
				r = _transfer(cmd, uid, ItemLocation.equipment(cmd.actor, slot), ItemLocation.container(backpack_id(cmd.actor)), 0)
		"set_door":
			var ent: Interactable = sim.entities.get(str(cmd.args.get("entity", "")))
			if ent == null or ent.kind != "door":
				r = CommandResult.failure(cmd, "no_target", "There is nothing there.")
			elif ent.open == bool(cmd.args.get("open", false)):
				r = CommandResult.failure(cmd, "no_change", "")
			else:
				r = _use(InteractionCommand.make("use", cmd.actor, {"entity": ent.id}))
				r.command = cmd
		_:
			r = CommandResult.failure(cmd, "unknown", "Unknown command.")
	if log_commands:
		print("[cmd %d] %s -> %s %s" % [cmd.seq, JSON.stringify(cmd.to_wire()), "OK" if r.ok else "FAIL", r.code])
	if not r.ok:
		r.events.append({"type": "failed", "actor": cmd.actor, "code": r.code, "message": r.message,
			"pos": sim.actor_pos(cmd.actor)})
	for e in r.events:
		event_emitted.emit(e)
	command_resolved.emit(r)
	return r


## Per-tick rules: containers close when their user walks away.
func update(_dt: float) -> void:
	for actor in open_containers.keys():
		for cid in open_containers[actor].duplicate():
			var c: ContainerComponent = store.containers.get(cid)
			var ent: Interactable = sim.entities.get(c.owner_entity) if c else null
			if ent and sim.actor_pos(actor).distance_to(ent.pos) > ent.keep_open_range():
				var r := _close_container(actor, cid, null)
				for e in r.events:
					event_emitted.emit(e)


## Close every container an actor has open (disconnects, removal).
func close_all_for(actor: String) -> void:
	for cid in open_containers.get(actor, []).duplicate():
		var r := _close_container(actor, cid, null)
		for e in r.events:
			event_emitted.emit(e)


# --- access rules shared by every transfer ---------------------------------

func _access(actor: String, loc: Dictionary, purpose: String) -> String:
	match loc.get("kind", ""):
		"container":
			var c: ContainerComponent = store.containers.get(loc.get("container", ""))
			if c == null:
				return "invalid_dest"
			if c.owner_entity == actor:
				return ""
			var ent: Interactable = sim.entities.get(c.owner_entity)
			if ent == null:
				return "not_yours"
			if sim.actor_pos(actor).distance_to(ent.pos) > ent.keep_open_range():
				return "too_far"
			if not is_open(actor, c.id):
				return "not_open"
			return ""
		"world":
			var p: Vector2 = loc.get("pos", Vector2.INF)
			if sim.actor_pos(actor).distance_to(p) > ITEM_RANGE:
				return "too_far"
			if purpose == "put" and sim.is_blocked(p, DROP_CLEARANCE, false):
				return "blocked"
			return ""
		"equipment":
			return "" if loc.get("owner", "") == actor else "not_yours"
	return "invalid_dest"


# --- command handlers ------------------------------------------------------

func _transfer(cmd: InteractionCommand, uid: int, from: Dictionary, to: Dictionary, qty: int) -> CommandResult:
	if item_guard.is_valid():
		var g: String = item_guard.call()
		if g != "":
			return CommandResult.failure(cmd, g, ItemTransferService.MESSAGES.get(g, g))
	var p := transfers.plan(cmd.actor, uid, from, to, qty)
	if not p["ok"]:
		return CommandResult.failure(cmd, p["code"], p["message"])
	var perr := transfers.persist_plan(p)
	if perr != "":
		return CommandResult.failure(cmd, perr, ItemTransferService.MESSAGES.get(perr, "That could not be done."))
	var events := transfers.commit(p)
	var d := store.def(p["def"])
	var snd := ""
	var tk: String = p["to"]["kind"]
	var fk: String = p["from"]["kind"]
	if tk == "equipment":
		snd = d.sound("equip", "equip")
	elif fk == "equipment":
		snd = d.sound("unequip", "unequip")
	elif fk == "world":
		snd = d.sound("pickup", "item_pickup")
	else:
		snd = d.sound("drop", "item_place")
	events.append({"type": "sound", "name": snd, "pos": sim.actor_pos(cmd.actor)})
	if tk == "equipment" or fk == "equipment":
		events.append({"type": "equipment_changed", "actor": cmd.actor})
	return CommandResult.success(cmd, events)


func _use(cmd: InteractionCommand) -> CommandResult:
	var eid: String = cmd.args.get("entity", "")
	if eid.begins_with("item:"):
		var uid := int(eid.substr(5))
		var loc := store.location(uid)
		if loc.get("kind", "") != "world":
			return CommandResult.failure(cmd, "stale", ItemTransferService.MESSAGES["stale"])
		return _transfer(cmd, uid, loc, ItemLocation.container(backpack_id(cmd.actor)), 0)
	var ent: Interactable = sim.entities.get(eid)
	if ent == null:
		return CommandResult.failure(cmd, "no_target", "There is nothing there.")
	if sim.actor_pos(cmd.actor).distance_to(ent.pos) > ent.use_range():
		return CommandResult.failure(cmd, "too_far", "That is too far away.")
	var events: Array = []
	match ent.kind:
		"door":
			if ent.open:
				for r in ent.closed_rects():
					for a in sim.players:
						if _circle_rect(sim.actor_pos(a), WorldSim.PLAYER_RADIUS, r):
							return CommandResult.failure(cmd, "obstructed", "Something is in the way.")
			if persist_world.is_valid() and ent.policy == "permanent":
				var werr: String = persist_world.call(ent.id, {"open": not ent.open})
				if werr != "":
					return CommandResult.failure(cmd, werr, ItemTransferService.MESSAGES.get(werr, "That could not be done."))
			ent.open = not ent.open
			events.append({"type": "door_changed", "id": ent.id, "open": ent.open})
			events.append({"type": "sound", "name": ent.def["sounds"]["open" if ent.open else "close"], "pos": ent.pos})
		"chest", "corpse":
			var already := is_open(cmd.actor, ent.container_id)
			if not already:
				open_containers.get_or_add(cmd.actor, []).append(ent.container_id)
				events.append({"type": "sound", "name": ent.def["sounds"]["open"], "pos": ent.pos})
			if not ent.open:
				ent.open = true
				events.append({"type": "chest_changed", "id": ent.id, "open": true})
			events.append({"type": "container_opened", "actor": cmd.actor, "container": ent.container_id, "entity": ent.id})
		_:
			return CommandResult.failure(cmd, "no_use", "You cannot use that.")
	return CommandResult.success(cmd, events)


func _use_item(cmd: InteractionCommand) -> CommandResult:
	var uid := int(cmd.args.get("uid", 0))
	var from: Dictionary = cmd.args.get("from", {})
	var it := store.item(uid)
	if it == null:
		return CommandResult.failure(cmd, "no_item", ItemTransferService.MESSAGES["no_item"])
	var d := store.def(it.def_id)
	match from.get("kind", ""):
		"world":
			return _transfer(cmd, uid, from, ItemLocation.container(backpack_id(cmd.actor)), 0)
		"equipment":
			return _transfer(cmd, uid, from, ItemLocation.container(backpack_id(cmd.actor)), 0)
		"container":
			if d.equip_slot != "":
				return _transfer(cmd, uid, from, ItemLocation.equipment(cmd.actor, d.equip_slot), 0)
			if from["container"] != backpack_id(cmd.actor):
				return _transfer(cmd, uid, from, ItemLocation.container(backpack_id(cmd.actor)), 0)
	return CommandResult.failure(cmd, "no_use", "You cannot use that yet.")


func _close_container(actor: String, cid: String, cmd: InteractionCommand) -> CommandResult:
	var events: Array = []
	if not is_open(actor, cid):
		return CommandResult.failure(cmd, "not_open", "")
	open_containers[actor].erase(cid)
	events.append({"type": "container_closed", "actor": actor, "container": cid})
	var c: ContainerComponent = store.containers.get(cid)
	var ent: Interactable = sim.entities.get(c.owner_entity) if c else null
	if ent and ent.kind == "chest":
		var anyone := false
		for a in open_containers:
			if open_containers[a].has(cid):
				anyone = true
		if not anyone and ent.open:
			ent.open = false
			events.append({"type": "chest_changed", "id": ent.id, "open": false})
			events.append({"type": "sound", "name": ent.def["sounds"]["close"], "pos": ent.pos})
	return CommandResult.success(cmd, events)


static func _circle_rect(p: Vector2, radius: float, r: Rect2) -> bool:
	var q := Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
	return p.distance_squared_to(q) < radius * radius
