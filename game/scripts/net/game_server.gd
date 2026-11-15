class_name GameServer
extends Node
## Authoritative dedicated server for one world region.
##
## Owns the only WorldSim that decides anything. Clients send movement intent
## (INPUT) and InteractionCommands (CMD); the server validates, advances a fixed
## tick simulation and replicates results:
##   * player state  - unreliable, STATE_RATE Hz, per-client interest filtered
##   * world entities - reliable ENTITY on change
##   * items          - reliable ITEMS diffs against what each client may see
##   * events/results - reliable, only to the peers concerned
##
## This node must be the root of its own SceneMultiplayer branch (it sets that
## up itself), with its NetChannel child named "Net".

signal log_line(text: String)

var sim: WorldSim
var net := NetChannel.new()
var enet: ENetMultiplayerPeer
var port := Protocol.DEFAULT_PORT
var tick_rate := Protocol.TICK_RATE
var state_rate := Protocol.STATE_RATE
var linger := Protocol.LINGER
var max_clients := 16
var bind_ip := "127.0.0.1"         # localhost by default; LAN needs an explicit bind
var verbose := true

var sessions: Dictionary = {}     # peer id -> Dictionary (see _new_session)
var tick := 0
var time := 0.0
var _acc := 0.0
var _state_acc := 0.0
var _items_dirty := true
var _known: Dictionary = {}       # peer -> {uid: signature} (what that client holds)
var _event_peer := 0              # peer whose command is executing (routes actor events)
var stats := {"commands": 0, "command_failures": 0, "duplicates": 0, "invalid_messages": 0,
	"rejected_inputs": 0, "excess_inputs": 0, "stale_inputs": 0, "joins": 0, "leaves": 0}


func _enter_tree() -> void:
	get_tree().set_multiplayer(SceneMultiplayer.new(), get_path())
	add_child(net)


func start(p_port: int = Protocol.DEFAULT_PORT) -> Error:
	port = p_port
	sim = WorldSim.new()
	sim.load_map(Protocol.MAP, false)
	sim.local_actor = ""
	sim.interaction.event_emitted.connect(_on_sim_event)
	enet = ENetMultiplayerPeer.new()
	enet.set_bind_ip(bind_ip)
	var err := enet.create_server(port, max_clients)
	if err != OK:
		_log("could not listen on port %d (%s)" % [port, error_string(err)])
		return err
	var smp := multiplayer as SceneMultiplayer
	smp.server_relay = false            # clients may only talk to the server
	smp.allow_object_decoding = false
	multiplayer.multiplayer_peer = enet
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	net.received.connect(_on_message)
	_log("listening on %s:%d  (tick %d Hz, state %d Hz, protocol v%d)" % [bind_ip, port, tick_rate, state_rate, Protocol.VERSION])
	return OK


func stop() -> void:
	if enet:
		enet.close()
	multiplayer.multiplayer_peer = null
	_log("stopped")


func _log(t: String) -> void:
	if verbose:
		print("[server %7.2f] %s" % [time, t])
	log_line.emit(t)


# --- sessions ------------------------------------------------------------------

func _new_session(peer: int) -> Dictionary:
	return {"peer": peer, "state": "pending", "session": "", "actor": "", "name": "",
		"connected_at": time, "inputs": [], "last_seq": 0, "applied_seq": 0, "last_input_time": 0.0,
		"rids": {}, "rid_order": [], "invalid": 0, "linger_until": 0.0}


func _on_peer_connected(peer: int) -> void:
	sessions[peer] = _new_session(peer)
	var p := enet.get_peer(peer)
	if p:
		p.set_timeout(0, 2000, 6000)   # detect dead clients within ~6 s


