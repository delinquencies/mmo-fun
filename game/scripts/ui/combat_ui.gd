class_name CombatUI
## Combat windows in the existing leather / parchment style.


class Bar extends Control:
	var value := 1.0
	var max_value := 1.0
	var fill := Color(0.7, 0.15, 0.12)
	var caption := ""

	func _init(p_fill: Color, p_caption: String, w := 150) -> void:
		fill = p_fill
		caption = p_caption
		custom_minimum_size = Vector2(w, 14)
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func set_values(v: float, m: float) -> void:
		if v != value or m != max_value:
			value = v
			max_value = m
			queue_redraw()

	func _draw() -> void:
		var r := Rect2(Vector2.ZERO, size)
		draw_rect(r, Color(0.06, 0.04, 0.03))
		draw_rect(r.grow(-1), Color(0.18, 0.12, 0.08))
		var k := clampf(value / maxf(max_value, 1.0), 0.0, 1.0)
		var fr := Rect2(Vector2(2, 2), Vector2((size.x - 4) * k, size.y - 4))
		draw_rect(fr, fill)
		draw_rect(Rect2(fr.position, Vector2(fr.size.x, 2)), fill.lightened(0.35))
		draw_rect(r, Color(0.55, 0.42, 0.24), false, 1.0)
		var font := get_theme_default_font()
		var txt := "%s  %d / %d" % [caption, roundi(value), roundi(max_value)]
		draw_string_outline(font, Vector2(6, size.y - 3), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, 3, Color(0.05, 0.03, 0.02))
		draw_string(font, Vector2(6, size.y - 3), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UISkin.TEXT)


class VitalsWindow extends GameWindow:
	var hp := Bar.new(Color(0.62, 0.12, 0.1), "Health")
	var st := Bar.new(Color(0.55, 0.5, 0.18), "Stamina")
	var mn := Bar.new(Color(0.16, 0.32, 0.62), "Mana")
	var status := UISkin.label("", UISkin.TEXT_DIM, 11)

	func _init() -> void:
		super("Vitals")
		for b in [hp, st, mn]:
			content.add_child(b)
		content.add_child(status)

	func refresh(c: Combatant, engaged: String) -> void:
		if c == null:
			return
		hp.set_values(c.hp, c.hp_max)
		st.set_values(c.st, c.st_max)
		mn.set_values(c.mn, c.mn_max)
		var t := "Defeated" if c.dead else ("Fighting %s" % engaged if engaged != "" else "At peace")
		if c.has_status("shocked"):
			t += "  (shocked)"
		status.text = t


class TargetWindow extends GameWindow:
	var name_l := UISkin.label("", UISkin.GOLD, 13)
	var kind_l := UISkin.label("", UISkin.TEXT_DIM, 11)
	var hp := Bar.new(Color(0.62, 0.12, 0.1), "Health", 170)

	func _init() -> void:
		super("Target")
		content.add_child(name_l)
		content.add_child(kind_l)
		content.add_child(hp)

	func show_target(nm: String, hostile: bool, c: Combatant, engaged: bool) -> void:
		name_l.text = nm
		name_l.add_theme_color_override("font_color", UISkin.BAD if hostile else Color(0.6, 0.9, 0.5))
		var state := "dead" if c and c.dead else ("engaged" if engaged else ("hostile - double-click or Space to attack" if hostile else "friendly"))
		kind_l.text = state
		if c:
			hp.set_values(c.hp, c.hp_max)


class SkillsWindow extends GameWindow:
	var rows: Dictionary = {}

	func _init() -> void:
		super("Skills")

	func refresh(skills: Dictionary, names: Dictionary, highlight := "") -> void:
		for k in skills:
			if not rows.has(k):
				var l := UISkin.label("", UISkin.TEXT, 12)
				content.add_child(l)
				rows[k] = l
			rows[k].text = "%-14s %5.1f" % [names.get(k, k), float(skills[k])]
			rows[k].add_theme_color_override("font_color", UISkin.GOLD if k == highlight else UISkin.TEXT)
		if is_inside_tree():
			fit()


class DeathWindow extends GameWindow:
	var respawn_btn := Button.new()

	func _init() -> void:
		super("Defeated")
		content.add_child(UISkin.label("You have fallen. Your belongings are safe.", UISkin.TEXT, 13))
		content.add_child(UISkin.label("Return to the homestead shrine to recover.", UISkin.TEXT_DIM, 11))
		respawn_btn.text = "Return to the homestead"
		ConnectWindow._button_style(respawn_btn)
		content.add_child(respawn_btn)
