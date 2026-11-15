class_name GroundLayer
extends Node2D
## Draws one terrain layer (base grass, or a corner-masked overlay) as batched
## texture-region draws. Tile (i,j)'s diamond top vertex sits at Iso.to_screen(i,j).

var tex: Texture2D
var tiles: Array = []   # [Rect2 dst, Rect2 src]


func setup(texture: Texture2D, tile_list: Array) -> void:
	tex = texture
	tiles = tile_list
	queue_redraw()


func _draw() -> void:
	for t in tiles:
		draw_texture_rect_region(tex, t[0], t[1])


static func build(sim: WorldSim, aset: AssetSet) -> Array[GroundLayer]:
	var w := aset.tile_w
	var h := aset.tile_h
	var period := int(aset.manifest["terrain"]["period"])
	var grass: Array = []
	var dirt: Array = []
	var water: Array = []
	for j in sim.size.y:
		for i in sim.size.x:
			var top := Iso.to_screen(Vector2(i, j), w)
			# Drawn half a pixel larger on each side so neighbouring diamonds
			# overlap: at fractional zoom (1.25x, 1.5x, 1.75x) nearest-neighbour
			# rounding otherwise leaves dotted gaps along tile seams. Logical
			# tile size and coordinates are unchanged.
			var dst := Rect2(top - Vector2(w * 0.5, 0), Vector2(w, h)).grow_individual(0.5, 0.25, 0.5, 0.25)
			var a := posmod(i, period)
			var b := posmod(j, period)
			grass.append([dst, Rect2(a * w, b * h, w, h)])
			for layer in [[WorldSim.TERRAIN_DIRT, dirt], [WorldSim.TERRAIN_WATER, water]]:
				var t: int = layer[0]
				var m := 0
				if sim.corner(i, j) == t: m |= 1
				if sim.corner(i + 1, j) == t: m |= 2
				if sim.corner(i + 1, j + 1) == t: m |= 4
				if sim.corner(i, j + 1) == t: m |= 8
				if m:
					layer[1].append([dst, Rect2((a + b * period) * w, (m - 1) * h, w, h)])
	var out: Array[GroundLayer] = []
	var names := ["grass", "dirt", "water"]
	var lists := [grass, dirt, water]
	for k in 3:
		var gl := GroundLayer.new()
		gl.name = "Ground_" + names[k]
		gl.setup(aset.texture(aset.manifest["terrain"][names[k]]), lists[k])
		if names[k] == "water":
			var mat := ShaderMaterial.new()
			mat.shader = load("res://shaders/water.gdshader")
			gl.material = mat
		out.append(gl)
	return out