func _on_peer_disconnected(peer: int) -> void:
	var s: Dictionary = sessions.get(peer, {})
	if s.is_empty():
		return
	if s["state"] == "active":
		s["state"] = "linkdead"
		s["linger_until"] = time + linger
		s["inputs"].clear()
		sim.interaction.close_all_for(s["actor"])
		var ps: PlayerState = sim.players.get(s["actor"])
		if ps:
			ps.linkdead = true
			ps.moving = false
		_broadcast(Protocol.make(Protocol.PLAYER_STATUS, {"actor": s["actor"], "linkdead": true}))
		_log("%s (%s) lost connection - link-dead for %.0fs" % [s["name"], s["session"], linger])
	elif s["state"] != "linkdead":
		sessions.erase(peer)
	_known.erase(peer)


func _remove_session(peer: int, reason: String) -> void:
	var s: Dictionary = sessions.get(peer, {})
	if s.is_empty():
		return
	sessions.erase(peer)
	_known.erase(peer)
	if s["actor"] != "" and sim.players.has(s["actor"]):
		sim.interaction.close_all_for(s["actor"])
		var dropped := sim.remove_player(s["actor"])
		_items_dirty = true
		_broadcast(Protocol.make(Protocol.PLAYER_LEAVE, {"actor": s["actor"], "reason": reason}))
		stats["leaves"] += 1
		_log("%s (%s) removed: %s; %d carried item(s) left on the ground" % [s["name"], s["session"], reason, dropped.size()])


func _kick(peer: int, reason: String) -> void:
	net.send(peer, Protocol.make(Protocol.REJECT, {"reason": reason}))
	net.flush_all()
	var s: Dictionary = sessions.get(peer, {})
	if s.get("state", "") == "active":
		_remove_session(peer, reason)
	else:
		sessions.erase(peer)
	if multiplayer.get_peers().has(peer):
		enet.disconnect_peer(peer)


# --- messages --------------------------------------------------------------------

func _on_message(peer: int, msg: Variant, _reliable: bool) -> void:
	var s: Dictionary = sessions.get(peer, {})
	if s.is_empty() or s["state"] == "linkdead":
		return
	var err := Protocol.validate(msg, Protocol.CLIENT_TO_SERVER)
	if err != "":
		stats["invalid_messages"] += 1
		s["invalid"] += 1
		if s["state"] == "pending":
			_kick(peer, "protocol: " + err)
		elif s["invalid"] > 50:
			_kick(peer, "too many invalid messages")
		return
	match msg["t"]:
		Protocol.HELLO:
			_on_hello(peer, s, msg)
		Protocol.CMD:
			if s["state"] == "active":
				_on_command(peer, s, msg)
		Protocol.INPUT:
			if s["state"] == "active":
				_on_input(s, msg)
		Protocol.PING:
			net.send(peer, Protocol.make(Protocol.PONG, {"time": float(msg["time"]), "server_time": time}))
		Protocol.BYE:
			if s["state"] == "active":
				_remove_session(peer, "left the world")
			else:
				sessions.erase(peer)
			enet.disconnect_peer(peer)


func _on_hello(peer: int, s: Dictionary, msg: Dictionary) -> void:
	if s["state"] != "pending":
		return
	var nm := Protocol.sanitize_name(str(msg["name"]))
	if nm == "":
		nm = "Wanderer"
	var taken := {}
	for o in sessions.values():
		taken[o["name"]] = true
	var base := nm
	var n := 2
	while taken.has(nm):
		nm = "%s %d" % [base, n]
		n += 1
	var sid := "%08x" % (randi() & 0x7fffffff)
	var actor := "pc_" + sid
	s["session"] = sid
	s["actor"] = actor
	s["name"] = nm
	s["state"] = "active"
	s["last_input_time"] = time
	var spawn := sim._free_drop_spot(sim.spawn_point + Vector2(0.9, 0.0).rotated(sim.players.size() * 1.9) * minf(1.0, sim.players.size()))
	sim.add_player(actor, nm, spawn)
	stats["joins"] += 1
	var players := []
	for a in sim.players:
		players.append(_player_record(sim.players[a]))
	var ents := []
	for id in sim.entities:
		ents.append([id, sim.entities[id].open])
	net.send(peer, Protocol.make(Protocol.WELCOME, {"session": sid, "actor": actor, "name": nm,
		"tick_rate": tick_rate, "state_rate": state_rate, "time": time, "players": players, "entities": ents}))
	for o in sessions.values():
		if o["peer"] != peer and o["state"] == "active":
			net.send(o["peer"], Protocol.make(Protocol.PLAYER_JOIN, {"player": _player_record(sim.players[actor])}))
	_known[peer] = {}
	_items_dirty = true
	_flush_items()
	_log("%s joined as %s (session %s, peer %d)" % [nm, actor, sid, peer])


