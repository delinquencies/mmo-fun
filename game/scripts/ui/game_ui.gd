class_name GameUI
extends Control
## Client-side UI controller. Owns windows, selection, drag state, tooltips and
## feedback text. It reads the authoritative ItemStore for display and turns
## every user action into an InteractionCommand - it never edits item state.

signal feedback(text: String, world_pos: Vector2, color: Color)

var sim: WorldSim
var store: ItemStore
var interaction: InteractionSystem   # local rules: drop previews / range only
var authority: Object                # decides outcomes: InteractionSystem offline, NetClient online
var audio: AudioEvents
var actor := WorldSim.PLAYER_ID

var backpack: ContainerWindow
var equipment_win: EquipmentWindow
var chest_windows: Dictionary = {}     # container id -> ContainerWindow
var selected_slot: ItemSlot
var dragging_uid := 0
var ui_scale := 1.0


func setup(p_sim: WorldSim, p_audio: AudioEvents, p_authority: Object = null) -> void:
	sim = p_sim
	store = sim.items
	interaction = sim.interaction
	authority = p_authority if p_authority else sim.interaction
	actor = sim.local_actor
	audio = p_audio
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	store.changed.connect(_refresh_all)
	authority.event_emitted.connect(_on_event)
	backpack = ContainerWindow.new(self, interaction.backpack_id(actor))
	backpack.close_requested.connect(func(): toggle_backpack(false))
	equipment_win = EquipmentWindow.new(self, actor)
	equipment_win.close_requested.connect(func(): toggle_equipment(false))
	add_child(backpack)
	add_child(equipment_win)
	_place_default.call_deferred()


func _place_default() -> void:
	var v := view_size()
	backpack.position = Vector2(v.x - backpack.size.x - 14, 96)
	equipment_win.position = Vector2(v.x - equipment_win.size.x - 14, 96 + backpack.size.y + 8)


func view_size() -> Vector2:
	return get_viewport_rect().size / ui_scale


func set_ui_scale(s: float) -> void:
	ui_scale = s
	scale = Vector2(s, s)
	for w in get_children():
		if w is GameWindow:
			var v := view_size()
			w.position = Vector2(clampf(w.position.x, 0, v.x - 60), clampf(w.position.y, 0, v.y - 40))


func toggle_backpack(show: Variant = null) -> void:
	_toggle(backpack, show)


func toggle_equipment(show: Variant = null) -> void:
	_toggle(equipment_win, show)


func _toggle(w: GameWindow, show: Variant) -> void:
	var v: bool = (not w.visible) if show == null else bool(show)
	if v == w.visible:
		if v:
			w.raise()
		return
	w.visible = v
	audio.play("window_open" if v else "window_close")
	if v:
		w.raise()
		w.pop_in()


# --- commands ---------------------------------------------------------------

func submit(cmd: InteractionCommand) -> CommandResult:
	return authority.submit(cmd)


func would_accept(data: Dictionary, to: Dictionary) -> bool:
	return interaction.transfers.plan(actor, int(data["uid"]), data["from"], to, int(data.get("qty", 0)))["ok"]


func transfer(data: Dictionary, to: Dictionary) -> bool:
	return submit(InteractionCommand.transfer(actor, int(data["uid"]), data["from"], to, int(data.get("qty", 0)))).ok


var last_drop_slot: ItemSlot


func use_item(uid: int) -> void:
	submit(InteractionCommand.use_item(actor, uid, store.location(uid)))


func begin_drag(uid: int) -> void:
	dragging_uid = uid
	_refresh_all()


func select_slot(s: ItemSlot) -> void:
	var prev := selected_slot
	selected_slot = s
	if prev and is_instance_valid(prev):
		prev.queue_redraw()
	s.queue_redraw()
	audio.play("ui_click")


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END and dragging_uid != 0:
		dragging_uid = 0
		_refresh_all()


# --- events from the authority ---------------------------------------------

func _on_event(e: Dictionary) -> void:
	match e["type"]:
		"container_opened":
			if e["actor"] == actor:
				_open_container(e["container"])
		"container_closed":
			if e["actor"] == actor and chest_windows.has(e["container"]):
				var w: ContainerWindow = chest_windows[e["container"]]
				chest_windows.erase(e["container"])
				w.queue_free()
		"sound":
			audio.play(e["name"], e.get("pos"))
		"system":
			feedback.emit(e["message"], Vector2.INF, UISkin.GOLD)
		"failed":
			if e["actor"] == actor:
				audio.play("invalid")
				if last_drop_slot and is_instance_valid(last_drop_slot):
					last_drop_slot.flash = 1.0
				if e["message"] != "":
					feedback.emit(e["message"], e["pos"], UISkin.BAD)


func _open_container(cid: String) -> void:
	if chest_windows.has(cid):
		chest_windows[cid].raise()
		return
	var w := ContainerWindow.new(self, cid)
	w.close_requested.connect(func(): submit(InteractionCommand.close_container(actor, cid)))
	add_child(w)
	var v := view_size()
	w.position = Vector2(v.x * 0.5 + 60, v.y * 0.5 - w.size.y - 30)
	w.pop_in()
	chest_windows[cid] = w


func _refresh_all() -> void:
	backpack.refresh()
	equipment_win.refresh()
	for cid in chest_windows:
		chest_windows[cid].refresh()


# --- tooltips & previews -----------------------------------------------------

func make_tooltip(uid: int) -> Control:
	var it := store.item(uid)
	if it == null:
		return null
	var d := store.def(it.def_id)
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UISkin.parchment())
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	var title := d.name + ("  x%d" % it.quantity if d.stackable and it.quantity > 1 else "")
	v.add_child(UISkin.label(title, UISkin.INK, 14, false))
	var desc := UISkin.label(d.description, UISkin.INK_DIM, 12, false)
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.custom_minimum_size = Vector2(210, 0)
	v.add_child(desc)
	var facts: PackedStringArray = []
	if d.equip_slot != "":
		facts.append("Equip: %s" % EquipmentComponent.SLOT_NAMES.get(d.equip_slot, d.equip_slot))
	if d.stackable:
		facts.append("Stacks to %d" % d.max_stack)
	facts.append("#%d" % uid)
	v.add_child(UISkin.label("   ".join(facts), UISkin.INK_DIM, 11, false))
	p.add_child(v)
	return p


func make_text_tooltip(text: String) -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UISkin.parchment())
	p.add_child(UISkin.label(text, UISkin.INK, 12, false))
	return p


func make_drag_preview(uid: int) -> Control:
	var root := Control.new()
	var icon := UISkin.icon(store.def(store.item(uid).def_id).icon)
	var tr := TextureRect.new()
	tr.texture = icon
	tr.scale = Vector2(ui_scale, ui_scale)
	tr.position = -icon.get_size() * 0.5 * ui_scale
	tr.modulate = Color(1, 1, 1, 0.9)
	root.add_child(tr)
	return root
