class_name ItemDefinition
extends RefCounted
## Static, data-driven description of an item type (game/data/items.json).

var id: String
var name: String
var description: String
var stackable := false
var max_stack := 1
var equip_slot := ""          # "" = not equippable; else an EquipmentComponent slot name
var paperdoll_layer := ""     # overlay sheet id on the character when equipped
var icon := ""
var world_sprite := ""
var sounds: Dictionary = {}


static func from_dict(def_id: String, d: Dictionary) -> ItemDefinition:
	var def := ItemDefinition.new()
	def.id = def_id
	def.name = d.get("name", def_id)
	def.description = d.get("description", "")
	def.stackable = bool(d.get("stackable", false))
	def.max_stack = int(d.get("max_stack", 1000 if def.stackable else 1))
	def.equip_slot = d.get("equip_slot", "")
	def.paperdoll_layer = d.get("paperdoll_layer", "")
	def.icon = d.get("icon", def_id)
	def.world_sprite = d.get("world_sprite", "")
	def.sounds = d.get("sounds", {})
	return def


func sound(event: String, fallback: String) -> String:
	return sounds.get(event, fallback)
