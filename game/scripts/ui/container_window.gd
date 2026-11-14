class_name ContainerWindow
extends GameWindow
## Grid view of one ContainerComponent (backpack, chest).

var ui: GameUI
var cid: String
var slots: Array[ItemSlot] = []
var _base_title: String


func _init(p_ui: GameUI, container_id: String) -> void:
	var c: ContainerComponent = p_ui.store.containers[container_id]
	super(c.title)
	ui = p_ui
	cid = container_id
	_base_title = c.title
	var grid := GridContainer.new()
	grid.columns = c.columns
	grid.add_theme_constant_override("h_separation", 2)
	grid.add_theme_constant_override("v_separation", 2)
	for i in c.capacity:
		var s := ItemSlot.new(ui, ItemLocation.container(cid, i))
		s.window = self
		grid.add_child(s)
		slots.append(s)
	content.add_child(grid)
	fit()
	refresh()


func refresh() -> void:
	for s in slots:
		s.refresh()
	var c: ContainerComponent = ui.store.containers[cid]
	set_title("%s   %d/%d" % [_base_title, c.used(), c.capacity])


## Dropping on the window frame (not a slot) means "anywhere in here".
func _can_drop_data(_at: Vector2, data: Variant) -> bool:
	return data is Dictionary and data.has("uid")


func _drop_data(_at: Vector2, data: Variant) -> void:
	ui.transfer(data, ItemLocation.container(cid, -1))
