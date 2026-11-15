extends Control
## Isometric visual laboratory: owns the simulation, one or two WorldViews
## (resolution comparison), input, zoom and the HUD.

const SETS: PackedStringArray = ["t64", "t96"]
const ZOOMS: PackedFloat32Array = [0.5, 1.0, 1.5, 2.0, 3.0, 4.0]
const MAP := "res://data/maps/homestead.json"

var sim := WorldSim.new()            # the world being shown: offline sim or the network replica
var offline_sim: WorldSim
var net := NetClient.new()
var online := false
var connect_win := ConnectWindow.new()
var login_win := LoginWindow.new()
var char_win := CharacterWindow.new()
var name_labels: Dictionary = {}     # actor -> Label
var _authority: Object
var asset_sets: Dictionary = {}
var active := 0
var compare := false
var matched_scale := false
var zoom_i := 3
var show_grid := false
var show_collision := false
var show_energy := false
var show_help := true
const UI_SCALES: PackedFloat32Array = [1.0, 1.5, 2.0]
var ui_scale_i := 0

var views: Array[WorldView] = []
var cells: Array[Control] = []
var row := HBoxContainer.new()
var hud := Label.new()
var help := Label.new()
var hud_panel := PanelContainer.new()
var help_panel := PanelContainer.new()

# Slice 002: interaction + UI
var audio := AudioEvents.new()
var surface := WorldSurface.new()
var game_ui := GameUI.new()
var float_layer := Control.new()
var journal := VBoxContainer.new()
var floaters: Array = []          # [Label, world_pos, height_px, age]
var hovered_id := ""
var scenario: Node

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
	offline_sim = sim
	net.name = "NetClient"
	add_child(net)
	net.status_changed.connect(_on_net_status)
	net.world_ready.connect(_on_net_world_ready)
	if cli.has("lag") or cli.has("loss") or cli.has("jitter"):
		net.net.configure(float(cli.get("lag", 0)), float(cli.get("jitter", 0)), float(cli.get("loss", 0)))
	if cli.has("no_predict"):
		net.predict = false
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

	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.add_theme_constant_override("separation", 2)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	add_child(audio)
	surface.main = self
	add_child(surface)
	float_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	float_layer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(float_layer)
	_build_hud()
	journal.mouse_filter = Control.MOUSE_FILTER_IGNORE
	journal.add_theme_constant_override("separation", 0)
	add_child(journal)
	_setup_cursors()
	_switch_world(sim, sim.interaction)
	connect_win.connect_requested.connect(func(a, p, n): net.connect_to(a, p, n))
	connect_win.disconnect_requested.connect(func(): net.disconnect_from_server())
	connect_win.leave_world_requested.connect(func(): net.send_chars("leave"))
	add_child(connect_win)
	connect_win.visible = false
	_setup_account_ui()
	_place_connect_window.call_deferred()
	if cli.has("connect"):
		var hp: PackedStringArray = String(cli["connect"]).split(":")
		connect_win.address_edit.text = hp[0]
		if hp.size() > 1:
			connect_win.port_edit.text = hp[1]
		if cli.has("name"):
			connect_win.name_edit.text = String(cli["name"])
		connect_win._on_connect.call_deferred()
	if cli.has("ui_scale"):
		set_ui_scale(float(cli["ui_scale"]))
	if cli.has("scenario"):
		scenario = load("res://scripts/debug/scenario_runner.gd").new()
		scenario.main = self
		scenario.name_ = String(cli["scenario"])
		add_child(scenario)


## Show a world: the offline sim (authority = its InteractionSystem) or the
## network replica (authority = NetClient). Views and UI are rebuilt for it.
func _switch_world(new_sim: WorldSim, authority: Object) -> void:
	if _authority and _authority.event_emitted.is_connected(_journal_event):
		_authority.event_emitted.disconnect(_journal_event)
	sim = new_sim
	_authority = authority
	if is_instance_valid(game_ui) and game_ui.is_inside_tree():
		remove_child(game_ui)
		game_ui.queue_free()
	game_ui = GameUI.new()
	game_ui.setup(sim, audio, authority)
	game_ui.feedback.connect(func(t, p, c): float_text(t, p, 86.0, c))
	add_child(game_ui)
	authority.event_emitted.connect(_journal_event)
	for l in name_labels.values():
		l.queue_free()
	name_labels.clear()
	hovered_id = ""
	_rebuild_views()
	set_ui_scale(UI_SCALES[ui_scale_i])
	for w in [connect_win, login_win, char_win]:
		if w.is_inside_tree():
			move_child(w, -1)


