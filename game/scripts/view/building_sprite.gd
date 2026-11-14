class_name BuildingSprite
extends Node2D
## Large footprint objects are sliced into vertical strips; each strip y-sorts
## at the point where its column meets the footprint's front edges. This keeps
## correct occlusion when actors walk along any side of a building while still
## using Godot's built-in y-sort.

const STRIP_FRACTION := 0.5   # strip width = tile_w * STRIP_FRACTION

var sort_points: PackedVector2Array = []


func setup(tex: Texture2D, pivot: Vector2, footprint: Rect2, tile_w: int) -> void:
	y_sort_enabled = true
	var fw := footprint.size.x
	var fd := footprint.size.y
	var strip := int(tile_w * STRIP_FRACTION)
	var width := tex.get_width()
	var c0 := 0
	while c0 < width:
		var c1 := mini(c0 + strip, width)
		var sx := (c0 + c1) * 0.5 - pivot.x
		var sy: float
		# front edges: y = fd (x in 0..fw) and x = fw (y in 0..fd), local to footprint origin
		if sx <= (fw - fd) * tile_w * 0.5:
			var x_e := clampf(2.0 * sx / tile_w + fd, 0.0, fw)
			sy = (x_e + fd) * tile_w * 0.25
		else:
			var y_e := clampf(fw - 2.0 * sx / tile_w, 0.0, fd)
			sy = (fw + y_e) * tile_w * 0.25
		var node := Sprite2D.new()
		node.texture = tex
		node.centered = false
		node.region_enabled = true
		node.region_rect = Rect2(c0, 0, c1 - c0, tex.get_height())
		node.position = Vector2(sx, sy)
		node.offset = Vector2(c0 - pivot.x - sx, -pivot.y - sy)
		add_child(node)
		sort_points.append(Vector2(sx, sy))
		c0 = c1
