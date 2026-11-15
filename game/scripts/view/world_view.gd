class_name WorldView
extends Node2D
## Presentation of a WorldSim using one AssetSet. Several views can render the
## same sim at once (resolution comparison mode).

var sim: WorldSim
var aset: AssetSet
var camera := Camera2D.new()
var entities := Node2D.new()      # y-sorted props + actors
var shadows := CanvasGroup.new()  # merged so overlapping shadows don't double-darken
var overlay: DebugOverlay
var player: ActorSprite                 # the local character (camera target)
var actor_views: Dictionary = {}        # actor id -> ActorSprite (every character)
var sheep_views: Array[ActorSprite] = []
var trees: Array = []            # tree canopies fade when they hide the local player
var buildings: Array = []         # [BuildingSprite, world pos, footprint]
var show_energy := false          # E: preview the reusable blade-energy effect on a held weapon
var entity_views: Dictionary = {} # entity id -> {node, shadow, meta, frame}
var ground_views: Dictionary = {} # item uid -> {node, shadow, meta}
var hovered := ""
var selected := ""
var drop_marker := DropMarker.new()
# Slice 005 combat presentation
var npc_views: Dictionary = {}    # npc id -> ActorSprite
var fx_layer := Node2D.new()
var target_ring := CombatFX.Ring.new()
var target_id := ""
var present: Dictionary = {}      # entity id -> {"swing": t, "flash": t, "dead_at": t}
var _pick_images: Dictionary = {} # texture file -> Image (for pixel-accurate picking)


func setup(world_sim: WorldSim, asset_set: AssetSet) -> void:
	sim = world_sim
	aset = asset_set
	var tw := aset.tile_w
	for gl in GroundLayer.build(sim, aset):
		gl.z_index = -20
		add_child(gl)
	shadows.z_index = -10
	shadows.self_modulate = Color(0.02, 0.06, 0.1, 0.42)
	add_child(shadows)
	entities.y_sort_enabled = true
	add_child(entities)

	for p in sim.props:
		var type: String = p["type"]
		var meta := aset.sprite(type)
		if meta.is_empty():
			push_warning("no sprite for %s in %s" % [type, aset.id])
			continue
		var tex := aset.texture(meta["file"])
		var pivot := Vector2(meta["pivot"][0], meta["pivot"][1])
		var pos := Iso.to_screen(p["pos"], tw)
		var sh := Sprite2D.new()
		sh.texture = aset.texture(meta["shadow"])
		sh.centered = false
		sh.offset = -pivot
		sh.position = pos
		shadows.add_child(sh)
		var def: Dictionary = sim.prop_defs.get(type, {})
		var node: Node2D
		if def.get("sort", "point") == "footprint":
			var fp: Array = def["footprint"]
			var b := BuildingSprite.new()
			b.setup(tex, pivot, Rect2(fp[0], fp[1], fp[2] - fp[0], fp[3] - fp[1]), tw)
			node = b
			buildings.append({"node": b, "rect": Rect2(-pivot, tex.get_size()), "fp": fp, "pos": p["pos"]})
		else:
			var s := Sprite2D.new()
			s.texture = tex
			s.centered = false
			s.offset = -pivot
			node = s
		node.position = pos
		node.name = type
		entities.add_child(node)
		if type.begins_with("tree"):
			trees.append({"node": node, "rect": Rect2(-pivot, tex.get_size()), "pos": p["pos"]})
		_add_effects(node, type, meta)

	for id in sim.entities:
		_add_entity_view(sim.entities[id])

	for s in sim.sheep:
		var sv := ActorSprite.new()
		sv.setup(aset, "sheep")
		entities.add_child(sv)
		shadows.add_child(sv.shadow)
		sheep_views.append(sv)

	_sync_actors()
	drop_marker.tile_w = tw
	drop_marker.z_index = -5
	add_child(drop_marker)
	target_ring.tile_w = tw
	target_ring.z_index = -6
	target_ring.visible = false
	add_child(target_ring)
	fx_layer.z_index = 6
	add_child(fx_layer)

	overlay = DebugOverlay.new()
	overlay.view = self
	overlay.z_index = 100
	add_child(overlay)

	camera.position_smoothing_enabled = false
	add_child(camera)
	sync(0.0)