# --- Slice 004: login, character selection ------------------------------------

func _setup_account_ui() -> void:
	for w in [login_win, char_win]:
		add_child(w)
		w.visible = false
	login_win.close_requested.connect(func(): net.disconnect_from_server())
	char_win.close_requested.connect(func(): net.disconnect_from_server())
	login_win.login_requested.connect(func(u, pw):
		login_win.set_busy(true)
		login_win.set_status("Checking your credentials ...")
		net.send_auth("login", {"username": u, "password": pw}))
	login_win.register_requested.connect(func(u, pw):
		login_win.set_busy(true)
		login_win.set_status("Creating the account ...")
		net.send_auth("register", {"username": u, "password": pw}))
	login_win.leave_requested.connect(func(): net.disconnect_from_server())
	char_win.enter_requested.connect(func(cid):
		char_win.set_status("Entering the world ...")
		net.send_chars("enter", {"character_id": cid}))
	char_win.create_requested.connect(func(n, ap): net.send_chars("create", {"name": n, "appearance": ap}))
	char_win.logout_requested.connect(func(): net.send_auth("logout", {}))
	net.realm_ready.connect(_on_realm_ready)
	net.auth_result.connect(_on_auth_result)
	net.chars_result.connect(_on_chars_result)
	net.left_world.connect(_on_left_world)
	var aset: AssetSet = asset_sets.get(SETS[active])
	if aset:
		var meta := aset.anim("player")
		var idle: Dictionary = meta["anims"]["idle"]
		var pv := Vector2(meta["pivot"][0], meta["pivot"][1])
		var h := float(meta.get("content_height_px", 72)) + 6.0
		char_win.set_preview_source(aset.texture(idle["file"]), Rect2(pv.x - h * 0.42, pv.y - h, h * 0.84, h + 4))


func _show_window(w: GameWindow) -> void:
	for o in [connect_win, login_win, char_win]:
		o.visible = o == w
	w.fit()
	w.position = Vector2(size.x * 0.5 - w.size.x * 0.5, maxf(60.0, size.y * 0.5 - w.size.y * 0.5 - 60))
	move_child(w, -1)
	w.pop_in()


func _on_realm_ready(info: Dictionary) -> void:
	login_win.realm_label.text = "%s  -  %s" % [info["realm"], "encrypted connection" if net.secure else "unencrypted (local only)"]
	login_win.set_busy(false)
	login_win.set_status("Log in, or create an account.")
	_show_window(login_win)


func _on_auth_result(r: Dictionary) -> void:
	login_win.set_busy(false)
	if not r["ok"]:
		login_win.set_status(r["message"], true)
		if not login_win.visible and net.state == "login":
			_show_window(login_win)
		return
	if net.state == "account":
		char_win.set_status("")
		_show_window(char_win)
		net.send_chars("list")
	elif net.state == "login":
		if r["data"].has("username") and not r["data"].has("token"):
			login_win.set_status("Account '%s' created. You can log in now." % r["data"]["username"])
		else:
			login_win.set_status("Logged out.")
		_show_window(login_win)


func _on_chars_result(r: Dictionary) -> void:
	if not r["ok"]:
		char_win.set_status(r["message"], true)
		return
	var d: Dictionary = r["data"]
	if d.has("characters"):
		char_win.populate(d["characters"])
	elif d.has("character"):
		char_win.set_status("%s has been created." % d["character"]["name"])
		char_win.name_edit.text = ""
		net.send_chars("list")


func _on_left_world(reason: String) -> void:
	online = false
	_switch_world(offline_sim, offline_sim.interaction)
	char_win.set_status(reason)
	_show_window(char_win)
	net.send_chars("list")


func _place_connect_window() -> void:
	connect_win.fit()
	connect_win.position = Vector2(size.x * 0.5 - connect_win.size.x * 0.5, 90)


