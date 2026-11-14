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
var player: ActorSprite
var sheep_views: Array[ActorSprite] = []
var buildings: Array = []         # [BuildingSprite, world pos, footprint]
var show_energy := true


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
		_add_effects(node, type, meta)

	for s in sim.sheep:
		var sv := ActorSprite.new()
		sv.setup(aset, "sheep")
		entities.add_child(sv)
		shadows.add_child(sv.shadow)
		sheep_views.append(sv)

	player = ActorSprite.new()
	player.name = "Player"
	player.setup(aset, "player", true)
	entities.add_child(player)
	shadows.add_child(player.shadow)

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


## Pull state from the simulation.
func sync(_dt: float) -> void:
	var tw := aset.tile_w
	player.position = Iso.to_screen(sim.player_pos, tw)
	var anim := "walk" if sim.player_moving else "idle"
	var f := int(floor(sim.player_anim_time * player.fps(anim)))
	player.show_frame(anim, f, sim.player_facing)
	if player.energy:
		player.energy.enabled = show_energy
		player.energy.visible = show_energy
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
	camera.position = player.position.round()
	if overlay.visible:
		overlay.queue_redraw()


func mouse_world() -> Vector2:
	return Iso.to_world(get_global_mouse_position(), aset.tile_w)


## Fade a building while it hides the player (readability; UO-style roofs are future work).
func _update_occlusion_fade(dt: float) -> void:
	for b in buildings:
		var node: BuildingSprite = b["node"]
		var rect: Rect2 = b["rect"]
		var fp: Array = b["fp"]
		var local: Vector2 = sim.player_pos - b["pos"]
		# behind = the player's world point is not in front of either front edge
		var behind: bool = local.x < float(fp[2]) and local.y < float(fp[3])
		var screen_local := player.position - node.position
		var covered := rect.grow(-4).has_point(screen_local + Vector2(0, -20.0 * aset.tile_w / 64.0))
		var target := 0.55 if (behind and covered) else 1.0
		var a: float = move_toward(node.modulate.a, target, dt * 3.0) if dt > 0.0 else target
		node.modulate.a = a
