class_name EquipmentComponent
extends RefCounted
## Equipment slots for one actor. Reserved slots exist in the model (so UI and
## saves can rely on them) but refuse items until their rules are designed.

const SLOT_NAMES := {"main_hand": "Main Hand", "off_hand": "Off Hand"}

var owner: String
var slots: Dictionary = {"main_hand": 0, "off_hand": 0}
var reserved: PackedStringArray = ["off_hand"]


func _init(p_owner: String) -> void:
	owner = p_owner


func is_reserved(slot: String) -> bool:
	return reserved.has(slot)
