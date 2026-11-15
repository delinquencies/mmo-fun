class_name ItemInstance
extends RefCounted
## One concrete item (or stack) in the world. Identity is the uid; where it is
## lives in ItemStore.locations so an item can never be in two places.

var uid: int
var def_id: String
var quantity := 1
var version := 1          # optimistic-concurrency version mirrored from the database


func _init(p_uid: int, p_def: String, p_qty: int) -> void:
	uid = p_uid
	def_id = p_def
	quantity = p_qty


func to_dict() -> Dictionary:
	return {"uid": uid, "def": def_id, "qty": quantity}
