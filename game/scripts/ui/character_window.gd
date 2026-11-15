class_name CharacterWindow
extends GameWindow
## Character selection + minimal creation (name, cloth colour).

signal enter_requested(character_id: int)
signal create_requested(name: String, appearance: Dictionary)
signal logout_requested

var list := VBoxContainer.new()
var name_edit := LineEdit.new()
var create_btn := Button.new()
var logout_btn := Button.new()
var status := UISkin.label("", UISkin.TEXT_DIM, 12)
var swatches: Dictionary = {}
var cloth := "olive"
var enter_buttons: Dictionary = {}      # character id -> Button
var _preview_tex: Texture2D
var _preview_region := Rect2()


func _init() -> void:
	super("Your Characters")
	list.add_theme_constant_override("separation", 4)
	content.add_child(list)
	content.add_child(HSeparator.new())
	content.add_child(UISkin.label("New character", UISkin.GOLD, 13))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	name_edit.placeholder_text = "Name"
	name_edit.custom_minimum_size = Vector2(130, 0)
	name_edit.max_length = 16
	ConnectWindow._edit_style(name_edit)
	row.add_child(name_edit)
	for key in Appearance.CLOTH:
		var b := Button.new()
		b.custom_minimum_size = Vector2(22, 22)
		b.tooltip_text = Appearance.CLOTH[key]["label"] + " cloth"
		var sb := StyleBoxFlat.new()
		sb.bg_color = Appearance.CLOTH[key]["swatch"]
		sb.border_color = Color(0.08, 0.05, 0.03)
		sb.set_border_width_all(2)
		var sel := sb.duplicate()
		sel.border_color = UISkin.GOLD
		b.add_theme_stylebox_override("normal", sb)
		b.add_theme_stylebox_override("hover", sel)
		b.add_theme_stylebox_override("pressed", sel)
		b.add_theme_stylebox_override("focus", sel)
		b.set_meta("sel", sel)
		b.set_meta("norm", sb)
		b.pressed.connect(func(): _pick(key))
		swatches[key] = b
		row.add_child(b)
	create_btn.text = "Create"
	ConnectWindow._button_style(create_btn)
	create_btn.pressed.connect(func(): create_requested.emit(name_edit.text.strip_edges(), {"cloth": cloth}))
	row.add_child(create_btn)
	content.add_child(row)
	content.add_child(UISkin.label("Names: 3-16 letters; spaces or apostrophes inside. Up to %d characters." % Protocol.MAX_CHARACTERS, UISkin.TEXT_DIM, 11))
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	status.custom_minimum_size = Vector2(300, 0)
	content.add_child(status)
	logout_btn.text = "Log out"
	ConnectWindow._button_style(logout_btn)
	logout_btn.pressed.connect(func(): logout_requested.emit())
	content.add_child(logout_btn)
	_pick("olive")


func set_preview_source(tex: Texture2D, region: Rect2) -> void:
	_preview_tex = tex
	_preview_region = region


func _pick(key: String) -> void:
	cloth = key
	for k in swatches:
		var b: Button = swatches[k]
		b.add_theme_stylebox_override("normal", b.get_meta("sel") if k == key else b.get_meta("norm"))


func populate(characters: Array) -> void:
	for c in list.get_children():
		c.queue_free()
	enter_buttons.clear()
	if characters.is_empty():
		list.add_child(UISkin.label("No characters yet. Create one below.", UISkin.TEXT_DIM, 12))
	for ch in characters:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		if _preview_tex:
			var at := AtlasTexture.new()
			at.atlas = _preview_tex
			at.region = _preview_region
			var tr := TextureRect.new()
			tr.texture = at
			tr.custom_minimum_size = Vector2(48, 56)
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.material = Appearance.material_for(ch.get("appearance", {}))
			row.add_child(tr)
		var info := VBoxContainer.new()
		info.add_child(UISkin.label(str(ch["name"]), UISkin.GOLD, 14))
		var cl: String = ch.get("appearance", {}).get("cloth", "olive")
		var when: String = str(ch.get("last_played_at", "")).substr(0, 16).replace("T", " ") if ch.get("last_played_at") else "never"
		info.add_child(UISkin.label("%s cloth - last played %s" % [Appearance.CLOTH.get(cl, {"label": cl})["label"], when], UISkin.TEXT_DIM, 11))
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info)
		var b := Button.new()
		b.text = "Enter"
		ConnectWindow._button_style(b)
		var cid := int(ch["id"])
		b.pressed.connect(func(): enter_requested.emit(cid))
		enter_buttons[cid] = b
		row.add_child(b)
		list.add_child(row)
	create_btn.disabled = characters.size() >= Protocol.MAX_CHARACTERS
	if is_inside_tree():
		fit.call_deferred()


func set_status(text: String, bad := false) -> void:
	status.text = text
	status.add_theme_color_override("font_color", UISkin.BAD if bad else UISkin.TEXT_DIM)