func _on_net_status(state: String, detail: String) -> void:
	connect_win.set_state(state, detail)
	connect_win.leave_world_btn.visible = state == "connected" and not net.realm.is_empty()
	if state == "disconnected" or state == "failed":
		login_win.visible = false
		char_win.visible = false
		if not online:
			connect_win.visible = true
	_journal(detail, UISkin.BAD if state == "failed" else UISkin.GOLD)
	if (state == "disconnected" or state == "failed") and online:
		online = false
		_switch_world(offline_sim, offline_sim.interaction)
		connect_win.visible = true
		move_child(connect_win, -1)


func _on_net_world_ready() -> void:
	online = true
	_switch_world(net.sim, net)
	for w in [connect_win, login_win, char_win]:
		w.visible = false


## Say goodbye while the scene tree is still intact (window close / scripted quit),
## so the server removes the character at once instead of treating it as a crash.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		net.goodbye_now()


func quit_game(code := 0) -> void:
	net.goodbye_now()
	await get_tree().process_frame
	get_tree().quit(code)


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
		"E  blade-energy preview      F5  hot-reload forged assets      F12  screenshot      H  hide help",
		"Left click  select / name      Double-click  use (door, chest, pick up, equip)      Drag  move items",
		"I  backpack      P  equipment      Shift+drag  move one from a stack      F2  UI scale      F9  realm connection",
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
		cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.size_flags_vertical = Control.SIZE_EXPAND_FILL
		cell.clip_contents = true
		var svc := SubViewportContainer.new()
		svc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		svc.stretch = true
		svc.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		var vp := SubViewport.new()
		vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
		vp.snap_2d_transforms_to_pixel = true
		svc.add_child(vp)
		cell.add_child(svc)
		var view := WorldView.new()
		view.setup(sim, asset_sets[id])
		vp.add_child(view)
		var tag := Label.new()
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return   # typing into a panel (connection, login, character name)
	match event.physical_keycode:
		KEY_F9:
			connect_win.visible = not connect_win.visible
			if connect_win.visible:
				move_child(connect_win, -1)
				connect_win.pop_in()
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
		KEY_I, KEY_B:
			game_ui.toggle_backpack()
		KEY_P:
			game_ui.toggle_equipment()
		KEY_F2:
			ui_scale_i = (ui_scale_i + 1) % UI_SCALES.size()
			set_ui_scale(UI_SCALES[ui_scale_i])
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
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
		surface.right_held = false
	if dir == Vector2.ZERO and surface.right_held:
		dir = _mouse_world_dir()
	if scenario and scenario.move_target != Vector2.INF:
		var to: Vector2 = scenario.move_target - sim.player_pos
		dir = to if to.length() > 0.06 else Vector2.ZERO
	if cli_walk_dir != Vector2.ZERO:
		dir = cli_walk_dir
	var run := Input.is_physical_key_pressed(KEY_SHIFT)
	if get_viewport().gui_get_focus_owner() is LineEdit:
		dir = Vector2.ZERO
	if online:
		net.set_input(dir, run)      # intent only; the server moves the character
	else:
		sim.step_player(dt, dir, run)
		sim.step_sheep(dt)
		sim.interaction.update(dt)
	audio.listener_pos = sim.player_pos
	for v in views:
		v.sync(dt)
	_update_floaters(dt)
	_update_name_labels()
	journal.position = Vector2(12, size.y - help_panel.size.y - journal.size.y - 18) if help_panel.visible else Vector2(12, size.y - journal.size.y - 12)
	_update_hud()
	help_panel.position = Vector2(10, size.y - help_panel.size.y - 10)
	frame_count += 1
	if cli.has("shot") and not scenario and frame_count == int(cli.get("frames", 30)):
		_screenshot(cli["shot"])
		get_tree().quit()


func _update_name_labels() -> void:
	for a in sim.players:
		var ps: PlayerState = sim.players[a]
		var l: Label = name_labels.get(a)
		if l == null:
			l = UISkin.label(ps.display_name, UISkin.GOLD if a == sim.local_actor else UISkin.TEXT, 13)
			float_layer.add_child(l)
			name_labels[a] = l
		l.text = ps.display_name + ("  (link lost)" if ps.linkdead else "")
		l.modulate.a = 0.55 if ps.linkdead else 1.0
		l.position = (world_to_screen(ps.render_pos, 86.0) - Vector2(l.size.x * 0.5, l.size.y)).round()
	for a in name_labels.keys():
		if not sim.players.has(a):
			name_labels[a].queue_free()
			name_labels.erase(a)


