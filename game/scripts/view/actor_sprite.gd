class_name ActorSprite
extends Node2D
## Eight-direction sprite-sheet actor. Rows = facings (Iso.DIRECTIONS order),
## columns = frames. Node origin = foot anchor (the y-sort point).

var aset: AssetSet
var meta: Dictionary
var sprite := Sprite2D.new()
var shadow := Sprite2D.new()   # lives in the view's shadow layer
var energy: SwordEnergy
var current_anim := ""
var frame := 0
var facing := 0
var frame_size := Vector2i.ZERO
var pivot := Vector2.ZERO


func setup(asset_set: AssetSet, actor: String, with_energy := false) -> void:
	aset = asset_set
	meta = aset.anim(actor)
	frame_size = Vector2i(int(meta["frame_size"][0]), int(meta["frame_size"][1]))
	pivot = Vector2(meta["pivot"][0], meta["pivot"][1])
	for s in [sprite, shadow]:
		s.centered = false
		s.region_enabled = true
		s.offset = -pivot
	add_child(sprite)
	if with_energy:
		energy = SwordEnergy.new()
		add_child(energy)


func show_frame(anim: String, f: int, dir: int, bob := 0.0) -> void:
	var a: Dictionary = meta["anims"][anim]
	if anim != current_anim:
		current_anim = anim
		sprite.texture = aset.texture(a["file"])
		shadow.texture = aset.texture(a["shadow"])
	frame = posmod(f, int(a["frames"]))
	facing = dir
	var r := Rect2(frame * frame_size.x, dir * frame_size.y, frame_size.x, frame_size.y)
	sprite.region_rect = r
	shadow.region_rect = r
	sprite.position.y = -round(bob)
	shadow.global_position = global_position
	if energy:
		var fa: Dictionary = a["anchors"][dir][frame]
		var b := Vector2(fa["blade_base"][0], fa["blade_base"][1])
		var t := Vector2(fa["blade_tip"][0], fa["blade_tip"][1])
		var behind := float(fa["blade_visible"]) < 0.5
		energy.set_blade(b, t)
		var want := 0 if behind else get_child_count() - 1
		if energy.get_index() != want:
			move_child(energy, want)


func fps(anim: String) -> float:
	return float(meta["anims"][anim]["fps"])
