class_name EquipmentWindow
extends GameWindow
## Compact equipment panel. Off hand exists in the model but is reserved.

var ui: GameUI
var slots: Array[ItemSlot] = []


func _init(p_ui: GameUI, actor: String) -> void:
	super("Equipment")
	ui = p_ui
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 14)
	var eq: EquipmentComponent = ui.store.equipment[actor]
	for slot_name in ["main_hand", "off_hand"]:
		var col := VBoxContainer.new()
		col.alignment = BoxContainer.ALIGNMENT_CENTER
		var reserved := eq.is_reserved(slot_name)
		var cap: String = EquipmentComponent.SLOT_NAMES[slot_name]
		var s := ItemSlot.new(ui, ItemLocation.equipment(actor, slot_name), reserved,
			cap + (" (reserved for a future update)" if reserved else ""))
		s.window = self
		s.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		slots.append(s)
		col.add_child(s)
		var l := UISkin.label(cap, UISkin.TEXT_DIM if reserved else UISkin.TEXT, 11)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		col.add_child(l)
		row.add_child(col)
	content.add_child(row)
	fit()
	refresh()


func refresh() -> void:
	for s in slots:
		s.refresh()
