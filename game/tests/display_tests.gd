extends SceneTree
## Headless tests for client display preferences (world zoom, interface size).
##   godot --headless --path game --script res://tests/display_tests.gd

var failures := 0
var checks := 0
var _finished := false
var current := ""
const TMP := "user://display_test_settings.cfg"


func _init() -> void:
	for t in ["t_defaults", "t_zoom_steps", "t_ui_choices", "t_fit_window", "t_prefs_roundtrip", "t_reset", "t_no_persist"]:
		current = t
		var before := failures
		_finished = false
		call(t)
		if not _finished:
			failures += 1
			print("   x [%s] test did not run to completion (script error)" % t)
		print("%s %s" % ["PASS" if failures == before else "FAIL", t])
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	print("\n%d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)


func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("   x [%s] %s" % [current, what])


func fresh() -> DisplaySettings:
	var d := DisplaySettings.new()
	d.path = TMP
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP))
	return d


func t_defaults() -> void:
	var d := fresh()
	check(d.world_zoom == 1.5, "default world zoom 1.5x (got %s)" % d.world_zoom)
	check(d.zoom_min == 1.0 and d.zoom_max == 2.0 and d.zoom_step == 0.25, "zoom limits 1.0-2.0 step 0.25 from display.json")
	check(Array(d.ui_choices) == [1.0, 1.25, 1.5, 1.75, 2.0], "interface choices 100-200%")
	# headless reports a 1920x1080 screen at scale 1: the 1080p baseline is 150%
	check(d.ui_scale == 1.5, "default interface size at 1080p is 150%% (got %s)" % d.ui_scale)
	_finished = true


func t_zoom_steps() -> void:
	var d := fresh()
	var seen: Array = [d.world_zoom]
	for i in 6:
		seen.append(d.step_zoom(1))
	check(seen == [1.5, 1.75, 2.0, 2.0, 2.0, 2.0, 2.0], "zoom in stops at 2.0 (%s)" % [seen])
	for i in 8:
		d.step_zoom(-1)
	check(d.world_zoom == 1.0, "zoom out stops at 1.0")
	check(d.clamp_zoom(1.37) == 1.25 and d.clamp_zoom(9.0) == 2.0 and d.clamp_zoom(0.1) == 1.0, "stored values snap to 0.25 and clamp")
	_finished = true


func t_ui_choices() -> void:
	var d := fresh()
	check(d.nearest_ui_choice(720.0 / 720.0) == 1.0 and d.nearest_ui_choice(1080.0 / 720.0) == 1.5 and d.nearest_ui_choice(1440.0 / 720.0) == 2.0 and d.nearest_ui_choice(2160.0 / 720.0) == 2.0,
		"screen-based default: 720 -> 100%, 1080 -> 150%, 1440 / 2160 -> 200%")
	d.ui_scale = 1.0
	var seq: Array = []
	for i in 5:
		seq.append(d.cycle_ui(1))
	check(seq == [1.25, 1.5, 1.75, 2.0, 1.0], "F2 cycles 125, 150, 175, 200, 100 (%s)" % [seq])
	_finished = true


func t_fit_window() -> void:
	var d := fresh()
	d.ui_scale = 1.5
	check(is_equal_approx(d.effective_ui_factor(Vector2(1920, 1080)), 1.5), "150% fits a 1080p window")
	d.ui_scale = 2.0
	check(is_equal_approx(d.effective_ui_factor(Vector2(1920, 1080)), 2.0), "200% fits a 1080p window (540-point layout)")
	check(is_equal_approx(d.effective_ui_factor(Vector2(1280, 720)), 720.0 / 540.0), "200% in a 720p window is reduced so the layout keeps 540 points")
	d.ui_scale = 1.0
	check(is_equal_approx(d.effective_ui_factor(Vector2(800, 400)), 1.0), "never below 100%")
	_finished = true


func t_prefs_roundtrip() -> void:
	var d := fresh()
	d.world_zoom = 1.75
	d.ui_scale = 1.25
	d.show_help = false
	d.save_prefs()
	var e := DisplaySettings.new()
	e.path = TMP
	e.load_prefs()
	check(e.world_zoom == 1.75 and e.ui_scale == 1.25 and e.show_help == false, "zoom, interface size and help survive a restart")
	var cfg := ConfigFile.new()
	cfg.set_value("display", "world_zoom", 7.0)
	cfg.set_value("display", "ui_scale", 3.3)
	cfg.save(TMP)
	e.load_prefs()
	check(e.world_zoom == 2.0 and e.ui_scale == 2.0, "tampered values are clamped on load")
	_finished = true


func t_reset() -> void:
	var d := fresh()
	d.world_zoom = 1.0
	d.ui_scale = 2.0
	d.reset_to_default()
	check(d.world_zoom == 1.5 and d.ui_scale == 1.5, "reset restores 1.5x and the screen default")
	_finished = true


func t_no_persist() -> void:
	var d := fresh()
	d.persist = false
	d.world_zoom = 2.0
	d.save_prefs()
	check(not FileAccess.file_exists(TMP), "automated runs never write the preferences file")
	_finished = true
