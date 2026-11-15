class_name LoginWindow
extends GameWindow
## Account login / registration for a persistent realm.

signal login_requested(username: String, password: String)
signal register_requested(username: String, password: String)
signal leave_requested

var user_edit := LineEdit.new()
var pass_edit := LineEdit.new()
var login_btn := Button.new()
var register_btn := Button.new()
var leave_btn := Button.new()
var status := UISkin.label("", UISkin.TEXT_DIM, 12)
var realm_label := UISkin.label("", UISkin.GOLD, 13)


func _init() -> void:
	super("Enter the Realm")
	content.add_child(realm_label)
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	for pair in [["Account", user_edit], ["Password", pass_edit]]:
		grid.add_child(UISkin.label(pair[0], UISkin.TEXT, 12))
		var e: LineEdit = pair[1]
		e.custom_minimum_size = Vector2(170, 0)
		e.max_length = 64
		ConnectWindow._edit_style(e)
		grid.add_child(e)
	pass_edit.secret = true
	pass_edit.text_submitted.connect(func(_t): _login())
	content.add_child(grid)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	for pair in [[login_btn, "Log in"], [register_btn, "Create account"], [leave_btn, "Leave"]]:
		var b: Button = pair[0]
		b.text = pair[1]
		ConnectWindow._button_style(b)
		row.add_child(b)
	login_btn.pressed.connect(_login)
	register_btn.pressed.connect(func(): register_requested.emit(user_edit.text.strip_edges(), pass_edit.text))
	leave_btn.pressed.connect(func(): leave_requested.emit())
	content.add_child(row)
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(250, 0)
	content.add_child(status)
	content.add_child(UISkin.label("Account names: 3-24 letters, digits or _. Passwords: 8+ characters.", UISkin.TEXT_DIM, 11))


func _login() -> void:
	login_requested.emit(user_edit.text.strip_edges(), pass_edit.text)


func set_status(text: String, bad := false) -> void:
	status.text = text
	status.add_theme_color_override("font_color", UISkin.BAD if bad else UISkin.TEXT_DIM)
	if is_inside_tree():
		fit()


func set_busy(b: bool) -> void:
	login_btn.disabled = b
	register_btn.disabled = b
