class_name ItemLocation
## Item locations are plain Dictionaries so they serialise directly into
## commands (future network messages):
##   {"kind": "container", "container": <id>, "slot": <int, -1 = any>}
##   {"kind": "world", "pos": Vector2}
##   {"kind": "equipment", "owner": <actor id>, "slot": <slot name>}


static func container(cid: String, slot: int = -1) -> Dictionary:
	return {"kind": "container", "container": cid, "slot": slot}


static func world(pos: Vector2) -> Dictionary:
	return {"kind": "world", "pos": pos}


static func equipment(owner: String, slot: String) -> Dictionary:
	return {"kind": "equipment", "owner": owner, "slot": slot}


static func same(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty() or a.get("kind") != b.get("kind"):
		return false
	match a["kind"]:
		"container":
			return a["container"] == b["container"] and int(a["slot"]) == int(b["slot"])
		"world":
			return (a["pos"] as Vector2).distance_to(b["pos"]) < 0.001
		"equipment":
			return a["owner"] == b["owner"] and a["slot"] == b["slot"]
	return false


static func describe(l: Dictionary) -> String:
	match l.get("kind", ""):
		"container":
			return "%s[%d]" % [l["container"], int(l["slot"])]
		"world":
			return "world(%.2f, %.2f)" % [l["pos"].x, l["pos"].y]
		"equipment":
			return "%s.%s" % [l["owner"], l["slot"]]
	return "<none>"


static func to_wire(l: Dictionary) -> Dictionary:
	var o := l.duplicate()
	if o.get("kind") == "world":
		o["pos"] = [o["pos"].x, o["pos"].y]
	return o


static func from_wire(o: Dictionary) -> Dictionary:
	var l := o.duplicate()
	if l.get("kind") == "world" and l["pos"] is Array:
		l["pos"] = Vector2(l["pos"][0], l["pos"][1])
	return l
