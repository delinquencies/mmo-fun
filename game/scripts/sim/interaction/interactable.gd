class_name Interactable
extends RefCounted
## A world object the player can use (door, chest). Pure state + rules data;
## its sprite lives in the view layer. Definitions: game/data/interactables.json

var id: String
var def_id: String
var def: Dictionary
var kind: String
var pos: Vector2
var open := false
var container_id := ""


func display_name() -> String:
	return def.get("name", id)


func use_range() -> float:
	return float(def.get("use_range", 1.8))


func keep_open_range() -> float:
	return float(def.get("keep_open_range", use_range() + 0.8))


func _rects(key: String) -> Array[Rect2]:
	var out: Array[Rect2] = []
	for r in def.get(key, []):
		out.append(Rect2(pos.x + r[0], pos.y + r[1], r[2] - r[0], r[3] - r[1]))
	return out


## World-space collision for the current state.
func collision_rects() -> Array[Rect2]:
	if kind == "door":
		return _rects("open_collision" if open else "closed_collision")
	return _rects("collision")


func closed_rects() -> Array[Rect2]:
	return _rects("closed_collision")