func _player_record(ps: PlayerState) -> Array:
	return [ps.actor, ps.display_name, ps.pos.x, ps.pos.y, ps.facing, ps.linkdead]


func _on_command(peer: int, s: Dictionary, msg: Dictionary) -> void:
	var rid: int = msg["rid"]
	if s["rids"].has(rid):
		# duplicate delivery or replay: answer again, never execute twice
		stats["duplicates"] += 1
		net.send(peer, s["rids"][rid])
		return
	var res: Dictionary
	var cerr := Protocol.validate_command(msg["cmd"])
	if cerr != "":
		stats["invalid_messages"] += 1
		res = Protocol.make(Protocol.RESULT, {"rid": rid, "ok": false, "code": "invalid", "message": "Invalid request (%s)." % cerr})
	else:
		var wire: Dictionary = msg["cmd"].duplicate(true)
		wire["actor"] = s["actor"]          # identity comes from the session, never the payload
		wire["seq"] = rid
		var cmd := InteractionCommand.from_wire(wire)
		_event_peer = peer
		var r := sim.interaction.submit(cmd)
		_event_peer = 0
		stats["commands"] += 1
		if not r.ok:
			stats["command_failures"] += 1
		res = Protocol.make(Protocol.RESULT, {"rid": rid, "ok": r.ok, "code": r.code, "message": r.message})
	s["rids"][rid] = res
	s["rid_order"].append(rid)
	if s["rid_order"].size() > Protocol.RID_CACHE:
		s["rids"].erase(s["rid_order"].pop_front())
	net.send(peer, res)
	_flush_items()


func _on_input(s: Dictionary, msg: Dictionary) -> void:
	var inputs: Array = msg["inputs"]
	if inputs.size() > Protocol.INPUT_REDUNDANCY + 2:
		stats["rejected_inputs"] += inputs.size()
		return
	for i in inputs:
		var e := Protocol.validate_input(i)
		if e != "":
			stats["rejected_inputs"] += 1
			continue
		var seq: int = i[0]
		if seq <= s["last_seq"]:
			stats["stale_inputs"] += 1      # redundant copy or out-of-order: already have it
			continue
		if s["inputs"].size() >= Protocol.MAX_INPUT_QUEUE:
			stats["excess_inputs"] += 1     # faster than the tick rate: dropped, never applied
			s["last_seq"] = seq
			continue
		s["last_seq"] = seq
		s["inputs"].append([seq, Vector2(float(i[1]), float(i[2])), bool(i[3])])


# --- simulation tick -------------------------------------------------------------

func _process(delta: float) -> void:
	if enet == null:
		return
	_acc += delta
	var dt := 1.0 / tick_rate
	var steps := 0
	while _acc >= dt and steps < 5:
		_acc -= dt
		steps += 1
		_tick(dt)
	if steps == 5:
		_acc = 0.0
	_state_acc += delta
	if _state_acc >= 1.0 / state_rate:
		_state_acc = fmod(_state_acc, 1.0 / state_rate)
		_send_states()


func _tick(dt: float) -> void:
	tick += 1
	time += dt
	for peer in sessions.keys():
		var s: Dictionary = sessions[peer]
		match s["state"]:
			"pending":
				if time - s["connected_at"] > Protocol.HELLO_TIMEOUT:
					_kick(peer, "no hello")
			"linkdead":
				if time >= s["linger_until"]:
					_remove_session(peer, "timed out")
			"active":
				# at most ONE input per tick: speed is bounded by the rules, not the client
				if not s["inputs"].is_empty():
					var inp: Array = s["inputs"].pop_front()
					sim.step_actor(s["actor"], dt, inp[1], inp[2])
					s["applied_seq"] = inp[0]
					s["last_input_time"] = time
				else:
					sim.step_actor(s["actor"], dt, Vector2.ZERO, false)
					if time - s["last_input_time"] > 30.0:
						_kick(peer, "idle timeout")
	sim.interaction.update(dt)
	if _items_dirty or sim.items.revision != _last_rev:
		_flush_items()


