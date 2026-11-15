class_name NpcAI
## Reusable creature behaviour components. Each archetype's brain is a small
## composition of these (see CombatSystem._think): detection, target selection,
## navigation (steering with obstacle probing - no per-frame pathfinding),
## pursuit, leashing, wandering, retreat and strafing.


## Detection + target selection: nearest living player within `radius` that the
## creature can see.
static func detect(sim: WorldSim, npc: NpcState, radius: float) -> String:
	var best := ""
	var bd := radius
	for a in sim.players:
		var ps: PlayerState = sim.players[a]
		if ps.combat == null or ps.combat.dead or ps.linkdead:
			continue
		var d := ps.pos.distance_to(npc.pos)
		if d < bd and sim.line_clear(npc.pos, ps.pos):
			best = a
			bd = d
	return best


## Navigation: move toward `goal` at `speed`, probing alternative headings when
## blocked (±45°, ±90°, ±135°). Returns true when the goal is reached.
static func navigate(sim: WorldSim, npc: NpcState, goal: Vector2, speed: float, dt: float, stop_at := 0.1) -> bool:
	var to := goal - npc.pos
	var dist := to.length()
	if dist <= stop_at:
		npc.moving = false
		return true
	var step := minf(speed * dt, dist - stop_at * 0.5)
	var dir := to / dist
	var r: float = npc.def.get("radius", 0.3)
	for ang in [0.0, 0.785, -0.785, 1.571, -1.571, 2.356, -2.356]:
		var d2 := dir.rotated(ang)
		var np := npc.pos + d2 * step
		if not sim.is_blocked(np, r):
			npc.pos = np
			npc.facing = Iso.dir_index(d2)
			npc.moving = true
			npc.stuck = 0.0 if ang == 0.0 else npc.stuck + dt
			return false
	npc.moving = false
	npc.stuck += dt
	return false


static func face(npc: NpcState, at: Vector2) -> void:
	if at.distance_squared_to(npc.pos) > 0.0001:
		npc.facing = Iso.dir_index(at - npc.pos)


## Pick a wander point inside the home radius that is not blocked.
static func wander_point(sim: WorldSim, npc: NpcState, rng: RandomNumberGenerator) -> Vector2:
	var hr: float = npc.def.get("home_radius", 2.0)
	for i in 8:
		var p := npc.spawn + Vector2(rng.randf_range(-hr, hr), rng.randf_range(-hr, hr))
		if not sim.is_blocked(p, npc.def.get("radius", 0.3)):
			return p
	return npc.spawn


## Leash: too far from home (or target fled) -> give up.
static func beyond_leash(npc: NpcState) -> bool:
	return npc.pos.distance_to(npc.spawn) > float(npc.def.get("leash", 10.0))


## Retreat point: directly away from the threat, a few tiles.
static func flee_point(npc: NpcState, threat: Vector2) -> Vector2:
	var away := (npc.pos - threat).normalized()
	if away == Vector2.ZERO:
		away = Vector2(1, 0)
	return npc.pos + away * 4.0


## Strafe point: sidestep around the target to reposition between attacks.
static func strafe_point(npc: NpcState, target: Vector2) -> Vector2:
	var rel := npc.pos - target
	return target + rel.rotated(0.9 * npc.strafe_dir).normalized() * maxf(1.0, rel.length())
