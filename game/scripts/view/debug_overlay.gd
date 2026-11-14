class_name DebugOverlay
extends Node2D
## Toggleable calibration overlays: tile grid, collision shapes, sort anchors.

var view: WorldView
var show_grid := false
var show_collision := false


func _draw() -> void:
	if view == null:
		return
	var tw := view.aset.tile_w
	var sim := view.sim
	if show_grid:
		var c := Color(1, 1, 1, 0.18)
		for i in sim.size.x + 1:
			draw_line(Iso.to_screen(Vector2(i, 0), tw), Iso.to_screen(Vector2(i, sim.size.y), tw), c, 1.0)
		for j in sim.size.y + 1:
			draw_line(Iso.to_screen(Vector2(0, j), tw), Iso.to_screen(Vector2(sim.size.x, j), tw), c, 1.0)
		var pt := Vector2(floor(sim.player_pos.x), floor(sim.player_pos.y))
		var d := PackedVector2Array([Iso.to_screen(pt, tw), Iso.to_screen(pt + Vector2(1, 0), tw),
			Iso.to_screen(pt + Vector2(1, 1), tw), Iso.to_screen(pt + Vector2(0, 1), tw), Iso.to_screen(pt, tw)])
		draw_polyline(d, Color(1, 0.9, 0.3, 0.8), 1.0)
	if show_collision:
		var cc := Color(1, 0.25, 0.2, 0.8)
		for o in sim.obstacles:
			if o.has("circle"):
				var v: Vector3 = o["circle"]
				_iso_circle(Vector2(v.x, v.y), v.z, tw, cc)
			else:
				var r: Rect2 = o["rect"]
				var pts := PackedVector2Array([Iso.to_screen(r.position, tw), Iso.to_screen(Vector2(r.end.x, r.position.y), tw),
					Iso.to_screen(r.end, tw), Iso.to_screen(Vector2(r.position.x, r.end.y), tw), Iso.to_screen(r.position, tw)])
				draw_polyline(pts, cc, 1.0)
		_iso_circle(sim.player_pos, WorldSim.PLAYER_RADIUS, tw, Color(0.3, 1, 0.4, 0.9))
		# y-sort anchors
		for child in view.entities.get_children():
			if child is BuildingSprite:
				for sp in child.sort_points:
					draw_rect(Rect2(child.position + sp - Vector2(1, 1), Vector2(3, 3)), Color(0.2, 0.8, 1, 0.9))
			else:
				draw_rect(Rect2(child.position - Vector2(1, 1), Vector2(3, 3)), Color(1, 1, 0.2, 0.9))


func _iso_circle(c: Vector2, r: float, tw: int, col: Color) -> void:
	var pts := PackedVector2Array()
	for k in 25:
		var a := TAU * k / 24.0
		pts.append(Iso.to_screen(c + Vector2(cos(a), sin(a)) * r, tw))
	draw_polyline(pts, col, 1.0)