func _add_effects(node: Node2D, type: String, meta: Dictionary) -> void:
	var anchors: Dictionary = meta.get("anchors", {})
	if anchors.has("chimney_top"):
		node.add_child(Effects.chimney_smoke(Vector2(anchors["chimney_top"][0], anchors["chimney_top"][1]), aset.tile_w))
	if anchors.has("flame"):
		node.add_child(Effects.brazier_flame(Vector2(anchors["flame"][0], anchors["flame"][1]), aset.tile_w))


func _add_entity_view(ent: Interactable) -> void:
	if ent.kind == "corpse":
		_add_corpse_view(ent)
		return
	var meta := aset.sprite(ent.def.get("sprite", ""))
	if meta.is_empty():
		push_warning("no sprite for entity %s" % ent.id)
		return
	var node := Sprite2D.new()
	node.texture = aset.texture(meta["file"])
	node.centered = false
	node.region_enabled = true
	node.offset = -Vector2(meta["pivot"][0], meta["pivot"][1])
	node.position = Iso.to_screen(ent.pos, aset.tile_w)
	node.name = ent.id
	entities.add_child(node)
	var sh := Sprite2D.new()
	sh.texture = aset.texture(meta["shadow"])
	sh.centered = false
	sh.region_enabled = true
	sh.offset = node.offset
	sh.position = node.position
	shadows.add_child(sh)
	var f := float(int(meta.get("frames", 1)) - 1) if ent.open else 0.0
	entity_views[ent.id] = {"node": node, "shadow": sh, "meta": meta, "frame": f}
	_set_entity_frame(ent.id, int(f))


func _add_corpse_view(ent: Interactable) -> void:
	var m := aset.anim(str(ent.def.get("creature", "wolf")))
	if m.is_empty():
		return
	var death: Dictionary = m["anims"]["death"]
	var fs := Vector2(m["frame_size"][0], m["frame_size"][1])
	var node := Sprite2D.new()
	node.texture = aset.texture(death["file"])
	node.centered = false
	node.region_enabled = true
	node.region_rect = Rect2((int(death["frames"]) - 1) * fs.x, int(ent.def.get("facing", 0)) * fs.y, fs.x, fs.y)
	node.offset = -Vector2(m["pivot"][0], m["pivot"][1])
	node.position = Iso.to_screen(ent.pos, aset.tile_w)
	node.modulate = Color(0.85, 0.82, 0.78)
	entities.add_child(node)
	var sh := Sprite2D.new()
	shadows.add_child(sh)
	entity_views[ent.id] = {"node": node, "shadow": sh, "meta": {"frames": 1, "size": [fs.x, fs.y]}, "frame": 0.0, "corpse": true}


func _sync_dynamic_entities() -> void:
	for id in sim.entities:
		if not entity_views.has(id):
			_add_entity_view(sim.entities[id])
	for id in entity_views.keys():
		if not sim.entities.has(id):
			entity_views[id]["node"].queue_free()
			entity_views[id]["shadow"].queue_free()
			entity_views.erase(id)


func _set_entity_frame(id: String, f: int) -> void:
	if entity_views[id].get("corpse", false):
		return
	var v: Dictionary = entity_views[id]
	var fs: Array = v["meta"].get("frame_size", v["meta"]["size"])
	var r := Rect2(f * fs[0], 0, fs[0], fs[1])
	v["node"].region_rect = r
	v["shadow"].region_rect = r


