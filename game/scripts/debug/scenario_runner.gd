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
var base_zoom := 1.5


func _ready() -> void:
	shot_dir = String(main.cli.get("shot_dir", "user://scenario"))
	base_zoom = main.display.world_zoom
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
	get_viewport().push_input(ev, true)


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
	get_viewport().push_input(ev, true)


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
	get_viewport().push_input(ev, true)
	await frames(1)
	ev = ev.duplicate()
	ev.pressed = false
	get_viewport().push_input(ev, true)
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
	return main.world_px_to_screen(0, px)


## Every visible window lies fully inside the layout rect.
func windows_on_screen() -> bool:
	var v: Vector2 = main.get_viewport_rect().size
	var ok := true
	for parent in [main, main.game_ui]:
		for w in parent.get_children():
			if w is GameWindow and w.visible:
				var r := Rect2(w.position, w.size)
				if r.position.x < -0.5 or r.position.y < -0.5 or r.end.x > v.x + 0.5 or r.end.y > v.y + 0.5:
					say("   window %s at %s outside %s" % [w.title_label.text, r, v])
					ok = false
	return ok


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


## Item of `def_id` lying on the ground (the armory chest holds another sword).
func find_on_ground(def_id: String) -> int:
	for uid in main.sim.items.world_items():
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


# --- multiplayer roles (two real client processes + a dedicated server) ---------

func _wait_online(players := 2, timeout := 20.0) -> bool:
	var t0 := Time.get_ticks_msec()
	while not (main.online and main.sim.players.size() >= players):
		if Time.get_ticks_msec() - t0 > timeout * 1000.0:
			return false
		await frames(1)
	await frames(10)
	return true


func _other_actor() -> String:
	for a in main.sim.players:
		if a != main.sim.local_actor:
			return a
	return ""


func _run_mp_alice() -> void:
	check(await _wait_online(), "Alice: online with 2 players in the world")
	var sim: WorldSim = main.sim
	var ui: GameUI = main.game_ui
	var door: Interactable = sim.entities["cottage_door"]
	await walk_to(door.pos + Vector2(0.95, 0.15))
	if not door.open:
		await double_click(entity_screen("cottage_door"))
	check(await _until(func(): return door.open, 3.0), "Alice: door opened through the server")
	var sword := 0
	for uid in sim.items.world_items():
		if sim.items.item(uid).def_id == "iron_sword":
			sword = uid
	check(sword != 0, "Alice: sword visible on the ground (replicated)")
	var spos: Vector2 = sim.items.location(sword)["pos"]
	await walk_to(spos + Vector2(0.7, -0.3))
	await double_click(entity_screen("item:%d" % sword))
	check(await _until(func(): return main.sim.items.location(sword).get("container", "") == main.sim.local_actor + ".backpack", 3.0), "Alice: picked up the sword (server confirmed)")
	await frames(5)
	var slot := slot_of(ui.backpack, sword)
	if slot:
		await drag(slot_screen(slot), slot_screen(ui.equipment_win.slots[0]))
	check(await _until(func(): return main.sim.items.equipped(main.sim.local_actor, "main_hand") == sword, 3.0), "Alice: equipped the sword via drag-and-drop")
	var other := _other_actor()
	if other != "":
		await walk_to(main.sim.players[other].pos + Vector2(1.2, -0.8))
	await seconds(1.5)
	await shot("mp_alice_view")
	await seconds(6.0)   # stay so Bob can observe
	say("\nscenario %s: %d checks, %d failures" % [name_, checks, fails])
	main.quit_game(1 if fails else 0)


func _run_mp_bob() -> void:
	check(await _wait_online(), "Bob: online with 2 players in the world")
	var sim: WorldSim = main.sim
	await walk_to(sim.spawn_point + Vector2(1.5, 1.8))
	var alice := _other_actor()
	check(alice != "", "Bob: sees another player (%s)" % (sim.players[alice].display_name if alice != "" else "-"))
	check(await _until(func(): return main.sim.entities["cottage_door"].open, 20.0), "Bob: sees the door open (opened by Alice)")
	check(await _until(func(): return not main.sim.items.world_items().any(func(u): return main.sim.items.item(u).def_id == "iron_sword"), 20.0), "Bob: sees the sword disappear from the ground")
	check(await _until(func(): return main.sim.items.equipped(alice, "main_hand") != 0, 20.0), "Bob: sees the sword in Alice's hand")
	check(await _until(func(): return main.views[0].actor_views.has(alice) and main.views[0].actor_views[alice].overlay.visible, 5.0), "Bob: Alice is drawn with the weapon layer")
	await seconds(2.5)
	await shot("mp_bob_sees_alice")
	main.set_world_zoom(3.0)
	await shot("mp_bob_sees_alice_zoom3")
	say("\nscenario %s: %d checks, %d failures" % [name_, checks, fails])
	main.quit_game(1 if fails else 0)