var _last_rev := -1


func _send_states() -> void:
	for peer in sessions:
		var s: Dictionary = sessions[peer]
		if s["state"] != "active":
			continue
		var me: PlayerState = sim.players.get(s["actor"])
		var list := []
		for a in sim.players:
			var ps: PlayerState = sim.players[a]
			if a == s["actor"] or me.pos.distance_to(ps.pos) <= Protocol.INTEREST_RADIUS:
				list.append([a, ps.pos.x, ps.pos.y, ps.facing, ps.moving, ps.running])
		net.send(peer, Protocol.make(Protocol.STATE, {"tick": tick, "time": time, "ack": s["applied_seq"], "players": list}), false)


# --- item interest -----------------------------------------------------------------

func _visible(actor: String, loc: Dictionary) -> bool:
	match loc.get("kind", ""):
		"world":
			return sim.actor_pos(actor).distance_to(loc["pos"]) <= Protocol.INTEREST_RADIUS
		"container":
			var c: ContainerComponent = sim.items.containers.get(loc["container"])
			return c != null and (c.owner_entity == actor or sim.interaction.is_open(actor, c.id))
		"equipment":
			return true   # everyone needs to see what a character wields
	return false


## Send each client exactly the item changes it is allowed to know about.
func _flush_items() -> void:
	_items_dirty = false
	_last_rev = sim.items.revision
	for peer in sessions:
		var s: Dictionary = sessions[peer]
		if s["state"] != "active":
			continue
		var known: Dictionary = _known.get_or_add(peer, {})
		var up := []
		var seen := {}
		for uid in sim.items.items:
			var loc := sim.items.location(uid)
			if not _visible(s["actor"], loc):
				continue
			seen[uid] = true
			var sig := sim.items.signature(uid)
			if known.get(uid, "") != sig:
				var it := sim.items.item(uid)
				up.append([uid, it.def_id, it.quantity, ItemLocation.to_wire(loc)])
				known[uid] = sig
		var rm := []
		for uid in known.keys():
			if not seen.has(uid):
				rm.append(uid)
				known.erase(uid)
		if not up.is_empty() or not rm.is_empty():
			net.send(peer, Protocol.make(Protocol.ITEMS, {"up": up, "rm": rm}))


# --- event routing -------------------------------------------------------------------

func _peer_of(actor: String) -> int:
	for peer in sessions:
		if sessions[peer]["actor"] == actor and sessions[peer]["state"] == "active":
			return peer
	return 0


func _on_sim_event(e: Dictionary) -> void:
	match e["type"]:
		"door_changed", "chest_changed":
			_broadcast(Protocol.make(Protocol.ENTITY, {"id": e["id"], "open": e["open"]}))
		"sound":
			for peer in sessions:
				var s: Dictionary = sessions[peer]
				if s["state"] == "active" and sim.actor_pos(s["actor"]).distance_to(e["pos"]) <= Protocol.INTEREST_RADIUS:
					net.send(peer, Protocol.make(Protocol.EVENT, {"e": Protocol.event_to_wire(e)}))
		"container_opened", "container_closed":
			_items_dirty = true
			_to_actor(e)
		_:
			_to_actor(e)


func _to_actor(e: Dictionary) -> void:
	var peer := _peer_of(str(e.get("actor", "")))
	if peer:
		net.send(peer, Protocol.make(Protocol.EVENT, {"e": Protocol.event_to_wire(e)}))


func _broadcast(msg: Dictionary) -> void:
	for peer in sessions:
		if sessions[peer]["state"] == "active":
			net.send(peer, msg)


func active_count() -> int:
	var n := 0
	for s in sessions.values():
		if s["state"] == "active":
			n += 1
	return n