## Keep ground-item sprites in step with the authoritative item store.
func _sync_ground_items() -> void:
	var live := {}
	for uid in sim.items.world_items():
		live[uid] = true
		if not ground_views.has(uid):
			var d := sim.items.def(sim.items.item(uid).def_id)
			var meta := aset.sprite(d.world_sprite)
			if meta.is_empty():
				continue
			var node := Sprite2D.new()
			node.texture = aset.texture(meta["file"])
			node.centered = false
			node.offset = -Vector2(meta["pivot"][0], meta["pivot"][1])
			var sh := Sprite2D.new()
			sh.texture = aset.texture(meta["shadow"])
			sh.centered = false
			sh.offset = node.offset
			entities.add_child(node)
			shadows.add_child(sh)
			ground_views[uid] = {"node": node, "shadow": sh, "meta": meta}
		var pos := Iso.to_screen(sim.items.location(uid)["pos"], aset.tile_w)
		ground_views[uid]["node"].position = pos
		ground_views[uid]["shadow"].position = pos
	for uid in ground_views.keys():
		if not live.has(uid):
			ground_views[uid]["node"].queue_free()
			ground_views[uid]["shadow"].queue_free()
			ground_views.erase(uid)


func _sync_entities(dt: float) -> void:
	_sync_dynamic_entities()
	for id in entity_views:
		if entity_views[id].get("corpse", false):
			continue
		var ent: Interactable = sim.entities[id]
		var v: Dictionary = entity_views[id]
		var last := float(int(v["meta"].get("frames", 1)) - 1)
		var target := last if ent.open else 0.0
		var f: float = move_toward(v["frame"], target, dt * 14.0) if dt > 0.0 else target
		if int(round(f)) != int(round(v["frame"])) or dt == 0.0:
			_set_entity_frame(id, int(round(f)))
		v["frame"] = f


## Shared animation choice for players and creatures: death > attack > walk > idle.
func _animate(av: ActorSprite, id: String, moving: bool, anim_t: float, facing: int, dead: bool) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var pr: Dictionary = present.get(id, {})
	var anims: Dictionary = av.meta["anims"]
	if dead and anims.has("death"):
		if not pr.has("dead_at"):
			pr["dead_at"] = now
			present[id] = pr
		av.show_frame("death", mini(int((now - pr["dead_at"]) * av.fps("death")), int(anims["death"]["frames"]) - 1), facing)
		return
	pr.erase("dead_at")
	if anims.has("attack") and pr.has("swing"):
		var fa := int((now - float(pr["swing"])) * av.fps("attack"))
		if fa < int(anims["attack"]["frames"]):
			av.show_frame("attack", fa, facing)
			return
	var anim := "walk" if moving else "idle"
	av.show_frame(anim, int(floor(anim_t * av.fps(anim))), facing)


func _flash_color(id: String, dead: bool) -> Color:
	var pr: Dictionary = present.get(id, {})
	if pr.has("flash") and Time.get_ticks_msec() / 1000.0 - float(pr["flash"]) < 0.15:
		return Color(1.7, 0.55, 0.5)
	return Color(0.75, 0.75, 0.8, 0.85) if dead else Color.WHITE


func _sync_npcs() -> void:
	for id in sim.npcs:
		var n: NpcState = sim.npcs[id]
		var nv: ActorSprite = npc_views.get(id)
		if nv == null:
			if aset.anim(n.archetype).is_empty():
				continue
			nv = ActorSprite.new()
			nv.name = "Npc_" + id
			nv.setup(aset, n.archetype)
			entities.add_child(nv)
			shadows.add_child(nv.shadow)
			npc_views[id] = nv
		var dead := n.combat.dead
		nv.visible = not dead
		nv.shadow.visible = not dead
		if dead:
			continue
		nv.position = Iso.to_screen(n.render_pos, aset.tile_w)
		if n.swing_started > 0.0:
			present.get_or_add(id, {})["swing"] = n.swing_started
		_animate(nv, id, n.render_moving, n.anim_time, n.render_facing, false)
		nv.modulate = _flash_color(id, false)


