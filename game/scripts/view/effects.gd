class_name Effects
## Small runtime effects anchored to forge-exported points.


static func _soft_dot(size: int, inner: Color, outer: Color) -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, inner)
	g.set_color(1, outer)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	t.width = size
	t.height = size
	return t


static func chimney_smoke(at: Vector2, tile_w: int) -> CPUParticles2D:
	var k := tile_w / 64.0
	var p := CPUParticles2D.new()
	p.position = at
	p.z_index = 5
	p.amount = 26
	p.lifetime = 3.2
	p.preprocess = 3.0
	p.texture = _soft_dot(int(14 * k), Color(0.92, 0.92, 0.92, 1.0), Color(0.85, 0.85, 0.85, 0.0))
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 2.0 * k
	p.direction = Vector2(0.25, -1)
	p.spread = 12.0
	p.gravity = Vector2(4.0 * k, -2.0 * k)
	p.initial_velocity_min = 7.0 * k
	p.initial_velocity_max = 11.0 * k
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.0
	var curve := Curve.new()
	curve.add_point(Vector2(0, 0.5))
	curve.add_point(Vector2(1, 2.2))
	p.scale_amount_curve = curve
	var ramp := Gradient.new()
	ramp.set_color(0, Color(0.75, 0.75, 0.75, 0.0))
	ramp.add_point(0.12, Color(0.8, 0.8, 0.8, 0.9))
	ramp.set_color(ramp.get_point_count() - 1, Color(0.8, 0.8, 0.82, 0.0))
	p.color_ramp = ramp
	return p


static func brazier_flame(at: Vector2, tile_w: int) -> Node2D:
	var k := tile_w / 64.0
	var root := Node2D.new()
	root.position = at
	root.z_index = 5
	var glow := Sprite2D.new()
	glow.texture = _soft_dot(int(28 * k), Color(1.0, 0.6, 0.2, 0.35), Color(1.0, 0.4, 0.1, 0.0))
	var add := CanvasItemMaterial.new()
	add.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	glow.material = add
	root.add_child(glow)
	var p := CPUParticles2D.new()
	p.amount = 14
	p.lifetime = 0.5
	p.preprocess = 1.0
	p.material = add
	p.texture = _soft_dot(int(5 * k), Color(1.0, 0.85, 0.4, 1.0), Color(1.0, 0.35, 0.05, 0.0))
	p.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 2.0 * k
	p.direction = Vector2(0, -1)
	p.spread = 15.0
	p.gravity = Vector2(0, -20.0 * k)
	p.initial_velocity_min = 6.0 * k
	p.initial_velocity_max = 12.0 * k
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1.0, 0.95, 0.6, 1.0))
	ramp.add_point(0.4, Color(1.0, 0.55, 0.15, 0.9))
	ramp.set_color(ramp.get_point_count() - 1, Color(0.8, 0.2, 0.05, 0.0))
	p.color_ramp = ramp
	root.add_child(p)
	return root
