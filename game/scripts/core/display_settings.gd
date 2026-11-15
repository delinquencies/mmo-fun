class_name DisplaySettings
extends RefCounted
## Client-local presentation preferences: world camera zoom and interface
## scale. They are independent of each other and stored per machine in
## user://settings.cfg, never in the character database.
##
## Both values are in *display points*: on a desktop at 100% one point is one
## screen pixel; on a Retina Mac or a Windows desktop at 200% it is two. That
## keeps "1.5x" looking the same size on every monitor.
##
##   physical px per art px  = world_zoom * os_scale   (camera zoom)
##   physical px per UI px   = ui_scale   * os_scale   (Window.content_scale_factor)

var path := "user://settings.cfg"
const DATA := "res://data/display.json"

var zoom_default := 1.5
var zoom_min := 1.0
var zoom_max := 2.0
var zoom_step := 0.25
var ui_choices: PackedFloat32Array = [1.0, 1.25, 1.5, 1.75, 2.0]
var reference_height := 720.0
var min_layout_height := 540.0
var window_fraction := 0.85
var window_min := Vector2i(1280, 720)

var world_zoom := 1.5
var ui_scale := 1.5
var show_help := true       # keyboard help panel (H)
var persist := true          # false for automated runs: never touch the player's file


func _init() -> void:
	var f := FileAccess.open(DATA, FileAccess.READ)
	if f:
		var d: Dictionary = JSON.parse_string(f.get_as_text())
		var z: Dictionary = d.get("world_zoom", {})
		zoom_default = float(z.get("default", zoom_default))
		zoom_min = float(z.get("min", zoom_min))
		zoom_max = float(z.get("max", zoom_max))
		zoom_step = float(z.get("step", zoom_step))
		var u: Dictionary = d.get("ui_scale", {})
		if u.has("choices"):
			ui_choices = PackedFloat32Array(u["choices"])
		reference_height = float(u.get("reference_height", reference_height))
		min_layout_height = float(u.get("min_layout_height", min_layout_height))
		var w: Dictionary = d.get("window", {})
		window_fraction = float(w.get("fraction_of_screen", window_fraction))
		if w.has("min_size"):
			window_min = Vector2i(int(w["min_size"][0]), int(w["min_size"][1]))
	reset_to_default()


## Pixels per display point reported by the operating system.
static func os_scale() -> float:
	if DisplayServer.get_name() == "headless":
		return 1.0
	var s := DisplayServer.screen_get_scale()
	if OS.get_name() == "Windows":
		# Windows reports scale 1.0; its desktop scaling shows up as DPI.
		s = maxf(s, DisplayServer.screen_get_dpi() / 96.0)
	return maxf(1.0, s)


## Screen size in display points.
static func screen_points() -> Vector2:
	if DisplayServer.get_name() == "headless":
		return Vector2(1920, 1080)
	return Vector2(DisplayServer.screen_get_size()) / os_scale()


## The interface scale that suits this screen: 100% at 720 points tall,
## 150% at 1080, 200% at 1440 and above.
func auto_ui_scale() -> float:
	return nearest_ui_choice(screen_points().y / reference_height)


func nearest_ui_choice(s: float) -> float:
	var best := ui_choices[0]
	for c in ui_choices:
		if absf(c - s) < absf(best - s) - 0.001:
			best = c
	return best


func reset_to_default() -> void:
	world_zoom = zoom_default
	ui_scale = auto_ui_scale()


func clamp_zoom(z: float) -> float:
	return clampf(snappedf(z, zoom_step), zoom_min, zoom_max)


func step_zoom(d: int) -> float:
	world_zoom = clamp_zoom(world_zoom + d * zoom_step)
	return world_zoom


func cycle_ui(d := 1) -> float:
	var i := Array(ui_choices).find(nearest_ui_choice(ui_scale))
	ui_scale = ui_choices[posmod(i + d, ui_choices.size())]
	return ui_scale


## Interface scale actually used for a window of `window_px` physical pixels:
## the chosen one, reduced if the layout would get shorter than
## min_layout_height points (so windows always fit on small screens).
func effective_ui_factor(window_px: Vector2) -> float:
	var f := ui_scale * os_scale()
	return maxf(1.0, minf(f, window_px.y / min_layout_height))


## Initial window size: a share of the screen at 16:9, never below window_min.
func initial_window_size() -> Vector2i:
	var scr := Vector2(DisplayServer.screen_get_usable_rect().size)
	var w := scr.x * window_fraction
	var h := w * 9.0 / 16.0
	if h > scr.y * window_fraction:
		h = scr.y * window_fraction
		w = h * 16.0 / 9.0
	return Vector2i(maxi(int(w), mini(window_min.x, int(scr.x))), maxi(int(h), mini(window_min.y, int(scr.y))))


func load_prefs() -> void:
	if not persist:
		return
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return
	world_zoom = clamp_zoom(float(cfg.get_value("display", "world_zoom", world_zoom)))
	ui_scale = nearest_ui_choice(float(cfg.get_value("display", "ui_scale", ui_scale)))
	show_help = bool(cfg.get_value("interface", "show_help", show_help))


func save_prefs() -> void:
	if not persist:
		return
	var cfg := ConfigFile.new()
	cfg.load(path)   # keep any other sections
	cfg.set_value("display", "world_zoom", world_zoom)
	cfg.set_value("display", "ui_scale", ui_scale)
	cfg.set_value("interface", "show_help", show_help)
	cfg.save(path)
