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

# player
var player_pos := Vector2.ZERO
var player_facing := 0
var player_moving := false
var player_running := false
var player_anim_time := 0.0

# sheep
var sheep: Array = []
var sheep_pen := Rect2()
var _rng := RandomNumberGenerator.new()


func load_map(path: String) -> void:
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
	var ps: Array = map_data["player_start"]
	player_pos = Vector2(ps[0], ps[1])
	player_facing = 0
	var pen: Array = map_data["sheep_pen"]
	sheep_pen = Rect2(pen[0], pen[1], pen[2] - pen[0], pen[3] - pen[1])
	_rng.seed = 1234
	for s in map_data["sheep"]:
		sheep.append({"pos": Vector2(s["x"], s["y"]), "facing": _rng.randi_range(0, 7),
			"state": "graze", "timer": _rng.randf_range(1.0, 4.0), "target": Vector2.ZERO, "t": 0.0})


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


func is_blocked(p: Vector2, radius: float) -> bool:
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
	player_running = run
	if move_dir.length_squared() > 0.0001:
		var d := move_dir.normalized()
		player_facing = facing_hint if facing_hint >= 0 else Iso.dir_index(d)
		var speed := RUN_SPEED if run else WALK_SPEED
		var np := try_move(player_pos, d * speed * dt, PLAYER_RADIUS)
		player_moving = np.distance_squared_to(player_pos) > 0.0
		player_pos = np
	else:
		player_moving = false
	player_anim_time += dt * ((RUN_SPEED / WALK_SPEED) if (player_moving and run) else 1.0)


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
