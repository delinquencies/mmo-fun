class_name WorldSurface
extends Control
## Transparent layer over the game views that turns mouse input into world
## intent: hover, click (select / name), double-click (use), dragging ground
## items, and dropping carried items onto the ground. Windows sit above it, so
## anything they handle never reaches the world.

var main: Node            # main.gd: provides picking and coordinate helpers
var _press_id := ""
var _press_pos := Vector2.ZERO
var _drag_started := false
var right_held := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		main.update_hover(e.position)
		if _press_id.begins_with("item:") and not _drag_started and (e.button_mask & MOUSE_BUTTON_MASK_LEFT) \
				and e.position.distance_to(_press_pos) > 5.0:
			_drag_started = true
			main.start_world_drag(_press_id, self)
	elif e is InputEventMouseButton:
		match e.button_index:
			MOUSE_BUTTON_LEFT:
				if e.pressed:
					var id: String = main.pick_at(e.position)
					if e.double_click:
						if id != "":
							main.use_entity(id)
					else:
						_press_id = id
						_press_pos = e.position
						_drag_started = false
						main.select_entity(id)
				else:
					_press_id = ""
			MOUSE_BUTTON_RIGHT:
				right_held = e.pressed
			MOUSE_BUTTON_WHEEL_UP:
				if e.pressed:
					main.zoom_step(1)
			MOUSE_BUTTON_WHEEL_DOWN:
				if e.pressed:
					main.zoom_step(-1)


func _can_drop_data(at: Vector2, data: Variant) -> bool:
	if not (data is Dictionary and data.has("uid")):
		return false
	main.preview_world_drop(at, data)
	return true


func _drop_data(at: Vector2, data: Variant) -> void:
	main.drop_on_world(at, data)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END or what == NOTIFICATION_MOUSE_EXIT:
		if main:
			main.hide_drop_marker()
