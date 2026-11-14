class_name ItemStore
extends RefCounted
## Authoritative item state: every ItemInstance and exactly one location per
## item. Containers and equipment hold uids; the store keeps both views in
## sync. Mutation helpers prefixed with _ are reserved for ItemTransferService
## and world setup - presentation code must go through InteractionSystem.

signal changed

var defs: Dictionary = {}          # def id -> ItemDefinition
var items: Dictionary = {}         # uid -> ItemInstance
var locations: Dictionary = {}     # uid -> location Dictionary (see ItemLocation)
var containers: Dictionary = {}    # container id -> ContainerComponent
var equipment: Dictionary = {}     # actor id -> EquipmentComponent
var revision := 0
var _next_uid := 1001


func load_definitions(path: String) -> void:
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	for k in data:
		defs[k] = ItemDefinition.from_dict(k, data[k])


func def(def_id: String) -> ItemDefinition:
	return defs.get(def_id)


func item(uid: int) -> ItemInstance:
	return items.get(uid)


func location(uid: int) -> Dictionary:
	return locations.get(uid, {})


func add_container(c: ContainerComponent) -> void:
	containers[c.id] = c


func add_equipment(e: EquipmentComponent) -> void:
	equipment[e.owner] = e


## uid occupying a slot location, 0 if empty / not a slot.
func occupant(loc: Dictionary) -> int:
	match loc.get("kind", ""):
		"container":
			var c: ContainerComponent = containers.get(loc["container"])
			var s := int(loc["slot"])
			if c and s >= 0 and s < c.capacity:
				return c.slots[s]
		"equipment":
			var e: EquipmentComponent = equipment.get(loc["owner"])
			if e:
				return int(e.slots.get(loc["slot"], 0))
	return 0


## World-setup creation (map load, tests). Gameplay transfers never create items
## except when splitting a stack, which conserves quantity.
func spawn(def_id: String, qty: int, loc: Dictionary) -> int:
	var d := def(def_id)
	if d == null or qty < 1 or qty > d.max_stack:
		push_error("spawn rejected: %s x%d" % [def_id, qty])
		return 0
	var l := loc.duplicate()
	if l["kind"] == "container" and int(l["slot"]) < 0:
		var c: ContainerComponent = containers.get(l["container"])
		if c == null or c.first_empty() < 0:
			return 0
		l["slot"] = c.first_empty()
	if occupant(l) != 0:
		return 0
	var uid := _create(def_id, qty)
	_place(uid, l)
	revision += 1
	changed.emit()
	return uid


func world_items() -> Array[int]:
	var out: Array[int] = []
	for uid in locations:
		if locations[uid]["kind"] == "world":
			out.append(uid)
	return out


func equipped(owner: String, slot: String) -> int:
	var e: EquipmentComponent = equipment.get(owner)
	return int(e.slots.get(slot, 0)) if e else 0


func total_quantity(def_id: String) -> int:
	var n := 0
	for uid in items:
		if items[uid].def_id == def_id:
			n += items[uid].quantity
	return n


func _create(def_id: String, qty: int) -> int:
	var uid := _next_uid
	_next_uid += 1
	items[uid] = ItemInstance.new(uid, def_id, qty)
	return uid


func _place(uid: int, loc: Dictionary) -> void:
	locations[uid] = loc.duplicate()
	match loc["kind"]:
		"container":
			containers[loc["container"]].slots[int(loc["slot"])] = uid
		"equipment":
			equipment[loc["owner"]].slots[loc["slot"]] = uid


func _vacate(uid: int) -> void:
	var loc: Dictionary = locations.get(uid, {})
	match loc.get("kind", ""):
		"container":
			containers[loc["container"]].slots[int(loc["slot"])] = 0
		"equipment":
			equipment[loc["owner"]].slots[loc["slot"]] = 0
	locations.erase(uid)


func _destroy(uid: int) -> void:
	_vacate(uid)
	items.erase(uid)


## Returns human-readable violations; empty = consistent.
func check_invariants() -> PackedStringArray:
	var errs := PackedStringArray()
	var seen := {}
	for uid in items:
		var it: ItemInstance = items[uid]
		var d := def(it.def_id)
		if d == null:
			errs.append("uid %d has unknown def %s" % [uid, it.def_id])
			continue
		if it.quantity < 1 or it.quantity > d.max_stack:
			errs.append("uid %d bad quantity %d" % [uid, it.quantity])
		if not locations.has(uid):
			errs.append("uid %d has no location" % uid)
			continue
		var loc: Dictionary = locations[uid]
		if loc["kind"] != "world" and occupant(loc) != uid:
			errs.append("uid %d location %s not reflected in slot" % [uid, ItemLocation.describe(loc)])
	for uid in locations:
		if not items.has(uid):
			errs.append("location for missing uid %d" % uid)
	for cid in containers:
		var c: ContainerComponent = containers[cid]
		for s in c.capacity:
			var u: int = c.slots[s]
			if u == 0:
				continue
			if seen.has(u):
				errs.append("uid %d in two slots" % u)
			seen[u] = true
			if not ItemLocation.same(locations.get(u, {}), ItemLocation.container(cid, s)):
				errs.append("slot %s[%d] holds uid %d whose location differs" % [cid, s, u])
	for owner in equipment:
		var e: EquipmentComponent = equipment[owner]
		for slot in e.slots:
			var u: int = e.slots[slot]
			if u == 0:
				continue
			if seen.has(u):
				errs.append("uid %d in two slots" % u)
			seen[u] = true
			if not ItemLocation.same(locations.get(u, {}), ItemLocation.equipment(owner, slot)):
				errs.append("equip %s.%s holds uid %d whose location differs" % [owner, slot, u])
	return errs