func _net_line() -> String:
	if not online:
		return "Offline single-player   (F9: connect to a server)"
	return "Online as %s  -  %s:%d  -  %d in world  -  rtt %d ms" % [net.player_name, net.address, net.port,
		sim.players.size(), int(net.rtt * 1000.0)]


func _update_hud() -> void:
	var a: AssetSet = asset_sets.get(SETS[active])
	var mode := "side-by-side (%s)" % ("matched world scale" if matched_scale else "native pixels") if compare else a.label()
	hud.text = "Asset set: %s   |   %s\nZoom %.1fx   |   %d FPS\nPlayer (%.2f, %.2f)  tile (%d, %d)  facing %s%s" % [
		"compare" if compare else a.id, mode, ZOOMS[zoom_i], Engine.get_frames_per_second(),
		sim.player_pos.x, sim.player_pos.y, floori(sim.player_pos.x), floori(sim.player_pos.y),
		Iso.DIRECTIONS[sim.player_facing], "  (running)" if sim.player_running and sim.player_moving else ""]
	hud.text += "\n" + _net_line()


func _screenshot(path: String) -> void:
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(path)
	print("screenshot -> %s (%s)" % [ProjectSettings.globalize_path(path), error_string(err)])


# --- Slice 002: world interaction (client intent -> InteractionCommand) -----

func set_ui_scale(sc: float) -> void:
	game_ui.set_ui_scale(sc)


func zoom_step(d: int) -> void:
	_zoom(d)


func _setup_cursors() -> void:
	var c := {
		Input.CURSOR_ARROW: ["cursor_default", Vector2(0, 0)],
		Input.CURSOR_POINTING_HAND: ["cursor_use", Vector2(10, 0)],
		Input.CURSOR_MOVE: ["cursor_far", Vector2(10, 0)],
		Input.CURSOR_DRAG: ["cursor_grab", Vector2(16, 16)],
		Input.CURSOR_CAN_DROP: ["cursor_grab", Vector2(16, 16)],
		Input.CURSOR_FORBIDDEN: ["cursor_denied", Vector2(16, 16)],
	}
	for shape in c:
		var t := UISkin.ui(c[shape][0])
		if t:
			Input.set_custom_mouse_cursor(t, shape, c[shape][1])


## Screen position -> {view index, world pixel, world tile coords}; {} if none.
func screen_to_world(screen: Vector2) -> Dictionary:
	for k in cells.size():
		var cell := cells[k]
		var local := screen - cell.global_position
		if Rect2(Vector2.ZERO, cell.size).has_point(local):
			var vp: SubViewport = cell.get_child(0).get_child(0)
			var px := vp.get_canvas_transform().affine_inverse() * local
			return {"k": k, "px": px, "world": Iso.to_world(px, views[k].aset.tile_w)}
	return {}


## World tile position (+ height in sprite px of the primary set) -> screen.
func world_to_screen(world: Vector2, height_px := 0.0, k := 0) -> Vector2:
	if views.is_empty():
		return Vector2.ZERO
	k = mini(k, views.size() - 1)
	var vp: SubViewport = cells[k].get_child(0).get_child(0)
	var h := height_px * views[k].aset.tile_w / 64.0
	return cells[k].global_position + vp.get_canvas_transform() * (Iso.to_screen(world, views[k].aset.tile_w) - Vector2(0, h))


func pick_at(screen: Vector2) -> String:
	var w := screen_to_world(screen)
	return views[w["k"]].pick(w["px"]) if not w.is_empty() else ""


func entity_world_pos(id: String) -> Vector2:
	if id.begins_with("item:"):
		var loc := sim.items.location(int(id.substr(5)))
		return loc["pos"] if loc.get("kind", "") == "world" else Vector2.INF
	return sim.entities[id].pos if sim.entities.has(id) else Vector2.INF


func entity_range(id: String) -> float:
	return InteractionSystem.ITEM_RANGE if id.begins_with("item:") else sim.entities[id].use_range()


