class_name NpcState
extends RefCounted
## A server-simulated creature. Its definition comes from data/combat.json and
## its placement (spawn, patrol) from the map. Never persisted: creatures reset
## on server start and respawn after death (docs/COMBAT.md).

var id: String                   # stable network id, e.g. "n:wolf_1"
var archetype: String
var def: Dictionary
var spawn := Vector2.ZERO
var patrol: Array = []           # optional waypoints (bandit)
var pos := Vector2.ZERO
var facing := 0
var moving := false
var running := false
var state := "idle"              # idle | wander | chase | return | retreat | dead
var combat: Combatant
var goal := Vector2.INF          # current movement goal
var think_at := 0.0
var state_until := 0.0
var respawn_at := 0.0
var stuck := 0.0
var patrol_i := 0
var strafe_dir := 1.0
var anim_time := 0.0
var swing_started := -1.0        # presentation (replica): when the last attack began
var render_pos := Vector2.ZERO
var render_facing := 0
var render_moving := false


func display_name() -> String:
	return def.get("name", archetype)
