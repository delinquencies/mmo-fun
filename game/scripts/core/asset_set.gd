class_name AssetSet
extends RefCounted
## One native-resolution family of pre-rendered assets (e.g. t64 or t96),
## described by the manifest.json written by tools/forge/build.py.

var id: String
var dir: String
var tile_w: int
var tile_h: int
var manifest: Dictionary
var _cache: Dictionary = {}


static func load_set(set_id: String) -> AssetSet:
	var s := AssetSet.new()
	s.id = set_id
	s.dir = "res://assets/generated/%s/" % set_id
	var txt := FileAccess.get_file_as_string(s.dir + "manifest.json")
	if txt.is_empty():
		push_error("Missing manifest for asset set %s - run tools/forge/build.py" % set_id)
		return null
	s.manifest = JSON.parse_string(txt)
	s.tile_w = int(s.manifest["tile_w"])
	s.tile_h = int(s.manifest["tile_h"])
	return s


## Loads straight from the PNG on disk when available so freshly forged art
## can be hot-reloaded (F5) without an editor re-import; falls back to the
## imported resource in exported builds.
func texture(file: String) -> Texture2D:
	if _cache.has(file):
		return _cache[file]
	var path := dir + file
	var tex: Texture2D
	var abs_path := ProjectSettings.globalize_path(path)
	if FileAccess.file_exists(abs_path):
		var img := Image.load_from_file(abs_path)
		if img:
			tex = ImageTexture.create_from_image(img)
	if tex == null:
		tex = load(path)
	_cache[file] = tex
	return tex


func sprite(name: String) -> Dictionary:
	return manifest["sprites"].get(name, {})


func anim(name: String) -> Dictionary:
	return manifest["animations"].get(name, {})


func label() -> String:
	var ch := int(anim("player").get("content_height_px", 0))
	return "%dx%d tiles  |  character %d px" % [tile_w, tile_h, ch]
