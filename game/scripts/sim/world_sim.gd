class_name WorldSim
extends RefCounted
## Resolution-independent world state and rules, in world (tile) units.
##
## Views only *read* this. Keeping simulation separate from presentation lets
## two asset sets render the same world side by side, and is the shape a
## future authoritative server will need (the sim moves server-side; views stay).

const TERRAIN_GRASS := 0
const TERRAIN_DIRT := 1
const TERRAIN_WATER := 2

const PLAYER_RADIUS := 0.24
const WALK_SPEED := 3.2   # tiles / s
const RUN_SPEED := 5.6

var map_data: Dictionary
var size: Vector2i
var corners: Array[PackedByteArray] = []   # [row j][col i], (size+1)^2 vertices
var props: Array = []                        # {type, pos: Vector2}
var obstacles: Array = []                    # {circle: Vector3(x,y,r)} | {rect: Rect2}
var prop_defs: Dictionary

# players (Slice 003: any number of actors). `local_actor` is the character
# this process controls / follows; the player_* properties alias it so
# single-player code and tests keep working unchanged.
var players: Dictionary = {}          # actor id -> PlayerState
var local_actor := "player"
var spawn_point := Vector2.ZERO

var player_pos: Vector2:
	get: return players[local_actor].pos if players.has(local_actor) else Vector2.ZERO
	set(v):
		if players.has(local_actor):
			players[local_actor].pos = v
var player_facing: int:
	get: return players[local_actor].facing if players.has(local_actor) else 0
	set(v):
		if players.has(local_actor):
			players[local_actor].facing = v
var player_moving: bool:
	get: return players[local_actor].moving if players.has(local_actor) else false
var player_running: bool:
	get: return players[local_actor].running if players.has(local_actor) else false
var player_anim_time: float:
	get: return players[local_actor].anim_time if players.has(local_actor) else 0.0

# interaction / items (Slice 002)
const PLAYER_ID := "player"
var items := ItemStore.new()
var entities: Dictionary = {}               # entity id -> Interactable
var interaction: InteractionSystem
var interactable_defs: Dictionary

# sheep
var sheep: Array = []
var sheep_pen := Rect2()
var _rng := RandomNumberGenerator.new()


## spawn_items = false for network replicas: item state comes only from the server.
func load_map(path: String, spawn_local := true, spawn_items := true) -> void:
	map_data = JSON.parse_string(FileAccess.get_file_as_string(path))
	prop_defs = JSON.parse_string(FileAccess.get_file_as_string("res://data/props.json"))
	size = Vector2i(int(map_data["size"][0]), int(map_data["size"][1]))
	var legend := {"g": TERRAIN_GRASS, "d": TERRAIN_DIRT, "w": TERRAIN_WATER}
	for row in map_data["terrain_rows"]:
		var r := PackedByteArray()
		for ch in String(row):
			r.append(legend.get(ch, TERRAIN_GRASS))
		corners.append(r)
	for p in map_data["props"]:
		var pos := Vector2(float(p["x"]), float(p["y"]))
		props.append({"type": p["type"], "pos": pos})
		var def: Dictionary = prop_defs.get(p["type"], {})
		for shape in def.get("collision", []):
			if shape.has("circle"):
				var c: Array = shape["circle"]
				obstacles.append({"circle": Vector3(pos.x + c[0], pos.y + c[1], c[2])})
			elif shape.has("rect"):
				var r: Array = shape["rect"]
				obstacles.append({"rect": Rect2(pos.x + r[0], pos.y + r[1], r[2] - r[0], r[3] - r[1])})
	_load_interactables(spawn_items)
	var ps: Array = map_data["player_start"]
	spawn_point = Vector2(ps[0], ps[1])
	if spawn_local:
		add_player(PLAYER_ID, "Adventurer", spawn_point)
	var pen: Array = map_data["sheep_pen"]
	sheep_pen = Rect2(pen[0], pen[1], pen[2] - pen[0], pen[3] - pen[1])
	_rng.seed = 1234
	for s in map_data["sheep"]:
		sheep.append({"pos": Vector2(s["x"], s["y"]), "facing": _rng.randi_range(0, 7),
			"state": "graze", "timer": _rng.randf_range(1.0, 4.0), "target": Vector2.ZERO, "t": 0.0})


