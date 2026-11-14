extends Control
## Isometric visual laboratory: owns the simulation, one or two WorldViews
## (resolution comparison), input, zoom and the HUD.

const SETS: PackedStringArray = ["t64", "t96"]
const ZOOMS: PackedFloat32Array = [0.5, 1.0, 1.5, 2.0, 3.0, 4.0]
const MAP := "res://data/maps/homestead.json"

var sim := WorldSim.new()
var asset_sets: Dictionary = {}
var active := 0
var compare := false
var matched_scale := false
var zoom_i := 3
var show_grid := false
var show_collision := false
var show_energy := true
var show_help := true

var views: Array[WorldView] = []
var cells: Array[Control] = []
var row := HBoxContainer.new()
var hud := Label.new()
var help := Label.new()
var hud_panel := PanelContainer.new()
var help_panel := PanelContainer.new()

# command-line automation (screenshots for review)
var cli: Dictionary = {}
var frame_count := 0
var cli_walk_dir := Vector2.ZERO


func _ready() -> void:
	_parse_cli()
	for id in SETS:
		var s := AssetSet.load_set(id)
		if s:
			asset_sets[id] = s
	sim.load_map(MAP)
	if cli.has("set"):
		active = maxi(0, SETS.find(cli["set"]))
	if cli.has("zoom"):
		zoom_i = maxi(0, Array(ZOOMS).find(float(cli["zoom"])))
	compare = cli.has("compare")
	matched_scale = cli.has("matched")
	show_grid = cli.has("grid")
	show_collision = cli.has("collision")
	show_help = not cli.has("nohelp")
	if cli.has("pos"):
		var p: PackedStringArray = String(cli["pos"]).split(",")
		sim.player_pos = Vector2(float(p[0]), float(p[1]))
	if cli.has("face"):
		sim.player_facing = int(cli["face"])
	if cli.has("walk"):
		cli_walk_dir = Iso.dir_vector(int(cli["walk"]))

	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 2)
	add_child(row)
	_build_hud()
	_rebuild_views()


func _parse_cli() -> void:
	for a in OS.get_cmdline_user_args():
		var s := String(a).trim_prefix("--")
		var kv := s.split("=", true, 1)
		cli[kv[0]] = kv[1] if kv.size() > 1 else true


func _style(panel: PanelContainer) -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.06, 0.05, 0.04, 0.78)
	sb.border_color = Color(0.45, 0.36, 0.22, 0.9)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(8)
	panel.add_theme_stylebox_override("panel", sb)


func _build_hud() -> void:
	for pair in [[hud_panel, hud], [help_panel, help]]:
		var panel: PanelContainer = pair[0]
		var lab: Label = pair[1]
		_style(panel)
		lab.add_theme_font_size_override("font_size", 14)
		lab.add_theme_color_override("font_color", Color(0.93, 0.89, 0.78))
		panel.add_child(lab)
		add_child(panel)
	hud_panel.position = Vector2(10, 10)
	help.text = "\n".join([
		"WASD / Arrows  move      Shift  run      Right mouse (hold)  walk to cursor",
		"Tab  switch 64 / 96 set      C  side-by-side compare      M  matched world scale",
		"Mouse wheel / + -  zoom      G  tile grid      K  collision + sort anchors",
		"E  sword energy      F5  hot-reload forged assets      F12  screenshot      H  hide help",
	])
	help_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)


func _rebuild_views() -> void:
	for c in cells:
		c.queue_free()
	cells.clear()
	views.clear()
	var ids: Array = SETS if compare else [SETS[active]]
	for id in ids:
		if not asset_sets.has(id):
			continue
		var cell := Control.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
		cell.clip_contents = true
		var svc := SubViewportContainer.new()
		svc.stretch = true
		svc.set_anchors_preset(Control.PRESET_FULL_RECT)
		var vp := SubViewport.new()
		vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
		vp.snap_2d_transforms_to_pixel = true
		svc.add_child(vp)
		cell.add_child(svc)
		var view := WorldView.new()
		view.setup(sim, asset_sets[id])
		vp.add_child(view)
		var tag := Label.new()
		tag.text = asset_sets[id].label()
		tag.add_theme_font_size_override("font_size", 13)
		tag.add_theme_color_override("font_color", Color(1, 0.92, 0.7))
		tag.add_theme_color_override("font_outline_color", Color.BLACK)
		tag.add_theme_constant_override("outline_size", 4)
		tag.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		tag.position = Vector2(-10, 8)
		tag.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		cell.add_child(tag)
		row.add_child(cell)
		cells.append(cell)
		views.append(view)
	_apply_view_settings()


