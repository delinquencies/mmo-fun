class_name CombatFX
## Short-lived combat presentation: arrows, lightning bolts, hit sparks, target
## ring. Every effect frees itself; nothing accumulates (lifetimes <= 0.6 s).


class Arrow extends Node2D:
	var from := Vector2.ZERO
	var to := Vector2.ZERO
	var dur := 0.3
	var t := 0.0
	var hit := true

	func _process(dt: float) -> void:
		t += dt
		if t >= dur:
			var fx := CombatFX.spark(to, Color(0.95, 0.85, 0.6) if hit else Color(0.7, 0.65, 0.55), 6)
			get_parent().add_child(fx)
			queue_free()
			return
		queue_redraw()

	func _draw() -> void:
		var k := t / dur
		var p := from.lerp(to, k) + Vector2(0, -sin(k * PI) * from.distance_to(to) * 0.12)
		var dir := (to - from).normalized()
		draw_line(p - dir * 9.0, p, Color(0.35, 0.22, 0.1), 2.0)
		draw_line(p, p + dir * 2.0, Color(0.85, 0.85, 0.9), 2.0)
		draw_line(p - dir * 9.0, p - dir * 7.0, Color(0.85, 0.3, 0.2), 3.0)


class Bolt extends Node2D:
	var from := Vector2.ZERO
	var to := Vector2.ZERO
	var life := 0.35
	var t := 0.0
	var _pts := PackedVector2Array()
	var _rng := RandomNumberGenerator.new()

	func _ready() -> void:
		var m := CanvasItemMaterial.new()
		m.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
		material = m
		_regen()

	func _regen() -> void:
		_pts.clear()
		var n := maxi(5, int(from.distance_to(to) / 6.0))
		var nrm := (to - from).orthogonal().normalized()
		for k in n + 1:
			var f := float(k) / n
			var off := 0.0 if k == 0 or k == n else _rng.randf_range(-1.0, 1.0) * from.distance_to(to) * 0.12
			_pts.append((from.lerp(to, f) + nrm * off).round())

	func _process(dt: float) -> void:
		t += dt
		if t >= life:
			queue_free()
			return
		if int(t / 0.05) != int((t - dt) / 0.05):
			_regen()
		queue_redraw()

	func _draw() -> void:
		var a := 1.0 - t / life
		draw_polyline(_pts, Color(0.25, 0.45, 1.0, 0.45 * a), 4.0)
		draw_polyline(_pts, Color(0.75, 0.9, 1.0, 0.95 * a), 1.0)
		draw_circle(to, 7.0 * a, Color(0.35, 0.6, 1.0, 0.35 * a))


class Ring extends Node2D:
	var tile_w := 64
	var world := Vector2.ZERO
	var color := Color(1, 0.4, 0.25)
	var radius := 0.42

	func _process(_dt: float) -> void:
		queue_redraw()

	func _draw() -> void:
		var pulse := 0.75 + 0.25 * sin(Time.get_ticks_msec() / 160.0)
		var pts := PackedVector2Array()
		for k in 33:
			var a := TAU * k / 32.0
			pts.append(Iso.to_screen(world + Vector2(cos(a), sin(a)) * radius, tile_w))
		draw_polyline(pts, Color(color, 0.85 * pulse), 1.0)
		var inner := PackedVector2Array()
		for k in 33:
			var a := TAU * k / 32.0
			inner.append(Iso.to_screen(world + Vector2(cos(a), sin(a)) * radius * 0.82, tile_w))
		draw_polyline(inner, Color(color, 0.35 * pulse), 1.0)


static func spark(at: Vector2, color: Color, amount := 10) -> CPUParticles2D:
	var p := CPUParticles2D.new()
	p.position = at
	p.one_shot = true
	p.emitting = true
	p.amount = amount
	p.lifetime = 0.35
	p.explosiveness = 1.0
	p.direction = Vector2(0, -1)
	p.spread = 70.0
	p.gravity = Vector2(0, 60)
	p.initial_velocity_min = 25.0
	p.initial_velocity_max = 55.0
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.0
	p.color = color
	p.finished.connect(p.queue_free)
	return p
