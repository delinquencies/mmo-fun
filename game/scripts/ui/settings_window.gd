class_name SettingsWindow
extends GameWindow
## Display settings: world zoom and interface size (independent), reset.
## Emits requests; main.gd applies and saves them (DisplaySettings).

signal zoom_requested(delta: int)
signal ui_scale_requested(scale: float)
signal reset_requested

var zoom_label := UISkin.label("", UISkin.GOLD, 14)
var zoom_minus := Button.new()
var zoom_plus := Button.new()
var ui_buttons: Dictionary = {}     # scale -> Button
var note := UISkin.label("", UISkin.TEXT_DIM, 12)
var reset_btn := Button.new()


func _init(choices: PackedFloat32Array) -> void:
	super("Settings")
	content.add_child(UISkin.label("World zoom", UISkin.TEXT, 13))
	var zr := HBoxContainer.new()
	zr.add_theme_constant_override("separation", 8)
	for pair in [[zoom_minus, "-", -1], [zoom_plus, "+", 1]]:
		var b: Button = pair[0]
		b.text = pair[1]
		b.custom_minimum_size = Vector2(36, 26)
		ConnectWindow._button_style(b)
		var d: int = pair[2]
		b.pressed.connect(func(): zoom_requested.emit(d))
	zr.add_child(zoom_minus)
	zoom_label.custom_minimum_size = Vector2(60, 0)
	zoom_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	zr.add_child(zoom_label)
	zr.add_child(zoom_plus)
	zr.add_child(UISkin.label("mouse wheel", UISkin.TEXT_DIM, 12))
	content.add_child(zr)

	content.add_child(UISkin.label("Interface size", UISkin.TEXT, 13))
	var ur := HBoxContainer.new()
	ur.add_theme_constant_override("separation", 4)
	var group := ButtonGroup.new()
	for c in choices:
		var b := Button.new()
		b.text = "%d%%" % roundi(c * 100.0)
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size = Vector2(52, 26)
		ConnectWindow._button_style(b)
		b.add_theme_color_override("font_pressed_color", UISkin.GOLD)
		var sc := c
		b.pressed.connect(func(): ui_scale_requested.emit(sc))
		ur.add_child(b)
		ui_buttons[c] = b
	content.add_child(ur)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(300, 0)
	content.add_child(note)
	reset_btn.text = "Reset to default"
	ConnectWindow._button_style(reset_btn)
	reset_btn.pressed.connect(func(): reset_requested.emit())
	var rr := HBoxContainer.new()
	rr.add_child(reset_btn)
	content.add_child(rr)


func show_values(zoom: float, zmin: float, zmax: float, ui: float, effective: float) -> void:
	zoom_label.text = "%.2fx" % zoom
	zoom_minus.disabled = zoom <= zmin + 0.001
	zoom_plus.disabled = zoom >= zmax - 0.001
	for c in ui_buttons:
		ui_buttons[c].set_pressed_no_signal(absf(c - ui) < 0.001)
	if effective < ui - 0.01:
		note.text = "This window is too small for %d%%; showing %d%%. Saved for larger windows. F2 cycles sizes." % [roundi(ui * 100), roundi(effective * 100)]
	else:
		note.text = "Saved on this computer. F2 cycles interface sizes; O opens this window."