func _apply_view_settings() -> void:
	for v in views:
		var z := ZOOMS[zoom_i]
		if matched_scale and v.aset.tile_w != 64:
			z *= 64.0 / v.aset.tile_w
		v.camera.zoom = Vector2(z, z)
		v.overlay.show_grid = show_grid
		v.overlay.show_collision = show_collision
		v.overlay.visible = show_grid or show_collision
		v.show_energy = show_energy
	help_panel.visible = show_help


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(-1)
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	match event.physical_keycode:
		KEY_TAB:
			active = (active + 1) % SETS.size()
			_rebuild_views()
		KEY_1:
			active = 0
			_rebuild_views()
		KEY_2:
			active = 1
			_rebuild_views()
		KEY_C:
			compare = not compare
			_rebuild_views()
		KEY_M:
			matched_scale = not matched_scale
			_apply_view_settings()
		KEY_EQUAL, KEY_KP_ADD:
			_zoom(1)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_zoom(-1)
		KEY_G:
			show_grid = not show_grid
			_apply_view_settings()
		KEY_K:
			show_collision = not show_collision
			_apply_view_settings()
		KEY_E:
			show_energy = not show_energy
			_apply_view_settings()
		KEY_H, KEY_F1:
			show_help = not show_help
			_apply_view_settings()
		KEY_F5:
			for id in SETS:
				asset_sets[id] = AssetSet.load_set(id)
			_rebuild_views()
		KEY_F12:
			_screenshot("user://screenshot_%d.png" % Time.get_unix_time_from_system())


func _zoom(d: int) -> void:
	zoom_i = clampi(zoom_i + d, 0, ZOOMS.size() - 1)
	_apply_view_settings()


func _key_dir() -> Vector2:
	# Screen-intuitive keys mapped to world directions; diagonals follow tile axes.
	var d := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP):
		d += Vector2(-1, -1)
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN):
		d += Vector2(1, 1)
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		d += Vector2(-1, 1)
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		d += Vector2(1, -1)
	return d


func _mouse_world_dir() -> Vector2:
	for k in cells.size():
		var cell := cells[k]
		var local := cell.get_local_mouse_position()
		if Rect2(Vector2.ZERO, cell.size).has_point(local):
			var vp: SubViewport = cell.get_child(0).get_child(0)
			var screen := vp.get_canvas_transform().affine_inverse() * local
			var target := Iso.to_world(screen, views[k].aset.tile_w)
			var d := target - sim.player_pos
			return d if d.length() > 0.15 else Vector2.ZERO
	return Vector2.ZERO


func _process(dt: float) -> void:
	var dir := _key_dir()
	if dir == Vector2.ZERO and Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		dir = _mouse_world_dir()
	if cli_walk_dir != Vector2.ZERO:
		dir = cli_walk_dir
	var run := Input.is_physical_key_pressed(KEY_SHIFT)
	sim.step_player(dt, dir, run)
	sim.step_sheep(dt)
	for v in views:
		v.sync(dt)
	_update_hud()
	help_panel.position = Vector2(10, size.y - help_panel.size.y - 10)
	frame_count += 1
	if cli.has("shot") and frame_count == int(cli.get("frames", 30)):
		_screenshot(cli["shot"])
		get_tree().quit()


func _update_hud() -> void:
	var a: AssetSet = asset_sets.get(SETS[active])
	var mode := "side-by-side (%s)" % ("matched world scale" if matched_scale else "native pixels") if compare else a.label()
	hud.text = "Asset set: %s   |   %s\nZoom %.1fx   |   %d FPS\nPlayer (%.2f, %.2f)  tile (%d, %d)  facing %s%s" % [
		"compare" if compare else a.id, mode, ZOOMS[zoom_i], Engine.get_frames_per_second(),
		sim.player_pos.x, sim.player_pos.y, floori(sim.player_pos.x), floori(sim.player_pos.y),
		Iso.DIRECTIONS[sim.player_facing], "  (running)" if sim.player_running and sim.player_moving else ""]


func _screenshot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("screenshot -> %s (%s)" % [ProjectSettings.globalize_path(path), error_string(err)])
