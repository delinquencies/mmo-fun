class_name SwordEnergy
extends Node2D
## Electric-blue blade energy drawn at runtime along the blade anchors exported
## per frame by the forge. Kept separate from the character art so it can be
## reused on other weapons and toggled independently.

var base := Vector2.ZERO
var tip := Vector2.ZERO
var enabled := true
var _arcs: Array = []
var _t := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	var m := CanvasItemMaterial.new()
	m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = m


func set_blade(b: Vector2, t: Vector2) -> void:
	if b != base or t != tip:
		base = b
		tip = t
		_regen()
		queue_redraw()


func _process(dt: float) -> void:
	_t += dt
	if _t > 0.06:
		_t = 0.0
		_regen()
		queue_redraw()


func _regen() -> void:
	_arcs.clear()
	var axis := tip - base
	var L := axis.length()
	if L < 1.0:
		return
	var n := axis.orthogonal().normalized()
	for a in 3:
		var pts := PackedVector2Array()
		var segs := maxi(4, int(L / 4.0))
		var amp := maxf(1.5, L * 0.09)
		for k in segs + 1:
			var f := float(k) / segs
			var off := 0.0 if (k == 0 or k == segs) else _rng.randf_range(-amp, amp)
			pts.append((base + axis * f + n * off).round())
		_arcs.append(pts)


func _draw() -> void:
	if not enabled or _arcs.is_empty():
		return
	var glow := Color(0.15, 0.3, 1.0, 0.35)
	draw_line(base, tip, glow, 4.0)
	draw_line(base, tip, Color(0.3, 0.55, 1.0, 0.5), 2.0)
	for i in _arcs.size():
		var c := Color(0.55, 0.8, 1.0, 0.9) if i == 0 else Color(0.25, 0.5, 1.0, 0.6)
		draw_polyline(_arcs[i], c, 1.0)
	draw_circle(tip, 1.5, Color(0.7, 0.9, 1.0, 0.8))