## Combat events -> presentation (called by main for every combat event).
func on_combat_event(e: Dictionary) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	var src: String = e.get("source", "")
	var tgt: String = e.get("target", "")
	match e["kind"]:
		"swing":
			present.get_or_add(src, {})["swing"] = now
		"projectile":
			var arrow := CombatFX.Arrow.new()
			arrow.from = _entity_screen(src) + Vector2(0, -38) * aset.tile_w / 64.0
			arrow.to = _entity_screen(tgt) + Vector2(0, -26) * aset.tile_w / 64.0
			arrow.dur = maxf(0.08, float(e.get("travel", 0.3)))
			arrow.hit = bool(e.get("hit", true))
			fx_layer.add_child(arrow)
		"damage":
			var delay := float(e.get("delay", 0.0))
			var flash_it := func():
				present.get_or_add(tgt, {})["flash"] = Time.get_ticks_msec() / 1000.0
				var at := _entity_screen(tgt) + Vector2(0, -24) * aset.tile_w / 64.0
				var electric: bool = e.get("category", "") == "electrical"
				fx_layer.add_child(CombatFX.spark(at, Color(0.55, 0.8, 1.0) if electric else Color(0.85, 0.15, 0.1), 12 if electric else 8))
				if electric and src != "" and (actor_views.has(src) or npc_views.has(src)):
					var bolt := CombatFX.Bolt.new()
					var av: ActorSprite = actor_views.get(src, npc_views.get(src))
					bolt.from = av.position + (av.energy.tip if av.energy else Vector2(0, -30))
					bolt.to = at
					fx_layer.add_child(bolt)
			if delay > 0.0:
				get_tree().create_timer(delay).timeout.connect(flash_it)
			else:
				flash_it.call()


func _entity_screen(id: String) -> Vector2:
	if npc_views.has(id):
		return npc_views[id].position
	if actor_views.has(id):
		return actor_views[id].position
	if sim.npcs.has(id):
		return Iso.to_screen(sim.npcs[id].render_pos, aset.tile_w)
	return Iso.to_screen(sim.actor_pos(id), aset.tile_w)


func _update_target_ring() -> void:
	var tid := target_id
	var ok := false
	if sim.npcs.has(tid) and not sim.npcs[tid].combat.dead:
		target_ring.world = sim.npcs[tid].render_pos
		target_ring.color = Color(1.0, 0.38, 0.22)
		target_ring.radius = float(sim.npcs[tid].def.get("radius", 0.3)) + 0.18
		ok = true
	elif sim.players.has(tid) and tid != sim.local_actor:
		target_ring.world = sim.players[tid].render_pos
		target_ring.color = Color(0.55, 0.9, 0.45)
		target_ring.radius = 0.42
		ok = true
	target_ring.visible = ok


## Create / remove character sprites to match the sim's player list.
func _sync_actors() -> void:
	for a in sim.players:
		if not actor_views.has(a):
			var av := ActorSprite.new()
			av.name = "Actor_" + a
			av.setup(aset, "player", true)
			av.set_appearance(sim.players[a].appearance)
			entities.add_child(av)
			shadows.add_child(av.shadow)
			shadows.add_child(av.overlay_shadow)
			actor_views[a] = av
	for a in actor_views.keys():
		if not sim.players.has(a):
			var av: ActorSprite = actor_views[a]
			av.shadow.queue_free()
			av.overlay_shadow.queue_free()
			av.queue_free()
			actor_views.erase(a)
	player = actor_views.get(sim.local_actor)


func node_for(id: String) -> Node2D:
	if npc_views.has(id):
		return npc_views[id]
	if actor_views.has(id):
		return actor_views[id]
	if id.begins_with("item:"):
		var uid := int(id.substr(5))
		return ground_views[uid]["node"] if ground_views.has(uid) else null
	return entity_views[id]["node"] if entity_views.has(id) else null


