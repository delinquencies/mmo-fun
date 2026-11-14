extends Node
## Scripted acceptance run through the *real* input path: synthetic mouse and
## keyboard events go through Input -> GUI -> WorldSurface / ItemSlot -> commands.
##   godot --path game -- --scenario=acceptance --shot_dir=/tmp/shots
## Prints PASS/FAIL per check and exits with code 0 when everything passed.

var main: Node
var name_ := "acceptance"
var move_target := Vector2.INF
var shot_dir := ""
var fails := 0
var checks := 0
var P := WorldSim.PLAYER_ID


func _ready() -> void:
	shot_dir = String(main.cli.get("shot_dir", "user://scenario"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(shot_dir))
	_run.call_deferred()


var _log: FileAccess


func say(t: String) -> void:
	print(t)
	if _log == null:
		_log = FileAccess.open("%s/scenario.log" % shot_dir, FileAccess.WRITE)
	_log.store_line(t)
	_log.flush()


func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		fails += 1
	say("%s  %s" % ["PASS" if cond else "FAIL", what])


func frames(n := 1) -> void:
	for i in n:
		await get_tree().process_frame


func shot(tag: String) -> void:
	await frames(2)
	say("-- step: %s  (player %.2f, %.2f)" % [tag, main.sim.player_pos.x, main.sim.player_pos.y])
	if DisplayServer.get_name() != "headless":
		main._screenshot("%s/%s.png" % [shot_dir, tag])


# --- synthetic input ---------------------------------------------------------

var _mouse := Vector2(10, 10)
var _mask := 0


func _motion(to: Vector2) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = to
	ev.global_position = to
	ev.relative = to - _mouse
	ev.button_mask = _mask
	_mouse = to
	get_viewport().push_input(ev)


func mouse_to(to: Vector2, steps := 6) -> void:
	var from := _mouse
	for i in steps:
		_motion(from.lerp(to, float(i + 1) / steps))
		await frames(1)


func _button(pressed: bool, double := false, button := MOUSE_BUTTON_LEFT) -> void:
	var ev := InputEventMouseButton.new()
	ev.position = _mouse
	ev.global_position = _mouse
	ev.button_index = button
	ev.pressed = pressed
	ev.double_click = double
	if pressed:
		_mask |= (1 << (button - 1))
	else:
		_mask &= ~(1 << (button - 1))
	ev.button_mask = _mask
	get_viewport().push_input(ev)


func click(at: Vector2) -> void:
	await mouse_to(at, 3)
	_button(true)
	await frames(1)
	_button(false)
	await frames(2)


func double_click(at: Vector2) -> void:
	await click(at)
	_button(true, true)
	await frames(1)
	_button(false)
	await frames(3)


func drag(from: Vector2, to: Vector2) -> void:
	await mouse_to(from, 3)
	_button(true)
	await frames(1)
	await mouse_to(from + Vector2(14, 6), 4)
	await mouse_to(to, 10)
	await frames(2)
	_button(false)
	await frames(4)


func key(code: Key) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	ev.pressed = true
	get_viewport().push_input(ev)
	await frames(1)
	ev = ev.duplicate()
	ev.pressed = false
	get_viewport().push_input(ev)
	await frames(2)


func walk_to(target: Vector2, timeout := 8.0) -> void:
	move_target = target
	var t := 0.0
	while main.sim.player_pos.distance_to(target) > 0.08 and t < timeout:
		await frames(1)
		t += get_process_delta_time()
	move_target = Vector2.INF
	await frames(2)


# --- lookups -------------------------------------------------------------------

func entity_screen(id: String) -> Vector2:
	var v: WorldView = main.views[0]
	var px := v.pick_point(id)
	var vp: SubViewport = main.cells[0].get_child(0).get_child(0)
	return main.cells[0].global_position + vp.get_canvas_transform() * px


func slot_screen(s: ItemSlot) -> Vector2:
	return s.get_global_transform_with_canvas() * (s.size * 0.5)


func slot_of(win: ContainerWindow, uid: int) -> ItemSlot:
	for s in win.slots:
		if s.uid == uid:
			return s
	return null


func find(def_id: String) -> int:
	for uid in main.sim.items.items:
		if main.sim.items.items[uid].def_id == def_id:
			return uid
	return 0


func totals() -> Dictionary:
	var t := {}
	for d in main.sim.items.defs:
		t[d] = main.sim.items.total_quantity(d)
	return t


func journal_has(text: String) -> bool:
	for l in main.journal.get_children():
		if (l as Label).text.contains(text):
			return true
	return false


func _abort(why: String) -> void:
	check(false, "ABORT: " + why)
	say("\nscenario %s: %d checks, %d failures (aborted)" % [name_, checks, fails])
	get_tree().quit(1)


# --- the run ---------------------------------------------------------------------

func _run() -> void:
	await frames(20)
	var sim: WorldSim = main.sim
	var ui: GameUI = main.game_ui
	var store := sim.items
	var before := totals()
	var door: Interactable = sim.entities["cottage_door"]
	var chest: Interactable = sim.entities["cottage_chest"]
	await shot("00_start")
	var dp := entity_screen("cottage_door")
	say("debug: vp=%s main=%s cell0=%s door_screen=%s pick=%s surface=%s" % [get_viewport().get_visible_rect().size, main.size, main.cells[0].size, dp, main.pick_at(dp), main.surface.size])

	# ---------------- Test 01: door ----------------
	await walk_to(door.pos + Vector2(2.6, 0.4))
	await mouse_to(entity_screen("cottage_door"))
	await frames(2)
	check(main.hovered_id == "cottage_door", "T01 hover detects the door")
	check(main.surface.mouse_default_cursor_shape == Control.CURSOR_MOVE, "T01 out-of-range cursor while 2.6 tiles away")
	await double_click(entity_screen("cottage_door"))
	check(not door.open, "T01 door refuses to open from out of range")
	await walk_to(door.pos + Vector2(0.95, 0.15))
	await mouse_to(entity_screen("cottage_door"))
	await frames(2)
	check(main.surface.mouse_default_cursor_shape == Control.CURSOR_POINTING_HAND, "T01 use cursor in range")
	await shot("01_door_hover")
	await double_click(entity_screen("cottage_door"))
	check(door.open, "T01 double-click opens the door")
	check(main.audio.last_played == "door_open" or journal_has("swings open"), "T01 door open feedback")
	await frames(10)
	await shot("02_door_open")
	await walk_to(door.pos + Vector2(-0.8, 0.0))
	check(sim.player_pos.x < door.pos.x - 0.6, "T01 walked through the open doorway")

	# ---------------- Test 04: chest transfer ----------------
	await walk_to(chest.pos + Vector2(0.8, 0.45))
	await double_click(entity_screen("cottage_chest"))
	check(ui.chest_windows.has(chest.container_id), "T04 chest window opened")
	check(chest.open, "T04 chest lid open")
	await frames(10)
	await shot("03_chest_open")
	if not ui.chest_windows.has(chest.container_id):
		return _abort("chest window never opened")
	var cw: ContainerWindow = ui.chest_windows[chest.container_id]
	var apples := find("red_apple")
	await drag(slot_screen(slot_of(cw, apples)), slot_screen(ui.backpack.slots[0]))
	check(store.location(apples).get("container", "") == "player.backpack", "T04 dragged apples chest -> backpack")
	await shot("04_apples_in_backpack")
	await drag(slot_screen(ui.backpack.slots[0]), slot_screen(cw.slots[5]))
	var loc := store.location(apples)
	check(loc.get("container", "") == "cottage_chest.contents" and int(loc["slot"]) == 5, "T04 dragged apples back into chest slot 6")
	check(totals() == before, "T04 nothing duplicated or lost")

	# ---------------- Test 06: rapid input ----------------
	var coins := find("gold_coins")
	var cs := slot_of(cw, coins)
	for i in 6:
		await double_click(slot_screen(cs))
	check(store.location(coins).get("container", "") == "player.backpack", "T06 coins moved once by rapid double-clicks")
	check(totals() == before and store.check_invariants().is_empty(), "T06 no duplication after 6 rapid double-clicks")
	var bs := slot_of(ui.backpack, coins)
	await drag(slot_screen(bs), slot_screen(cw.slots[0]))
	await drag(slot_screen(bs), slot_screen(cw.slots[1]))   # stale second drag from the now-empty slot
	check(store.location(coins).get("container", "") == "cottage_chest.contents", "T06 coins back in chest")
	check(totals() == before and store.check_invariants().is_empty(), "T06 repeated drags conserve items")

	# ---------------- leave the cottage, close the door ----------------
	await walk_to(door.pos + Vector2(-0.7, 0.0))
	await walk_to(door.pos + Vector2(1.0, 0.0))
	check(not ui.chest_windows.has(chest.container_id), "T07 chest window closes when walking away")
	await double_click(entity_screen("cottage_door"))
	check(not door.open, "T01 door closed again from outside")
	check(sim.is_blocked(door.pos + Vector2(-0.15, 0), WorldSim.PLAYER_RADIUS), "T01 closed door blocks the doorway again")

	# ---------------- Test 05: distant chest ----------------
	await double_click(entity_screen("cottage_chest"))
	check(not chest.open and not ui.chest_windows.has(chest.container_id), "T05 distant chest does not open")
	check(journal_has("too far"), "T05 'too far away' feedback shown")
	check(main.audio.last_played == "invalid", "T05 invalid sound event")
	await shot("05_too_far")

	# ---------------- Test 02: pick up sword ----------------
	var sword := find("iron_sword")
	var spos: Vector2 = store.location(sword)["pos"]
	await walk_to(spos + Vector2(0.7, -0.2))
	await mouse_to(entity_screen("item:%d" % sword))
	await frames(2)
	check(main.hovered_id == "item:%d" % sword, "T02 hover detects the sword on the ground")
	await shot("06_sword_on_ground")
	await drag(entity_screen("item:%d" % sword), slot_screen(ui.backpack.slots[4]))
	loc = store.location(sword)
	check(loc.get("container", "") == "player.backpack" and int(loc["slot"]) == 4, "T02 dragged sword from ground into backpack slot 5")
	check(not store.world_items().has(sword) and main.views[0].ground_views.get(sword) == null, "T02 sword sprite removed from world")

	# ---------------- Test 03: equip ----------------
	await drag(slot_screen(ui.backpack.slots[4]), slot_screen(ui.equipment_win.slots[0]))
	check(store.equipped(P, "main_hand") == sword, "T03 sword equipped in main hand")
	check(ui.backpack.slots[4].uid == 0 and ui.equipment_win.slots[0].uid == sword, "T03 UI reflects backpack/equipment state")
	await frames(3)
	check(main.views[0].player.overlay.visible and main.views[0].player.overlay_id == "iron_sword", "T03 weapon layer visible on the character")
	main.zoom_i = 4
	main._apply_view_settings()
	await shot("07_equipped")
	main.zoom_i = 3
	main._apply_view_settings()

	# ---------------- Test 05: invalid destinations ----------------
	await walk_to(door.pos + Vector2(0.95, 0.15))
	await double_click(entity_screen("cottage_door"))
	await walk_to(door.pos + Vector2(-0.8, 0.0))
	await walk_to(chest.pos + Vector2(0.8, 0.45))
	await double_click(entity_screen("cottage_chest"))
	if not ui.chest_windows.has(chest.container_id):
		return _abort("chest window did not reopen")
	cw = ui.chest_windows[chest.container_id]
	var potion := find("healing_potion")
	await drag(slot_screen(slot_of(cw, potion)), slot_screen(ui.equipment_win.slots[1]))
	check(store.location(potion).get("container", "") == "cottage_chest.contents", "T05 off-hand (reserved) refused, potion stays in chest")
	check(journal_has("not yet available"), "T05 reserved-slot feedback")
	await drag(slot_screen(slot_of(cw, potion)), slot_screen(ui.equipment_win.slots[0]))
	check(store.location(potion).get("container", "") == "cottage_chest.contents", "T05 potion cannot replace the sword in main hand")
	check(store.equipped(P, "main_hand") == sword, "T05 sword still equipped")
	await shot("08_invalid_drop")

	# ---------------- Definition of done: drop it back into the world ----------------
	await walk_to(door.pos + Vector2(-0.7, 0.0))
	await walk_to(door.pos + Vector2(1.4, 0.3))
	var ground: Vector2 = main.world_to_screen(sim.player_pos + Vector2(0.9, 0.6))
	await drag(slot_screen(ui.equipment_win.slots[0]), ground)
	check(store.location(sword).get("kind", "") == "world", "DoD dragged sword from hand onto the ground")
	check(store.equipped(P, "main_hand") == 0 and not main.views[0].player.overlay.visible, "DoD hand empty, weapon layer gone")
	await frames(3)
	check(main.views[0].ground_views.has(sword), "DoD sword sprite back in the world")
	await shot("09_dropped")

	# ---------------- Test 07: windows ----------------
	var bp: ContainerWindow = ui.backpack
	var p0 := bp.position
	var bar := bp.get_global_transform_with_canvas() * Vector2(40, 16)
	main.scenario.move_target = sim.player_pos + Vector2(2.0, 1.0)
	var walk_start := sim.player_pos
	await drag(bar, bar + Vector2(-420, 60))
	check(bp.position.distance_to(p0) > 100, "T07 backpack window dragged by its title bar")
	check(sim.player_pos.distance_to(walk_start) > 0.3, "T07 character kept walking while a window was dragged")
	move_target = Vector2.INF
	var close_btn := bp._close.get_global_transform_with_canvas() * (bp._close.size * 0.5)
	await click(close_btn)
	check(not bp.visible, "T07 backpack closed with its close button")
	await key(KEY_I)
	check(bp.visible, "T07 backpack reopened with I")
	await key(KEY_P)
	check(not ui.equipment_win.visible, "T07 equipment toggled closed with P")
	await key(KEY_P)
	check(ui.equipment_win.visible, "T07 equipment reopened")
	main.set_ui_scale(1.5)
	await frames(3)
	await shot("10_ui_scale_1_5")
	main.set_ui_scale(1.0)

	check(totals() == before, "ALL item totals conserved across the run")
	check(store.check_invariants().is_empty(), "ALL ownership invariants hold")
	say("\nscenario %s: %d checks, %d failures" % [name_, checks, fails])
	get_tree().quit(1 if fails else 0)