func _load_interactables(spawn_items := true) -> void:
	items.load_definitions("res://data/items.json")
	interactable_defs = JSON.parse_string(FileAccess.get_file_as_string("res://data/interactables.json"))
	for e in map_data.get("entities", []):
		var ent := Interactable.new()
		ent.id = e["id"]
		ent.def_id = e["def"]
		ent.def = interactable_defs[ent.def_id]
		ent.kind = ent.def["kind"]
		ent.pos = Vector2(e["x"], e["y"])
		if ent.kind == "chest":
			ent.container_id = ent.id + ".contents"
			items.add_container(ContainerComponent.new(ent.container_id, ent.display_name(), ent.id,
				int(ent.def.get("capacity", 8)), int(ent.def.get("columns", 4))))
			for c in (e.get("contents", []) if spawn_items else []):
				items.spawn(c[0], int(c[1]), ItemLocation.container(ent.container_id))
		entities[ent.id] = ent
	for g in (map_data.get("ground_items", []) if spawn_items else []):
		items.spawn(g["def"], int(g.get("qty", 1)), ItemLocation.world(Vector2(g["x"], g["y"])))
	interaction = InteractionSystem.new(self)


## Create a character with its backpack and equipment.
func add_player(actor: String, display_name: String, pos: Vector2) -> PlayerState:
	var ps := PlayerState.new(actor, display_name, pos)
	players[actor] = ps
	if not items.containers.has("%s.backpack" % actor):
		items.add_container(ContainerComponent.new("%s.backpack" % actor, "Backpack", actor, 15, 5))
	if not items.equipment.has(actor):
		items.add_equipment(EquipmentComponent.new(actor))
	return ps


## Remove a character. Anything it carried is placed on the ground at its feet
## so no item is ever lost with a session (temporary sessions own nothing
## permanently until persistence exists).
func remove_player(actor: String) -> Array[int]:
	var dropped: Array[int] = []
	var ps: PlayerState = players.get(actor)
	if ps == null:
		return dropped
	var spots := 0
	for uid in items.items.keys():
		var loc := items.location(uid)
		var mine: bool = (loc.get("kind") == "container" and loc["container"] == "%s.backpack" % actor) \
			or (loc.get("kind") == "equipment" and loc["owner"] == actor)
		if mine:
			var a := spots * 2.4
			var r := 0.25 + 0.12 * spots
			items._vacate(uid)
			items._place(uid, ItemLocation.world(_free_drop_spot(ps.pos + Vector2(cos(a), sin(a)) * r)))
			dropped.append(uid)
			spots += 1
	items.containers.erase("%s.backpack" % actor)
	items.equipment.erase(actor)
	if interaction:
		interaction.open_containers.erase(actor)
	players.erase(actor)
	if not dropped.is_empty():
		items.revision += 1
		items.changed.emit()
	return dropped


func _free_drop_spot(p: Vector2) -> Vector2:
	if not is_blocked(p, 0.1):
		return p
	for k in 16:
		var q := p + Vector2(cos(k * 0.8), sin(k * 0.8)) * (0.3 + 0.1 * k)
		if not is_blocked(q, 0.1):
			return q
	return p


func actor_pos(actor: String) -> Vector2:
	var ps: PlayerState = players.get(actor)
	return ps.pos if ps else Vector2.INF


func corner(i: int, j: int) -> int:
	if j < 0 or j >= corners.size() or i < 0 or i >= corners[j].size():
		return TERRAIN_GRASS
	return corners[j][i]


