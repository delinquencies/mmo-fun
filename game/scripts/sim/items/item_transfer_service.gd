class_name ItemTransferService
extends RefCounted
## The only path by which items change location. Every transfer is planned
## (validated against current authoritative state) before it is committed, so a
## stale, duplicated or out-of-range request fails without side effects.
##
## Access rules (range, open containers, blocked ground) are supplied by the
## owner as a Callable: access(actor, location, purpose: "take"|"put") -> code.

const MESSAGES := {
	"no_item": "That item no longer exists.",
	"stale": "That item is no longer there.",
	"bad_qty": "That is not a valid amount.",
	"too_far": "That is too far away.",
	"not_open": "You must open that container first.",
	"full": "That container is full.",
	"stack_full": "That stack cannot hold any more.",
	"cannot_equip": "You cannot equip that there.",
	"reserved": "That slot is not yet available.",
	"occupied": "You already have something equipped there.",
	"blocked": "You cannot place that there.",
	"not_yours": "That does not belong to you.",
	"invalid_dest": "You cannot put that there.",
	"no_change": "",
	"storage_unavailable": "The realm's records could not be updated; nothing was changed. Try again shortly.",
	"version_conflict": "That could not be done; the records disagree. Nothing was changed.",
	"conflict": "That could not be done; the records disagree. Nothing was changed.",
	"constraint": "That could not be done; the records refused it. Nothing was changed.",
}

var store: ItemStore
var access: Callable
## Optional durable gate: persist(actor, plan, changes) -> "" when the change is
## durably committed, otherwise a failure code. Called after validation and
## BEFORE memory is touched, so a storage failure leaves everything unchanged.
var persist: Callable


func _init(p_store: ItemStore, p_access: Callable) -> void:
	store = p_store
	access = p_access


static func fail(code: String) -> Dictionary:
	return {"ok": false, "code": code, "message": MESSAGES.get(code, code)}


func _can_merge(target_uid: int, def_id: String, qty: int) -> bool:
	var t := store.item(target_uid)
	var d := store.def(def_id)
	return t != null and d.stackable and t.def_id == def_id and t.quantity + qty <= d.max_stack


## Validate without mutating. qty <= 0 means "the whole stack".
func plan(actor: String, uid: int, from: Dictionary, to: Dictionary, qty: int = 0) -> Dictionary:
	var it := store.item(uid)
	if it == null:
		return fail("no_item")
	var cur := store.location(uid)
	if not ItemLocation.same(cur, from):
		return fail("stale")
	var d := store.def(it.def_id)
	var q := it.quantity if qty <= 0 else qty
	if q < 1 or q > it.quantity or (q < it.quantity and not d.stackable):
		return fail("bad_qty")
	var code: String = access.call(actor, cur, "take")
	if code != "":
		return fail(code)
	code = access.call(actor, to, "put")
	if code != "":
		return fail(code)

	var dest := to.duplicate()
	var merge := 0
	var swap := 0
	match to.get("kind", ""):
		"container":
			var c: ContainerComponent = store.containers.get(to["container"])
			if c == null:
				return fail("invalid_dest")
			var slot := int(to["slot"])
			if slot >= c.capacity:
				return fail("invalid_dest")
			if slot >= 0:
				var occ: int = c.slots[slot]
				if occ == uid:
					return fail("no_change")
				if occ != 0:
					if _can_merge(occ, it.def_id, q):
						merge = occ
					elif store.item(occ).def_id == it.def_id and d.stackable:
						return fail("stack_full")
					else:
						slot = -1
			if slot < 0 and merge == 0:
				if d.stackable:
					for s in c.capacity:
						var o: int = c.slots[s]
						if o != 0 and o != uid and _can_merge(o, it.def_id, q):
							merge = o
							break
				if merge == 0:
					if cur["kind"] == "container" and cur["container"] == c.id and q == it.quantity:
						return fail("no_change")
					slot = c.first_empty()
					if slot < 0:
						return fail("full")
			dest = store.location(merge) if merge else ItemLocation.container(c.id, slot)
		"equipment":
			var e: EquipmentComponent = store.equipment.get(to["owner"])
			if e == null or not e.slots.has(to["slot"]):
				return fail("invalid_dest")
			if e.is_reserved(to["slot"]):
				return fail("reserved")
			if d.equip_slot != to["slot"]:
				return fail("cannot_equip")
			if q != it.quantity:
				return fail("bad_qty")
			var occ: int = e.slots[to["slot"]]
			if occ == uid:
				return fail("no_change")
			if occ != 0:
				if cur["kind"] == "container":
					swap = occ
				else:
					return fail("occupied")
		"world":
			if not (to.get("pos") is Vector2):
				return fail("invalid_dest")
			if cur["kind"] == "world" and (cur["pos"] as Vector2).distance_to(to["pos"]) < 0.01:
				return fail("no_change")
		_:
			return fail("invalid_dest")
	return {"ok": true, "code": "", "message": "", "actor": actor, "uid": uid, "def": it.def_id,
		"from": cur.duplicate(), "to": dest, "qty": q, "split": q < it.quantity, "merge": merge, "swap": swap}


