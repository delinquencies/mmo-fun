class_name PlayerState
extends RefCounted
## One character in the world. `pos`/`facing`/`moving` are simulation state
## (authoritative on the server). `render_*` are presentation values: equal to
## the sim offline, interpolated (remote) or predicted+smoothed (local) online.

var actor: String
var display_name: String
var pos := Vector2.ZERO
var facing := 0
var moving := false
var running := false
var anim_time := 0.0
var linkdead := false
var character_id := 0             # persistent characters only (0 = temporary session)
var appearance: Dictionary = {}   # e.g. {"cloth": "azure"}
var combat: Combatant              # Slice 005: health, stamina, mana, timing
var skills: Dictionary = {}        # skill id -> value (persisted)
var skills_dirty := false

var render_pos := Vector2.ZERO
var render_facing := 0
var render_moving := false
var render_running := false


func _init(p_actor: String, p_name: String, p_pos: Vector2) -> void:
	actor = p_actor
	display_name = p_name
	pos = p_pos
	render_pos = p_pos


func sync_render() -> void:
	render_pos = pos
	render_facing = facing
	render_moving = moving
	render_running = running
