class_name DropMarker
extends Node2D
## Ground target shown while dragging an item over the world: green where the
## drop would be accepted, red where the transfer service would refuse it.

var tile_w := 64
var world_pos := Vector2.ZERO
var valid := true


func show_at(p: Vector2, ok: bool) -> void:
	world_pos = p
	valid = ok
	visible = true
	queue_redraw()


func _draw() -> void:
	var c := Color(0.55, 0.95, 0.35, 0.9) if valid else Color(1.0, 0.3, 0.2, 0.9)
	var r := 0.22
	var pts := PackedVector2Array()
	for v in [Vector2(-r, -r), Vector2(r, -r), Vector2(r, r), Vector2(-r, r), Vector2(-r, -r)]:
		pts.append(Iso.to_screen(world_pos + v, tile_w))
	var fill := pts.duplicate()
	fill.remove_at(4)
	draw_colored_polygon(fill, Color(c, 0.18))
	draw_polyline(pts, c, 1.0)
