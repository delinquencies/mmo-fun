class_name GameWindow
extends Control
## Draggable leather window with a timber title bar and close button.

signal close_requested

const TITLE_H := 22
const PAD := 10

var title_label: Label
var content := VBoxContainer.new()
var _bg := Panel.new()
var _bar := Panel.new()
var _close := TextureButton.new()
var _dragging := false
var _drag_off := Vector2.ZERO


func _init(title: String) -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	_bg.add_theme_stylebox_override("panel", UISkin.panel())
	_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_bg)
	_bar.add_theme_stylebox_override("panel", UISkin.titlebar())
	_bar.position = Vector2(6, 6)
	_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_bar.mouse_default_cursor_shape = Control.CURSOR_DRAG
	_bar.gui_input.connect(_on_bar_input)
	add_child(_bar)
	title_label = UISkin.label(title, UISkin.GOLD)
	title_label.position = Vector2(14, 1)
	_bar.add_child(title_label)
	_close.texture_normal = UISkin.ui("close_normal")
	_close.texture_hover = UISkin.ui("close_hover")
	_close.texture_pressed = UISkin.ui("close_pressed")
	_close.pressed.connect(func(): close_requested.emit())
	_close.tooltip_text = "Close"
	_bar.add_child(_close)
	content.position = Vector2(PAD, TITLE_H + 12)
	content.add_theme_constant_override("separation", 6)
	add_child(content)


func _ready() -> void:
	fit()


## Size the frame to its content (call after filling `content`).
func fit() -> void:
	content.reset_size()
	var c := content.get_combined_minimum_size()
	size = Vector2(maxf(c.x + PAD * 2, 140), c.y + TITLE_H + 12 + PAD)
	_bar.size = Vector2(size.x - 12, TITLE_H)
	_close.position = Vector2(_bar.size.x - 20, 3)
	pivot_offset = size * 0.5


func set_title(t: String) -> void:
	title_label.text = t


func pop_in() -> void:
	scale = Vector2(0.94, 0.94)
	modulate.a = 0.0
	var tw := create_tween().set_parallel().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "scale", Vector2.ONE, 0.16)
	tw.tween_property(self, "modulate:a", 1.0, 0.1)


func raise() -> void:
	if get_parent():
		get_parent().move_child(self, -1)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.pressed:
		raise()


func _on_bar_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		_dragging = e.pressed
		if e.pressed:
			raise()
			_drag_off = e.global_position - global_position
		# lift while carried
		position.y += -1 if e.pressed else 1
		modulate = Color(1.06, 1.06, 1.06) if e.pressed else Color.WHITE
	elif e is InputEventMouseMotion and _dragging:
		var parent_rect := get_parent_control().get_rect() if get_parent_control() else Rect2(Vector2.ZERO, get_viewport_rect().size)
		var p: Vector2 = (e.global_position - _drag_off - get_parent_control().global_position) / get_parent_control().scale
		var view := parent_rect.size / get_parent_control().scale
		position = Vector2(clampf(p.x, -size.x + 60, view.x - 60), clampf(p.y, 0, view.y - TITLE_H - 8))