## Pixel-accurate pick of the top-most interactable under a world-space pixel.
func pick(px: Vector2) -> String:
	var best := ""
	var best_y := -INF
	var cands: Array = []
	for id in entity_views:
		cands.append([id, entity_views[id]["node"]])
	for uid in ground_views:
		cands.append(["item:%d" % uid, ground_views[uid]["node"]])
	# characters and creatures: a generous body hit box (thin sprites such as
	# skeletons are otherwise hard to click)
	var k := aset.tile_w / 64.0
	for id in npc_views:
		var nv: ActorSprite = npc_views[id]
		if nv.visible:
			var h := (34.0 if sim.npcs[id].archetype == "wolf" else 66.0) * k
			var w := (22.0 if sim.npcs[id].archetype == "wolf" else 14.0) * k
			var rel := px - nv.position
			if absf(rel.x) < w and rel.y < 4.0 * k and rel.y > -h and nv.position.y > best_y:
				best = id
				best_y = nv.position.y
	for a in actor_views:
		if a != sim.local_actor:
			var rel2: Vector2 = px - actor_views[a].position
			if absf(rel2.x) < 14.0 * k and rel2.y < 4.0 * k and rel2.y > -70.0 * k and actor_views[a].position.y > best_y:
				best = a
				best_y = actor_views[a].position.y
	for c in cands:
		var node: Sprite2D = c[1]
		var gpos: Vector2 = node.get_parent().position + node.position if node.get_parent() is ActorSprite else node.position
		var local: Vector2 = px - gpos - node.offset
		var region := node.region_rect if node.region_enabled else Rect2(Vector2.ZERO, node.texture.get_size())
		# ground items are tiny: accept a small margin around opaque pixels
		var margin := 3 if String(c[0]).begins_with("item:") else 0
		if not Rect2(Vector2.ZERO, region.size).grow(margin).has_point(local):
			continue
		if _opaque_near(node.texture, region, local, margin) and gpos.y > best_y:
			best = c[0]
			best_y = gpos.y
	return best


func _opaque_near(tex: Texture2D, region: Rect2, local: Vector2, margin: int) -> bool:
	var key := tex.get_rid()
	if not _pick_images.has(key):
		_pick_images[key] = tex.get_image()
	var img: Image = _pick_images[key]
	for dy in range(-margin, margin + 1):
		for dx in range(-margin, margin + 1):
			var p := Vector2i(int(local.x) + dx, int(local.y) + dy)
			if p.x < 0 or p.y < 0 or p.x >= int(region.size.x) or p.y >= int(region.size.y):
				continue
			if img.get_pixelv(Vector2i(region.position) + p).a > 0.5:
				return true
	return false


func _apply_highlights(t: float) -> void:
	for id in entity_views:
		entity_views[id]["node"].modulate = Color.WHITE
	for uid in ground_views:
		ground_views[uid]["node"].modulate = Color.WHITE
	if npc_views.has(selected) or actor_views.has(selected):
		return   # creatures/players get the target ring instead of a tint
	var sel := node_for(selected)
	if sel:
		var k := 1.12 + 0.08 * sin(t * 6.0)
		sel.modulate = Color(k, k, k * 0.9)
	var hov := node_for(hovered)
	if hov:
		hov.modulate = Color(1.32, 1.26, 1.08)


## Pull state from the simulation.
func sync(_dt: float) -> void:
	var tw := aset.tile_w
	_sync_ground_items()
	_sync_entities(_dt)
	_apply_highlights(Time.get_ticks_msec() / 1000.0)
	_sync_actors()
	_sync_npcs()
	_update_target_ring()
	for a in actor_views:
		var av: ActorSprite = actor_views[a]
		var ps: PlayerState = sim.players[a]
		var weapon := sim.items.equipped(a, "main_hand")
		var it := sim.items.item(weapon) if weapon else null
		var layer := sim.items.def(it.def_id).paperdoll_layer if it else ""
		av.set_overlay(layer)
		av.position = Iso.to_screen(ps.render_pos, tw)
		var dead := ps.combat != null and ps.combat.dead
		_animate(av, a, ps.render_moving, ps.anim_time, ps.render_facing, dead)
		av.modulate = Color(0.65, 0.65, 0.7, 0.6) if ps.linkdead else _flash_color(a, dead)
		if av.energy:
			var magic := it != null and sim.items.def(it.def_id).effect == "lightning"
			var on := (magic or show_energy) and layer != "" and not dead
			av.energy.enabled = on
			av.energy.visible = on
	for k in sheep_views.size():
		var s: Dictionary = sim.sheep[k]
		var sv := sheep_views[k]
		sv.position = Iso.to_screen(s["pos"], tw)
		var st: String = s["state"]
		var t: float = s["t"]
		if st == "walk":
			sv.show_frame("stand", int(t * 4.0), s["facing"], absf(sin(t * 8.0)) * tw / 64.0)
		elif st == "graze":
			sv.show_frame("graze", int(t * 0.7), s["facing"])
		else:
			sv.show_frame("stand", 0, s["facing"])
	_update_occlusion_fade(_dt)
	if player:
		camera.position = player.position.round()
	if overlay.visible:
		overlay.queue_redraw()