func seconds(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _until(cond: Callable, timeout: float) -> bool:
	var t0 := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - t0 > timeout * 1000.0:
			return false
		await frames(1)
	return true


# --- Slice 005 combat walkthrough (offline world, real UI input) ---------------------

func npc_screen(id: String) -> Vector2:
	var v: WorldView = main.views[0]
	var nv: ActorSprite = v.npc_views[id]
	return main.world_px_to_screen(0, nv.position + Vector2(0, -24) * v.aset.tile_w / 64.0)


func _run_combat() -> void:
	await frames(20)
	var sim: WorldSim = main.sim
	var ui: GameUI = main.game_ui
	var armory: Interactable = sim.entities["armory_chest"]
	await walk_to(armory.pos + Vector2(0.8, 0.3))
	await double_click(entity_screen("armory_chest"))
	check(await _until(func(): return ui.chest_windows.has(armory.container_id), 3.0), "armory chest opened")
	await frames(6)
	var cw: ContainerWindow = ui.chest_windows[armory.container_id]
	var storm := 0
	for sl in cw.slots:
		if sl.uid and sim.items.item(sl.uid).def_id == "lightning_sword":
			storm = sl.uid
	await double_click(slot_screen(slot_of(cw, storm)))
	check(await _until(func(): return sim.items.equipped("player", "main_hand") == storm, 3.0), "Stormcaller equipped by double-click")
	await seconds(0.6)
	main.set_world_zoom(3.0)
	await shot("c1_stormcaller_idle")
	main.set_world_zoom(base_zoom)
	ui._open_container(armory.container_id)
	ui.chest_windows[armory.container_id].close_requested.emit()
	for wp in [Vector2(16.4, 16.8), Vector2(13.2, 22.4)]:
		await walk_to(wp)
	var wolf: NpcState = sim.npcs["n:wolf_1"]
	await walk_to(wolf.spawn + Vector2(3.0, -1.5))
	await _until(func(): return wolf.pos.distance_to(sim.player_pos) < 4.0, 4.0)
	await click(npc_screen("n:wolf_1"))
	check(main.target_id == "n:wolf_1" and main.target_win.visible, "wolf selected: target window shows it")
	await double_click(npc_screen("n:wolf_1"))
	check(sim.players["player"].combat.target == "n:wolf_1", "double-click engages the wolf")
	var got_shot := false
	var t0 := Time.get_ticks_msec()
	while not wolf.combat.dead and Time.get_ticks_msec() - t0 < 30000:
		var d: Vector2 = wolf.pos - sim.player_pos
		move_target = sim.player_pos + d * 0.5 if d.length() > 1.1 else Vector2.INF
		await frames(1)
		if not got_shot and main.views[0].fx_layer.get_children().any(func(n): return n is CombatFX.Bolt):
			got_shot = true
			await shot("c2_lightning_strike")
	move_target = Vector2.INF
	check(wolf.combat.dead, "wolf defeated")
	check(got_shot, "lightning discharge captured on screen")
	await seconds(0.8)
	await shot("c3_wolf_remains")
	var corpse := ""
	for id in sim.entities:
		if sim.entities[id].kind == "corpse":
			corpse = id
	await walk_to(sim.entities[corpse].pos + Vector2(0.7, 0.3))
	await double_click(entity_screen(corpse))
	check(await _until(func(): return ui.chest_windows.has(sim.entities[corpse].container_id), 3.0), "remains opened")
	await frames(6)
	var lw: ContainerWindow = ui.chest_windows[sim.entities[corpse].container_id]
	var pelt: int = lw.slots[0].uid
	await drag(slot_screen(lw.slots[0]), slot_screen(ui.backpack.slots[6]))
	check(sim.items.location(pelt).get("container", "") == "player.backpack", "pelt dragged into the backpack")
	await key(KEY_J)
	check(main.skills_win.visible, "skills window opens with J")
	await seconds(0.5)
	await shot("c4_loot_and_skills")
	# bow vs. the skeleton guard
	var bow := 0
	for uid in sim.items.items:
		if sim.items.item(uid).def_id == "hunting_bow":
			bow = uid
	sim.items._vacate(bow)
	sim.items._place(bow, ItemLocation.container("player.backpack", 9))
	sim.items.changed.emit()
	await double_click(slot_screen(ui.backpack.slots[9]))
	check(await _until(func(): return sim.items.equipped("player", "main_hand") == bow, 3.0), "hunting bow equipped")
	var skel: NpcState = sim.npcs["n:skeleton_1"]
	await walk_to(Vector2(16.6, 24.6))
	await walk_to(Vector2(17.2, 30.4))      # open ground, ~5 tiles from the guard post, clear line of sight
	for i in 4:      # the guard may be walking: click until the selection registers
		await click(npc_screen("n:skeleton_1"))
		if main.target_id == "n:skeleton_1":
			break
	check(main.target_id == "n:skeleton_1", "skeleton selected")
	await key(KEY_SPACE)
	check(sim.players["player"].combat.target == "n:skeleton_1", "Space attacks the selected target")
	var arrow := await _until(func(): return main.views[0].fx_layer.get_children().any(func(n): return n is CombatFX.Arrow), 6.0)
	check(arrow, "arrow in flight")
	await shot("c5_bow_vs_skeleton")
	await _until(func(): return skel.combat.dead or sim.players["player"].combat.dead, 30.0)
	# a defeat, on purpose: the bandit
	sim.players["player"].combat.hp = 3.0
	var bandit: NpcState = sim.npcs["n:bandit_1"]
	await walk_to(bandit.pos + Vector2(2.0, -1.0))
	check(await _until(func(): return sim.players["player"].combat.dead, 20.0), "the bandit defeats the player")
	await seconds(1.0)
	check(main.death_win.visible, "defeat window shown")
	await shot("c6_defeated")
	await press(main.death_win.respawn_btn)
	check(await _until(func(): return not sim.players["player"].combat.dead, 3.0), "returned to the homestead")
	await seconds(0.8)
	await shot("c7_respawned")
	say("\nscenario %s: %d checks, %d failures" % [name_, checks, fails])
	get_tree().quit(1 if fails else 0)


# --- Slice 004 Definition of Done (persistent realm, UI-driven) -------------------

func press(b: Control) -> void:
	await frames(2)
	await click(b.get_global_transform_with_canvas() * (b.size * 0.5))
	await frames(3)


func _ui_login(user: String, pw: String, register: bool) -> bool:
	var lw: LoginWindow = main.login_win
	if not await _until(func(): return lw.visible, 20.0):
		return false
	lw.user_edit.text = user
	lw.pass_edit.text = pw
	await frames(3)
	await shot("%s_login" % name_)
	if register:
		await press(lw.register_btn)
		if not await _until(func(): return lw.status.text.contains("created") or lw.status.text.contains("taken"), 8.0):
			return false
	await press(lw.login_btn)
	return await _until(func(): return main.char_win.visible and main.net.state == "account", 8.0)


func _ui_enter(char_name: String, cloth: String, create: bool) -> bool:
	var cw: CharacterWindow = main.char_win
	if create:
		cw.name_edit.text = char_name
		await press(cw.swatches[cloth])
		await shot("%s_character_create" % name_)
		await press(cw.create_btn)
		if not await _until(func(): return cw.status.text.contains("created"), 8.0):
			return false
	if not await _until(func(): return cw.enter_buttons.size() > 0, 8.0):
		return false
	await frames(5)
	await shot("%s_character_select" % name_)
	await press(cw.enter_buttons.values()[0])
	return await _wait_online(1, 10.0)


func _run_dod() -> void:
	var role: String = name_.trim_prefix("dod_")
	var me := "Alice" if role.begins_with("alice") else "Bob"
	var user := me.to_lower()
	var pw := "silver lantern 42" if me == "Alice" else "oak and iron 7"
	var first := role.ends_with("_1")
	check(await _ui_login(user, pw, first), "%s: %s via the login window" % [me, "registered and logged in" if first else "logged in"])
	check(await _ui_enter(me, "crimson" if me == "Alice" else "azure", first), "%s: %s character and entered the world" % [me, "created" if first else "selected"])
	var sim: WorldSim = main.sim
	var ui: GameUI = main.game_ui
	var my := sim.local_actor
	check(sim.players[my].appearance.get("cloth", "") == ("crimson" if me == "Alice" else "azure"), "%s: appearance is %s" % [me, sim.players[my].appearance])
	if role == "alice_1":
		var sword := 0
		for uid in sim.items.world_items():
			if sim.items.item(uid).def_id == "iron_sword":
				sword = uid
		check(sword != 0, "Alice: the sword lies on the ground")
		await walk_to(sim.items.location(sword)["pos"] + Vector2(0.7, -0.3))
		await double_click(entity_screen("item:%d" % sword))
		check(await _until(func(): return main.sim.items.location(sword).get("container", "") == my + ".backpack", 4.0), "Alice: picked up the sword")
		await frames(4)
		await drag(slot_screen(slot_of(ui.backpack, sword)), slot_screen(ui.equipment_win.slots[0]))
		check(await _until(func(): return main.sim.items.equipped(my, "main_hand") == sword, 4.0), "Alice: equipped it (drag to Main Hand)")
		await walk_to(Vector2(21.3, 12.9))
		var p: Vector2 = main.sim.player_pos
		say("SAVED_POS %.3f %.3f" % [p.x, p.y])
		await seconds(1.0)
		await shot("alice_1_equipped")
	elif role == "bob_1":
		var apples := 0
		for uid in sim.items.world_items():
			if sim.items.item(uid).def_id == "red_apple":
				apples = uid
		check(apples != 0, "Bob: apples by the trough")
		var ap: Vector2 = sim.items.location(apples)["pos"]
		await walk_to(ap + Vector2(0.6, 0.6))
		await double_click(entity_screen("item:%d" % apples))
		check(await _until(func(): return main.sim.items.location(apples).get("container", "") == my + ".backpack", 4.0), "Bob: picked up the apples")
		var door: Interactable = sim.entities["cottage_door"]
		await walk_to(ap + Vector2(2.2, -0.6))
		await walk_to(Vector2(16.4, 13.6))
		await walk_to(door.pos + Vector2(0.95, 0.1))
		if not door.open:
			await double_click(entity_screen("cottage_door"))
		check(await _until(func(): return main.sim.entities["cottage_door"].open, 4.0), "Bob: door open")
		await walk_to(door.pos + Vector2(0.2, 0.0))
		await walk_to(door.pos + Vector2(-0.85, 0.0))
		var chest: Interactable = sim.entities["cottage_chest"]
		await walk_to(chest.pos + Vector2(0.95, 0.35))
		await double_click(entity_screen("cottage_chest"))
		check(await _until(func(): return ui.chest_windows.has(chest.container_id), 4.0), "Bob: chest window open")
		await frames(10)
		var cw: ContainerWindow = ui.chest_windows[chest.container_id]
		await drag(slot_screen(slot_of(ui.backpack, apples)), slot_screen(cw.slots[7]))
		check(await _until(func(): return main.sim.items.occupant(ItemLocation.container(chest.container_id, 7)) == apples, 4.0), "Bob: deposited the apples in the chest (slot 8)")
		await seconds(1.0)
		await shot("bob_1_deposited")
	elif role == "alice_2":
		var exp: PackedStringArray = String(main.cli.get("expect_pos", "0,0")).split(",")
		var want := Vector2(float(exp[0]), float(exp[1]))
		check(main.sim.player_pos.distance_to(want) < 0.1, "Alice: back where she logged out (%.2f, %.2f)" % [main.sim.player_pos.x, main.sim.player_pos.y])
		check(await _until(func(): return main.sim.items.equipped(my, "main_hand") != 0, 4.0), "Alice: the sword is still equipped after the server restart")
		check(ui.equipment_win.slots[0].uid != 0, "Alice: equipment window shows it")
		check(await _until(func(): return main.sim.players.size() >= 2, 25.0), "Alice: Bob is in the world too")
		var bob := _other_actor()
		check(main.sim.items.containers.has(bob + ".backpack") == false or main.sim.items.containers[bob + ".backpack"].used() == 0, "Alice: cannot see Bob's backpack contents")
		await seconds(2.0)
		await shot("alice_2_after_restart")
		await seconds(6.0)
	elif role == "bob_2":
		var chest: Interactable = sim.entities["cottage_chest"]
		check(main.sim.player_pos.distance_to(chest.pos) < 2.0, "Bob: back beside the chest where he left")
		await double_click(entity_screen("cottage_chest"))
		check(await _until(func(): return ui.chest_windows.has(chest.container_id), 4.0), "Bob: chest opened")
		var apples_ok := await _until(func():
			var u: int = main.sim.items.occupant(ItemLocation.container(chest.container_id, 7))
			return u != 0 and main.sim.items.item(u).def_id == "red_apple", 4.0)
		check(apples_ok, "Bob: his apples are still in the chest after the restart")
		check(await _until(func(): return main.sim.players.size() >= 2, 20.0), "Bob: Alice is in the world")
		var alice := _other_actor()
		check(await _until(func(): return main.sim.items.equipped(alice, "main_hand") != 0, 6.0), "Bob: sees Alice's sword")
		await walk_to(chest.pos + Vector2(1.6, 0.3))
		await seconds(1.5)
		await shot("bob_2_after_restart")
	# leave the world through the UI, then log out
	main.connect_win.visible = true
	main.connect_win.leave_world_btn.visible = true
	await press(main.connect_win.leave_world_btn)
	check(await _until(func(): return main.char_win.visible and main.net.state == "account", 6.0), "%s: left the world (character selection)" % me)
	await press(main.char_win.logout_btn)
	check(await _until(func(): return main.login_win.visible and main.net.state == "login", 6.0), "%s: logged out" % me)
	say("\nscenario %s: %d checks, %d failures" % [name_, checks, fails])
	main.quit_game(1 if fails else 0)


func wheel(at: Vector2, up: bool) -> void:
	await mouse_to(at, 2)
	_button(true, false, MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN)
	await frames(1)
	_button(false, false, MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN)
	await frames(3)


## An interactable or ground item whose pick point is on screen and not under
## any window or HUD panel ("" if none).
func visible_entity() -> String:
	var ids: Array = ["cottage_door", "cottage_chest", "armory_chest"]
	for uid in main.sim.items.world_items():
		ids.append("item:%d" % uid)
	var view: Rect2 = main.get_viewport_rect().grow(-20)
	for id in ids:
		var p := entity_screen(id)
		if not view.has_point(p):
			continue
		var covered := false
		for c in main.get_children() + main.game_ui.get_children():
			if c is Control and c.visible and (c is GameWindow or c is PanelContainer) and c.get_global_rect().grow(6).has_point(p):
				covered = true
		if not covered:
			return id
	return ""


## Hover an entity through real mouse motion; true if the world picked it.
func hover_ok(id: String) -> bool:
	await mouse_to(entity_screen(id) + Vector2(3, 1), 4)
	await frames(2)
	return main.hovered_id == id


## Corrective directive "Game scale & readability": world zoom and interface
## size through real input, independence of the two, picking and drag-and-drop
## at several scales, window resize, reset.
func _run_display() -> void:
	await frames(20)
	var sim: WorldSim = main.sim
	var ui: GameUI = main.game_ui
	var v: WorldView = main.views[0]
	var win := get_window()
	var os_s := DisplaySettings.os_scale()
	var expect_ui: float = main.display.auto_ui_scale()
	say("window %s, screen %s points, os scale %.2f, layout %s" % [win.size, DisplaySettings.screen_points(), os_s, main.get_viewport_rect().size])
	check(is_equal_approx(main.display.world_zoom, 1.5) and is_equal_approx(v.camera.zoom.x, 1.5 * os_s), "D1 default world zoom 1.5x (camera %.2f)" % v.camera.zoom.x)
	check(is_equal_approx(win.content_scale_factor, minf(expect_ui * os_s, win.size.y / 540.0)), "D1 interface size %d%% for this screen (factor %.2f)" % [roundi(expect_ui * 100), win.content_scale_factor])
	var char_px := 72.0 * v.camera.zoom.x
	check(char_px >= 100.0 and char_px <= 120.0, "D1 character is %d screen px tall at the default zoom" % roundi(char_px))
	var vp_size: Vector2 = Vector2(main._vp(0).size)
	check(vp_size.distance_to(Vector2(win.size)) < 2.0, "D1 world renders at the full window resolution (%s for window %s)" % [vp_size, win.size])
	check(windows_on_screen(), "D1 all windows inside the view")
	await shot("d1_default")

	# --- world zoom with the mouse wheel; interface unaffected
	var factor0: float = win.content_scale_factor
	var label_h0: float = ui.backpack.size.y
	var mid: Vector2 = main.get_viewport_rect().size * Vector2(0.45, 0.6)
	await wheel(mid, true)
	check(is_equal_approx(main.display.world_zoom, 1.75), "D2 wheel up zooms in to 1.75x")
	await wheel(mid, true)
	await wheel(mid, true)
	check(is_equal_approx(main.display.world_zoom, 2.0), "D2 zoom stops at 2.0x")
	check(win.content_scale_factor == factor0 and ui.backpack.size.y == label_h0, "D2 world zoom leaves the interface size alone")
	check(await hover_ok("cottage_door"), "D2 hover picks the door at 2.0x")
	await shot("d2_zoom_2")
	for i in 5:
		await wheel(mid, false)
	check(is_equal_approx(main.display.world_zoom, 1.0), "D2 zoom stops at 1.0x")
	check(await hover_ok("cottage_chest"), "D2 hover picks the chest at 1.0x")
	await shot("d2_zoom_1")

	# --- settings window through clicks
	await key(KEY_O)
	var sw: SettingsWindow = main.settings_win
	check(sw.visible, "D3 O opens the settings window")
	await press(sw.zoom_plus)
	await press(sw.zoom_plus)
	check(is_equal_approx(main.display.world_zoom, 1.5), "D3 zoom + button (1.0 -> 1.5)")
	await press(sw.ui_buttons[2.0])
	check(is_equal_approx(win.content_scale_factor, minf(2.0 * os_s, win.size.y / 540.0)), "D3 200%% button sets the interface factor (%.2f)" % win.content_scale_factor)
	check(is_equal_approx(v.camera.zoom.x, 1.5 * os_s), "D3 interface size leaves the world zoom alone")
	check(Vector2(main._vp(0).size).distance_to(Vector2(win.size)) < 2.0, "D3 world still renders at full window resolution")
	check(windows_on_screen(), "D3 all windows inside the view at 200%")
	var bp_r := Rect2(ui.backpack.position, ui.backpack.size)
	var eq_r := Rect2(ui.equipment_win.position, ui.equipment_win.size)
	check(not bp_r.intersects(eq_r), "D3 backpack and equipment do not overlap at 200%")
	await shot("d3_ui_200")
	# picking and drag-and-drop at 200%
	await key(KEY_O)
	var vis := visible_entity()
	check(vis != "" and await hover_ok(vis), "D4 hover picks %s at 200%% interface" % vis)
	var apples := find_on_ground("red_apple")
	var ap: Vector2 = sim.items.location(apples)["pos"]
	await walk_to(ap + Vector2(0.6, 0.6))
	await drag(entity_screen("item:%d" % apples), slot_screen(ui.backpack.slots[2]))
	check(sim.items.location(apples).get("container", "") == "player.backpack" and int(sim.items.location(apples).get("slot", -1)) == 2, "D4 drag from the ground into backpack slot 3 lands exactly there at 200%")
	await drag(slot_screen(ui.backpack.slots[2]), slot_screen(ui.backpack.slots[9]))
	check(int(sim.items.location(apples).get("slot", -1)) == 9, "D4 drag between backpack slots at 200%")
	# 125% (non-integer) too
	main.set_ui_scale(1.25)
	await frames(4)
	await drag(slot_screen(ui.backpack.slots[9]), slot_screen(ui.backpack.slots[0]))
	check(int(sim.items.location(apples).get("slot", -1)) == 0, "D4 drag between backpack slots at 125%")
	var drop1: Vector2 = sim.player_pos + Vector2(0.8, -0.5)
	await drag(slot_screen(ui.backpack.slots[0]), main.world_to_screen(drop1))
	var l1: Dictionary = sim.items.location(apples)
	check(l1.get("kind", "") == "world" and (l1["pos"] as Vector2).distance_to(drop1) < 0.35, "D4 drop onto the ground lands under the cursor at 125%")
	check(await hover_ok("item:%d" % apples), "D4 hover picks the dropped apples at 125%")
	await drag(entity_screen("item:%d" % apples), slot_screen(ui.backpack.slots[0]))
	check(int(sim.items.location(apples).get("slot", -1)) == 0, "D4 drag them back into backpack slot 1 at 125%")
	await shot("d4_ui_125")

	# --- small window: interface reduced to fit, nothing off screen
	main.set_ui_scale(2.0)
	var big := win.size
	win.size = Vector2i(1280, 720)
	await frames(8)
	check(main.get_viewport_rect().size.y >= 539.0, "D5 1280x720 window at 200%%: layout keeps %d points of height" % roundi(main.get_viewport_rect().size.y))
	check(windows_on_screen(), "D5 all windows inside the 1280x720 window")
	check(Vector2(main._vp(0).size).distance_to(Vector2(win.size)) < 2.0, "D5 world follows the window size")
	var drop_at: Vector2 = sim.player_pos + Vector2(0.9, 0.4)
	await drag(slot_screen(ui.backpack.slots[0]), main.world_to_screen(drop_at))
	var loc: Dictionary = sim.items.location(apples)
	check(loc.get("kind", "") == "world" and (loc["pos"] as Vector2).distance_to(drop_at) < 0.35, "D5 drop onto the ground lands where the cursor is (%s vs %s)" % [loc.get("pos"), drop_at])
	check(await hover_ok("item:%d" % apples), "D5 hover picks the dropped apples after the resize")
	await shot("d5_small_window")
	win.size = big
	await frames(8)

	# --- reset
	await key(KEY_O)
	await press(sw.zoom_plus)
	await press(sw.reset_btn)
	check(is_equal_approx(main.display.world_zoom, 1.5) and is_equal_approx(main.display.ui_scale, expect_ui), "D6 Reset to default: zoom 1.5x, interface %d%%" % roundi(expect_ui * 100))
	check(is_equal_approx(win.content_scale_factor, minf(expect_ui * os_s, win.size.y / 540.0)), "D6 reset applied to the window")
	await shot("d6_reset")
	check(not FileAccess.file_exists(main.display.path) or not main.display.persist, "D6 automated run did not write the player's preferences")
	say("\nscenario %s: %d checks, %d failures" % [name_, checks, fails])
	get_tree().quit(1 if fails else 0)


func _abort(why: String) -> void:
	check(false, "ABORT: " + why)
	say("\nscenario %s: %d checks, %d failures (aborted)" % [name_, checks, fails])
	get_tree().quit(1)


# --- the run ---------------------------------------------------------------------

func _run() -> void:
	if name_.begins_with("dod_"):
		await _run_dod()
		return
	if name_ == "combat":
		await _run_combat()
		return
	if name_ == "display":
		await _run_display()
		return
	if name_ == "mp_alice":
		await _run_mp_alice()
		return
	if name_ == "mp_bob":
		await _run_mp_bob()
		return
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
	var sword := find_on_ground("iron_sword")
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
	main.set_world_zoom(3.0)
	await shot("07_equipped")
	main.set_world_zoom(base_zoom)

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
	var ui0: float = main.display.ui_scale
	var ui1 := 2.0 if ui0 < 1.75 else 1.0
	main.set_ui_scale(ui1)
	await frames(4)
	await shot("10_ui_scale_%d" % roundi(ui1 * 100))
	check(windows_on_screen(), "T07 all windows inside the view at %d%% interface size" % roundi(main.ui_factor * 100))
	main.set_ui_scale(ui0)
	await frames(4)
	check(windows_on_screen(), "T07 all windows inside the view after returning to %d%%" % roundi(ui0 * 100))

	check(totals() == before, "ALL item totals conserved across the run")
	check(store.check_invariants().is_empty(), "ALL ownership invariants hold")
	say("\nscenario %s: %d checks, %d failures" % [name_, checks, fails])
	get_tree().quit(1 if fails else 0)