func update_hover(screen: Vector2) -> void:
	var id := pick_at(screen)
	if id != hovered_id:
		hovered_id = id
		for v in views:
			v.hovered = id
	var shape := Control.CURSOR_ARROW
	if id != "":
		var in_range := sim.player_pos.distance_to(entity_world_pos(id)) <= entity_range(id)
		shape = Control.CURSOR_POINTING_HAND if in_range else Control.CURSOR_MOVE
	surface.mouse_default_cursor_shape = shape


func entity_name(id: String) -> String:
	if id.begins_with("item:"):
		var it := sim.items.item(int(id.substr(5)))
		if it == null:
			return ""
		var d := sim.items.def(it.def_id)
		return d.name + (" (%d)" % it.quantity if d.stackable and it.quantity > 1 else "")
	return sim.entities[id].display_name() if sim.entities.has(id) else ""


func select_entity(id: String) -> void:
	for v in views:
		v.selected = id
	if id != "":
		float_text(entity_name(id), entity_world_pos(id), 40.0, UISkin.GOLD)
		audio.play("ui_click")


func use_entity(id: String) -> void:
	game_ui.submit(InteractionCommand.use_entity(sim.local_actor, id))


func start_world_drag(id: String, src: Control) -> void:
	var uid := int(id.substr(5))
	if sim.items.item(uid) == null:
		return
	var data := {"uid": uid, "from": sim.items.location(uid), "qty": 0}
	game_ui.begin_drag(uid)
	src.force_drag(data, game_ui.make_drag_preview(uid))


func preview_world_drop(screen: Vector2, data: Dictionary) -> void:
	var w := screen_to_world(screen)
	if w.is_empty():
		return
	var to := ItemLocation.world(w["world"])
	var ok := game_ui.would_accept(data, to)
	for v in views:
		v.drop_marker.show_at(w["world"], ok)


func hide_drop_marker() -> void:
	for v in views:
		v.drop_marker.visible = false


func drop_on_world(screen: Vector2, data: Dictionary) -> void:
	hide_drop_marker()
	var w := screen_to_world(screen)
	if not w.is_empty():
		game_ui.transfer(data, ItemLocation.world(w["world"]))


# --- feedback text ------------------------------------------------------------

func float_text(text: String, world_pos: Vector2, height_px: float, color: Color) -> void:
	if text == "":
		return
	if world_pos == Vector2.INF:
		_journal(text, color)
		return
	var l := UISkin.label(text, color, 14)
	float_layer.add_child(l)
	floaters.append([l, world_pos, height_px, 0.0])
	_journal(text, color)


func _update_floaters(dt: float) -> void:
	for f in floaters.duplicate():
		var l: Label = f[0]
		f[3] += dt
		var age: float = f[3]
		var p := world_to_screen(f[1], f[2]) - Vector2(l.size.x * 0.5, l.size.y + age * 14.0)
		l.position = p.round()
		l.modulate.a = clampf(2.2 - age, 0.0, 1.0)
		if age > 2.2:
			l.queue_free()
			floaters.erase(f)


func _journal(text: String, color := UISkin.TEXT) -> void:
	var l := UISkin.label(text, color, 12)
	journal.add_child(l)
	while journal.get_child_count() > 6:
		var c := journal.get_child(0)
		journal.remove_child(c)
		c.queue_free()


func _journal_event(e: Dictionary) -> void:
	match e["type"]:
		"item_moved":
			var d := sim.items.def(e["def"])
			var fk: String = e["from"]["kind"]
			var tk: String = e["to"]["kind"]
			var n := d.name + (" (%d)" % int(e["qty"]) if d.stackable and int(e["qty"]) > 1 else "")
			if tk == "equipment":
				_journal("You equip the %s." % d.name)
			elif fk == "equipment":
				_journal("You unequip the %s." % d.name)
			elif fk == "world":
				_journal("You pick up %s." % n)
			elif tk == "world":
				_journal("You place %s on the ground." % n)
			else:
				_journal("Moved %s." % n, UISkin.TEXT_DIM)
		"door_changed":
			_journal("The door swings %s." % ("open" if e["open"] else "shut"), UISkin.TEXT_DIM)