func mouse_world() -> Vector2:
	return Iso.to_world(get_global_mouse_position(), aset.tile_w)


## Fade a building while it hides the player (readability; UO-style roofs are future work).
func _update_occlusion_fade(dt: float) -> void:
	if player == null:
		return
	var k := aset.tile_w / 64.0
	for t in trees:
		var tn: Sprite2D = t["node"]
		var tp: Vector2 = t["pos"]
		var behind_tree := (sim.player_pos.x + sim.player_pos.y) < (tp.x + tp.y) and sim.player_pos.distance_to(tp) < 3.5
		var hidden: bool = behind_tree and (t["rect"] as Rect2).grow(-6).has_point(player.position - tn.position + Vector2(0, -30) * k)
		var ta: float = move_toward(tn.modulate.a, 0.45 if hidden else 1.0, dt * 3.0) if dt > 0.0 else 1.0
		tn.modulate.a = ta
	for b in buildings:
		var node: BuildingSprite = b["node"]
		var rect: Rect2 = b["rect"]
		var fp: Array = b["fp"]
		var local: Vector2 = sim.player_pos - b["pos"]
		# behind = the player's world point is not in front of either front edge
		var behind: bool = local.x < float(fp[2]) and local.y < float(fp[3])
		var screen_local := player.position - node.position
		var covered := rect.grow(-4).has_point(screen_local + Vector2(0, -20.0 * aset.tile_w / 64.0))
		var inside: bool = local.x > 0.0 and local.y > 0.0 and behind
		var target := 1.0
		if inside:
			target = 0.32
		elif behind and covered:
			target = 0.55
		var a: float = move_toward(node.modulate.a, target, dt * 3.0) if dt > 0.0 else target
		node.modulate.a = a


## A world-pixel point that is guaranteed to hit `id` (centroid of its opaque
## pixels). Used by the scripted-input scenario runner.
func pick_point(id: String) -> Vector2:
	var node: Sprite2D = node_for(id)
	if node == null:
		return Vector2.INF
	var region := node.region_rect if node.region_enabled else Rect2(Vector2.ZERO, node.texture.get_size())
	var key := node.texture.get_rid()
	if not _pick_images.has(key):
		_pick_images[key] = node.texture.get_image()
	var img: Image = _pick_images[key]
	var acc := Vector2.ZERO
	var n := 0
	for y in int(region.size.y):
		for x in int(region.size.x):
			if img.get_pixel(int(region.position.x) + x, int(region.position.y) + y).a > 0.5:
				acc += Vector2(x, y)
				n += 1
	if n == 0:
		return Vector2.INF
	var c := acc / n
	# snap to the nearest opaque pixel
	var best := c
	var bd := INF
	for y in int(region.size.y):
		for x in int(region.size.x):
			if img.get_pixel(int(region.position.x) + x, int(region.position.y) + y).a > 0.5:
				var d := Vector2(x, y).distance_squared_to(c)
				if d < bd:
					bd = d
					best = Vector2(x, y)
	return node.position + node.offset + best + Vector2(0.5, 0.5)
