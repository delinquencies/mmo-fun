class_name Combatant
extends RefCounted
## Combat state shared by players and creatures: resources, defence, timing,
## status effects. Mutated only by CombatSystem (server / offline authority).

var id: String
var hp := 60.0
var hp_max := 60.0
var st := 60.0
var st_max := 60.0
var mn := 40.0
var mn_max := 40.0
var attack := 10.0
var defense := 8.0
var dead := false
var target := ""                 # entity id this combatant is attacking
var next_attack_at := 0.0
var pending: Dictionary = {}     # swing in progress {resolve_at, target, weapon}
var last_combat_at := -1e9
var statuses: Array = []         # [{id, until, next_tick, source}]
var invulnerable_until := 0.0


func _init(p_id: String) -> void:
	id = p_id


func alive() -> bool:
	return not dead


func has_status(sid: String) -> bool:
	for s in statuses:
		if s["id"] == sid:
			return true
	return false


func vitals() -> Array:
	return [roundi(hp), roundi(hp_max), roundi(st), roundi(st_max), roundi(mn), roundi(mn_max)]


func hp_pct() -> int:
	return clampi(roundi(hp / maxf(hp_max, 1.0) * 100.0), 0, 100)


func to_save() -> Dictionary:
	return {"hp": hp, "st": st, "mn": mn}


func load_save(d: Dictionary) -> void:
	hp = clampf(float(d.get("hp", hp_max)), 1.0, hp_max)
	st = clampf(float(d.get("st", st_max)), 0.0, st_max)
	mn = clampf(float(d.get("mn", mn_max)), 0.0, mn_max)
