class_name ItemSlot
extends Control
## One inventory / equipment slot. Displays whatever the authoritative store
## says occupies `loc`; all changes go through GameUI -> InteractionSystem.

const SIZE := 44

var ui: GameUI
var window: GameWindow
var loc: Dictionary
var disabled := false
var caption := ""
var uid := 0
var hover := false
var pressed := false
var drop_state := 0      # 0 none, 1 would accept, 2 would refuse
var flash := 0.0         # red flash on refused drop
var pop := 0.0           # bounce when an item lands


func _init(p_ui: GameUI, p_loc: Dictionary, p_disabled := false, p_caption := "") -> void:
	ui = p_ui
	loc = p_loc
	disabled = p_disabled
	caption = p_caption
	custom_minimum_size = Vector2(SIZE, SIZE)
	size = custom_minimum_size
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = " "
	mouse_entered.connect(func(): hover = true; queue_redraw())
	mouse_exited.connect(func(): hover = false; pressed = false; drop_state = 0; queue_redraw())


func refresh() -> void:
	var u := ui.store.occupant(loc)
	if u != uid and u != 0:
		pop = 1.0
	uid = u
	queue_redraw()


func _process(dt: float) -> void:
	if pop > 0.0 or flash > 0.0:
		pop = maxf(0.0, pop - dt * 5.0)
		flash = maxf(0.0, flash - dt * 2.5)
		queue_redraw()


func _draw() -> void:
	var state := "normal"
	if disabled:
		state = "disabled"
	elif drop_state == 1:
		state = "drop_ok"
	elif drop_state == 2 or flash > 0.0:
		state = "drop_bad"
	elif pressed:
		state = "pressed"
	elif ui.selected_slot == self and uid != 0:
		state = "selected"
	elif hover:
		state = "hover"
	draw_texture(UISkin.ui("slot_" + state), Vector2.ZERO)
	if uid == 0:
		return
	var it := ui.store.item(uid)
	if it == null:
		return
	var d := ui.store.def(it.def_id)
	var icon := UISkin.icon(d.icon)
	if icon:
		var s := 1.0 + 0.18 * sin(pop * PI)
		var sz := icon.get_size() * s
		var off := Vector2(1, 1) if pressed else Vector2.ZERO
		var col := Color(1, 1, 1, 0.35) if ui.dragging_uid == uid else Color.WHITE
		draw_texture_rect(icon, Rect2((size - sz) * 0.5 + off, sz), false, col)
	if d.stackable and it.quantity > 1:
		var font := get_theme_default_font()
		var txt := str(it.quantity)
		var w := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		var p := Vector2(size.x - w - 5, size.y - 6)
		draw_string_outline(font, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, 3, Color(0.05, 0.03, 0.02))
		draw_string(font, p, txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UISkin.TEXT)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		pressed = e.pressed and not disabled
		if e.pressed:
			if window:
				window.raise()
			if e.double_click and uid != 0:
				ui.use_item(uid)
			else:
				ui.select_slot(self)
		queue_redraw()


func _get_drag_data(_at: Vector2) -> Variant:
	if uid == 0 or disabled:
		return null
	var it := ui.store.item(uid)
	var qty := 0
	if Input.is_key_pressed(KEY_SHIFT) and ui.store.def(it.def_id).stackable and it.quantity > 1:
		qty = 1
	pressed = false
	set_drag_preview(ui.make_drag_preview(uid))
	ui.begin_drag(uid)
	return {"uid": uid, "from": ui.store.location(uid), "qty": qty}


func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	if not (data is Dictionary and data.has("uid")):
		return false
	var s := 1 if ui.would_accept(data, loc) else 2
	if s != drop_state:
		drop_state = s
		queue_redraw()
	# always accept the drop so a refused transfer still gets explicit feedback
	return true


func _drop_data(_at: Vector2, data: Variant) -> void:
	drop_state = 0
	if not ui.transfer(data, loc):
		flash = 1.0
	queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		drop_state = 0
		pressed = false
		queue_redraw()


func _make_custom_tooltip(_t: String) -> Object:
	if uid != 0:
		return ui.make_tooltip(uid)
	if caption != "":
		return ui.make_text_tooltip(caption)
	return null
