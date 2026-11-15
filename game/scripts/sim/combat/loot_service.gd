class_name LootService
## Server-authoritative loot rolls from data-driven tables (data/combat.json).


static func roll(tables: Dictionary, table_id: String, rng: RandomNumberGenerator, defs: Dictionary) -> Array:
	var out := []
	for entry in tables.get(table_id, []):
		if rng.randf() > float(entry.get("chance", 1.0)):
			continue
		var q: Array = entry.get("qty", [1, 1])
		var qty := rng.randi_range(int(q[0]), int(q[1]))
		var d: ItemDefinition = defs.get(entry["item"])
		if d == null or qty < 1:
			continue
		out.append([entry["item"], mini(qty, d.max_stack)])
	return out
