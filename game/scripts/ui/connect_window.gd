class_name ConnectWindow
extends GameWindow
## Realm connection panel: address, port, name, connect / disconnect, status.

signal connect_requested(address: String, port: int, player_name: String)
signal disconnect_requested

var address_edit := LineEdit.new()
var port_edit := LineEdit.new()
var name_edit := LineEdit.new()
var connect_btn := Button.new()
var disconnect_btn := Button.new()
var status := UISkin.label("Offline - single-player world", UISkin.TEXT_DIM, 12)


static func _edit_style(e: LineEdit) -> void:
	var sb := UISkin.parchment()
	sb.content_margin_left = 6
	sb.content_margin_top = 3
	sb.content_margin_bottom = 3
	for k in ["normal", "focus", "read_only"]:
		e.add_theme_stylebox_override(k, sb)
	e.add_theme_color_override("font_color", UISkin.INK)
	e.add_theme_color_override("caret_color", UISkin.INK)
	e.add_theme_color_override("selection_color", Color(0.6, 0.45, 0.2, 0.5))
	e.add_theme_font_size_override("font_size", 13)


static func _button_style(b: Button) -> void:
	var sb := UISkin.titlebar()
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	for k in ["normal", "hover", "pressed", "disabled", "focus"]:
		b.add_theme_stylebox_override(k, sb)
	b.add_theme_color_override("font_color", UISkin.TEXT)
	b.add_theme_color_override("font_hover_color", UISkin.GOLD)
	b.add_theme_color_override("font_pressed_color", Color(0.75, 0.6, 0.3))
	b.add_theme_color_override("font_disabled_color", Color(0.45, 0.4, 0.33))
	b.add_theme_font_size_override("font_size", 13)


func _init() -> void:
	super("Realm Connection")
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	for pair in [["Server", address_edit, "127.0.0.1", 150], ["Port", port_edit, str(Protocol.DEFAULT_PORT), 70], ["Name", name_edit, "Adventurer", 150]]:
		grid.add_child(UISkin.label(pair[0], UISkin.TEXT, 12))
		var e: LineEdit = pair[1]
		e.text = pair[2]
		e.custom_minimum_size = Vector2(pair[3], 0)
		e.max_length = 64 if pair[0] == "Server" else Protocol.MAX_NAME
		_edit_style(e)
		grid.add_child(e)
	content.add_child(grid)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	connect_btn.text = "Enter the realm"
	disconnect_btn.text = "Leave"
	_button_style(connect_btn)
	_button_style(disconnect_btn)
	connect_btn.pressed.connect(_on_connect)
	disconnect_btn.pressed.connect(func(): disconnect_requested.emit())
	name_edit.text_submitted.connect(func(_t): _on_connect())
	row.add_child(connect_btn)
	row.add_child(disconnect_btn)
	content.add_child(row)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(240, 0)
	content.add_child(status)
	set_state("disconnected", "Offline - single-player world. Development servers are for localhost / LAN only.")


func _on_connect() -> void:
	var p := int(port_edit.text) if port_edit.text.is_valid_int() else Protocol.DEFAULT_PORT
	connect_requested.emit(address_edit.text.strip_edges(), p, name_edit.text)


func set_state(state: String, detail: String) -> void:
	status.text = detail
	var c := UISkin.TEXT_DIM
	match state:
		"connected":
			c = Color(0.62, 0.9, 0.5)
		"connecting":
			c = UISkin.GOLD
		"failed":
			c = UISkin.BAD
	status.add_theme_color_override("font_color", c)
	connect_btn.disabled = state == "connecting" or state == "connected"
	disconnect_btn.disabled = state != "connected" and state != "connecting"
	for e in [address_edit, port_edit, name_edit]:
		e.editable = state != "connected" and state != "connecting"
	if is_inside_tree():
		fit()
