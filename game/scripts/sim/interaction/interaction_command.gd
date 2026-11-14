class_name InteractionCommand
extends RefCounted
## Player intent, expressed as data. The client builds commands; only
## InteractionSystem validates and applies them. Commands serialise via
## to_wire()/from_wire() so the same objects can later be sent to an
## authoritative server unchanged.
##
## Types and args:
##   "use"             {entity: String}                      door / chest / ground item ("item:<uid>")
##   "transfer"        {uid: int, from: Location, to: Location, qty: int (0 = all)}
##   "use_item"        {uid: int, from: Location}            double-click: equip / unequip / pick up
##   "close_container" {container: String}

static var _seq := 0

var seq: int
var type: String
var actor: String
var args: Dictionary


static func make(p_type: String, p_actor: String, p_args: Dictionary) -> InteractionCommand:
	var c := InteractionCommand.new()
	_seq += 1
	c.seq = _seq
	c.type = p_type
	c.actor = p_actor
	c.args = p_args
	return c


static func use_entity(actor: String, entity_id: String) -> InteractionCommand:
	return make("use", actor, {"entity": entity_id})


static func transfer(actor: String, uid: int, from: Dictionary, to: Dictionary, qty: int = 0) -> InteractionCommand:
	return make("transfer", actor, {"uid": uid, "from": from, "to": to, "qty": qty})


static func use_item(actor: String, uid: int, from: Dictionary) -> InteractionCommand:
	return make("use_item", actor, {"uid": uid, "from": from})


static func close_container(actor: String, cid: String) -> InteractionCommand:
	return make("close_container", actor, {"container": cid})


func to_wire() -> Dictionary:
	var a := args.duplicate()
	for k in ["from", "to"]:
		if a.has(k):
			a[k] = ItemLocation.to_wire(a[k])
	return {"seq": seq, "type": type, "actor": actor, "args": a}


static func from_wire(d: Dictionary) -> InteractionCommand:
	var a: Dictionary = d["args"].duplicate()
	for k in ["from", "to"]:
		if a.has(k):
			a[k] = ItemLocation.from_wire(a[k])
	if a.has("uid"):
		a["uid"] = int(a["uid"])
	var c := make(d["type"], d["actor"], a)
	c.seq = int(d.get("seq", c.seq))
	return c
