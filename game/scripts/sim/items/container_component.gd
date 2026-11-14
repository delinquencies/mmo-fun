class_name ContainerComponent
extends RefCounted
## A fixed-capacity grid of item slots (backpack, chest). Slots hold item uids
## (0 = empty). Only ItemStore / ItemTransferService mutate slots.

var id: String
var title: String
var owner_entity: String      # actor id (backpack) or world entity id (chest)
var capacity: int
var columns: int
var slots: PackedInt64Array


func _init(p_id: String, p_title: String, p_owner: String, p_capacity: int, p_columns: int) -> void:
	id = p_id
	title = p_title
	owner_entity = p_owner
	capacity = p_capacity
	columns = p_columns
	slots.resize(capacity)
	slots.fill(0)


func first_empty() -> int:
	for i in capacity:
		if slots[i] == 0:
			return i
	return -1


func used() -> int:
	var n := 0
	for s in slots:
		if s != 0:
			n += 1
	return n