## Bilinear water coverage at a world point (0..1).
func water_at(p: Vector2) -> float:
	var i := floori(p.x)
	var j := floori(p.y)
	var fx := p.x - i
	var fy := p.y - j
	var w00 := 1.0 if corner(i, j) == TERRAIN_WATER else 0.0
	var w10 := 1.0 if corner(i + 1, j) == TERRAIN_WATER else 0.0
	var w01 := 1.0 if corner(i, j + 1) == TERRAIN_WATER else 0.0
	var w11 := 1.0 if corner(i + 1, j + 1) == TERRAIN_WATER else 0.0
	return lerpf(lerpf(w00, w10, fx), lerpf(w01, w11, fx), fy)


func is_blocked(p: Vector2, radius: float, _include_actors := true) -> bool:
	if p.x < radius or p.y < radius or p.x > size.x - radius or p.y > size.y - radius:
		return true
	if water_at(p) > 0.45:
		return true
	for o in obstacles:
		if o.has("circle"):
			var c: Vector3 = o["circle"]
			if p.distance_squared_to(Vector2(c.x, c.y)) < (c.z + radius) * (c.z + radius):
				return true
		else:
			var r: Rect2 = o["rect"]
			var q := Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
			if p.distance_squared_to(q) < radius * radius:
				return true
	for id in entities:
		for r in (entities[id] as Interactable).collision_rects():
			var q2 := Vector2(clampf(p.x, r.position.x, r.end.x), clampf(p.y, r.position.y, r.end.y))
			if p.distance_squared_to(q2) < radius * radius:
				return true
	return false


## Axis-separated slide movement.
func try_move(p: Vector2, delta: Vector2, radius: float) -> Vector2:
	if not is_blocked(p + delta, radius):
		return p + delta
	var nx := p + Vector2(delta.x, 0)
	if not is_blocked(nx, radius):
		return nx
	var ny := p + Vector2(0, delta.y)
	if not is_blocked(ny, radius):
		return ny
	return p


## move_dir: world-space direction (zero = stand still). facing_hint >= 0 forces a facing.
func step_player(dt: float, move_dir: Vector2, run: bool, facing_hint: int = -1) -> void:
	step_actor(local_actor, dt, move_dir, run, facing_hint)
	if players.has(local_actor):
		players[local_actor].sync_render()


## The single movement rule, shared by offline play, the server simulation and
## client-side prediction. Speed comes from the rules, never from the caller:
## move_dir only contributes a direction.
func step_actor(actor: String, dt: float, move_dir: Vector2, run: bool, facing_hint: int = -1) -> void:
	var ps: PlayerState = players.get(actor)
	if ps == null:
		return
	ps.running = run
	if move_dir.length_squared() > 0.0001:
		var d := move_dir.normalized()
		ps.facing = facing_hint if facing_hint >= 0 else Iso.dir_index(d)
		var speed := RUN_SPEED if run else WALK_SPEED
		var np := try_move(ps.pos, d * speed * dt, PLAYER_RADIUS)
		ps.moving = np.distance_squared_to(ps.pos) > 0.0
		ps.pos = np
	else:
		ps.moving = false
	ps.anim_time += dt * ((RUN_SPEED / WALK_SPEED) if (ps.moving and run) else 1.0)


func step_sheep(dt: float) -> void:
	for s in sheep:
		s["t"] += dt
		s["timer"] -= dt
		match s["state"]:
			"graze", "stand":
				if s["timer"] <= 0.0:
					if _rng.randf() < 0.6:
						s["state"] = "walk"
						s["target"] = Vector2(
							_rng.randf_range(sheep_pen.position.x, sheep_pen.end.x),
							_rng.randf_range(sheep_pen.position.y, sheep_pen.end.y))
					else:
						s["state"] = "graze" if s["state"] == "stand" else "stand"
						s["timer"] = _rng.randf_range(2.0, 6.0)
			"walk":
				var to: Vector2 = s["target"] - s["pos"]
				if to.length() < 0.1 or s["timer"] < -8.0:
					s["state"] = "graze"
					s["timer"] = _rng.randf_range(2.0, 7.0)
				else:
					var d := to.normalized()
					s["facing"] = Iso.dir_index(d)
					var np := try_move(s["pos"], d * 0.55 * dt, 0.3)
					if np == s["pos"]:
						s["timer"] = -9.0
					s["pos"] = np