## The rows a plan changes, in storage terms (version = what we last saw; 0 = new).
func durable_changes(p: Dictionary) -> Array:
	var uid: int = p["uid"]
	var it := store.item(uid)
	var q: int = p["qty"]
	var ch: Array = []
	var row := func(id: int, def: String, qty: int, loc: Dictionary, ver: int) -> Dictionary:
		return {"op": "upsert", "uid": id, "def": def, "qty": qty, "loc": ItemLocation.to_wire(loc), "expect_version": ver}
	if p["split"]:
		ch.append(row.call(uid, it.def_id, it.quantity - q, store.location(uid), it.version))
		if p["merge"]:
			var m := store.item(p["merge"])
			ch.append(row.call(m.uid, m.def_id, m.quantity + q, store.location(m.uid), m.version))
		else:
			if not p.has("new_uid"):
				p["new_uid"] = store.reserve_uid()
			ch.append(row.call(p["new_uid"], it.def_id, q, p["to"], 0))
	elif p["swap"]:
		var o := store.item(p["swap"])
		ch.append(row.call(o.uid, o.def_id, o.quantity, p["from"], o.version))
		ch.append(row.call(uid, it.def_id, it.quantity, p["to"], it.version))
	elif p["merge"]:
		var m := store.item(p["merge"])
		ch.append(row.call(m.uid, m.def_id, m.quantity + it.quantity, store.location(m.uid), m.version))
		ch.append({"op": "delete", "uid": uid, "expect_version": it.version})
	else:
		ch.append(row.call(uid, it.def_id, it.quantity, p["to"], it.version))
	return ch


## Run the durable gate (if any). "" = committed (or no gate).
func persist_plan(p: Dictionary) -> String:
	if not persist.is_valid():
		return ""
	var changes := durable_changes(p)
	p["changes"] = changes
	return str(persist.call(p["actor"], p, changes))


## Apply a plan produced by plan(). Returns presentation events.
func commit(p: Dictionary) -> Array:
	var uid: int = p["uid"]
	var it := store.item(uid)
	var events: Array = []
	var result_uid := uid
	if p["split"]:
		it.quantity -= int(p["qty"])
		if p["merge"]:
			store.item(p["merge"]).quantity += int(p["qty"])
			result_uid = p["merge"]
		else:
			result_uid = store._create(it.def_id, int(p["qty"]), int(p.get("new_uid", 0)))
			store._place(result_uid, p["to"])
	elif p["swap"]:
		var other: int = p["swap"]
		store._vacate(uid)
		store._vacate(other)
		store._place(other, p["from"])
		store._place(uid, p["to"])
		events.append({"type": "item_moved", "uid": other, "def": store.item(other).def_id,
			"from": p["to"], "to": p["from"], "qty": store.item(other).quantity, "actor": p["actor"]})
	elif p["merge"]:
		store.item(p["merge"]).quantity += it.quantity
		store._destroy(uid)
		result_uid = p["merge"]
	else:
		store._vacate(uid)
		store._place(uid, p["to"])
	events.append({"type": "item_moved", "uid": result_uid, "source_uid": uid, "def": p["def"],
		"from": p["from"], "to": p["to"], "qty": p["qty"], "actor": p["actor"]})
	for ch in p.get("changes", []):   # mirror the database's version bump
		var ci := store.item(int(ch["uid"]))
		if ci and ch["op"] == "upsert" and int(ch["expect_version"]) > 0:
			ci.version = int(ch["expect_version"]) + 1
	store.revision += 1
	var errs := store.check_invariants()
	if not errs.is_empty():
		push_error("ITEM INVARIANT VIOLATION after transfer: %s" % "; ".join(errs))
	store.changed.emit()
	return events
