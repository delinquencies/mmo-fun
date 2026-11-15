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

# --- Slice 004: persistence -------------------------------------------------
var persistent := false            # accounts + characters + durable world (needs Keeper)
var keeper: KeeperClient
var server_id := "homestead-1"     # stable per region server: its stale locks are released on restart
var region := "homestead"
var realm_name := "The Homestead"
var tls: TLSOptions                # DTLS for client traffic (credentials)
var checkpoint_every := 10.0
var _checkpoint_acc := 0.0
var _unresolved: Dictionary = {}   # an item op whose commit outcome is unknown (blocks item commands)
var _auth_rate: Dictionary = {}    # peer -> [timestamps] of AUTH/CHARS requests
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
	if persistent:
		var perr := _start_persistence()
		if perr != OK:
			return perr
	var loopback := bind_ip == "127.0.0.1" or bind_ip == "localhost" or bind_ip == "::1"
	if persistent and not loopback and tls == null:
		_log("refusing to start: accounts over a non-loopback bind require DTLS (--tls_cert/--tls_key or dev certificate)")
		return ERR_UNAUTHORIZED
	enet = ENetMultiplayerPeer.new()
	enet.set_bind_ip(bind_ip)
	var err := enet.create_server(port, max_clients)
	if err != OK:
		_log("could not listen on port %d (%s)" % [port, error_string(err)])
		return err
	if tls:
		err = enet.host.dtls_server_setup(tls)
		if err != OK:
			_log("DTLS setup failed (%s)" % error_string(err))
			return err
	var smp := multiplayer as SceneMultiplayer
	smp.server_relay = false            # clients may only talk to the server
	smp.allow_object_decoding = false
	multiplayer.multiplayer_peer = enet
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	net.received.connect(_on_message)
	_log(("persistent realm '%s', DTLS %s; " % [realm_name, "on" if tls else "off"]) if persistent else "temporary sessions; ")
	_log("listening on %s:%d  (tick %d Hz, state %d Hz, protocol v%d)" % [bind_ip, port, tick_rate, state_rate, Protocol.VERSION])
	return OK


func stop() -> void:
	if persistent:
		_save_everyone("server shutdown")
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
		"rids": {}, "rid_order": [], "invalid": 0, "linger_until": 0.0,
		"account_id": 0, "username": "", "token": "", "character_id": 0, "busy": false}


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
	_auth_rate.erase(peer)


func _remove_session(peer: int, reason: String) -> void:
	var s: Dictionary = sessions.get(peer, {})
	if s.is_empty():
		return
	sessions.erase(peer)
	_known.erase(peer)
	if s["actor"] != "" and sim.players.has(s["actor"]) and persistent:
		_save_and_unload(s, reason)
		return
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
		Protocol.AUTH:
			if persistent and s["state"] in ["auth", "account"]:
				_on_auth(peer, s, msg)
		Protocol.CHARS:
			if persistent and s["state"] in ["auth", "account", "active"]:
				_on_chars(peer, s, msg)
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
	if persistent:
		s["state"] = "auth"
		net.send(peer, Protocol.make(Protocol.REALM, {"persistent": true, "realm": realm_name,
			"max_characters": Protocol.MAX_CHARACTERS, "secure": tls != null}))
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
	return [ps.actor, ps.display_name, ps.pos.x, ps.pos.y, ps.facing, ps.linkdead, ps.appearance]


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
	if persistent:
		_checkpoint_acc += dt
		if _checkpoint_acc >= checkpoint_every:
			_checkpoint_acc = 0.0
			_checkpoint()
		if not _unresolved.is_empty() and tick % 15 == 0:
			_resolve_unresolved()


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


# =============================================================================
# Slice 004: persistence (accounts, characters, durable items and world)
# =============================================================================

func _start_persistence() -> Error:
	keeper = KeeperClient.new()
	keeper.name = "Keeper"
	add_child(keeper)
	if keeper.secret == "":
		keeper.configure_from_env()
	if not keeper.ensure_connected(3.0):
		_log("cannot reach Keeper at %s:%d (%s) - start tools/keeper/run_keeper.sh" % [keeper.host, keeper.port, keeper.last_error])
		return ERR_CANT_CONNECT
	var r := keeper.call_sync("server_start", {"server_id": server_id}, 5.0)
	if not r.get("ok", false):
		_log("Keeper/database unavailable at startup (%s)" % r.get("code", "?"))
		return ERR_CANT_CONNECT
	# world: definitions, persistent objects and spawns -> stored state
	var defs := {}
	for d_id in sim.items.defs:
		var d: ItemDefinition = sim.items.defs[d_id]
		defs[d_id] = {"stackable": d.stackable, "max_stack": d.max_stack, "equip_slot": d.equip_slot, "name": d.name}
	var objects := []
	for e in sim.map_data.get("entities", []):
		var pol: String = e.get("persistence", "temporary")
		if pol == "temporary":
			continue
		var o := {"id": e["id"], "kind": sim.entities[e["id"]].kind, "policy": pol, "default_state": {"open": false}}
		if sim.entities[e["id"]].kind == "chest":
			var c: ContainerComponent = sim.items.containers[sim.entities[e["id"]].container_id]
			o["container"] = {"id": c.id, "capacity": c.capacity, "seed": e.get("contents", [])}
		objects.append(o)
	var spawns := []
	for g in sim.map_data.get("ground_items", []):
		if g.get("persistence", "temporary") != "temporary":
			spawns.append({"spawn_id": g["spawn_id"], "def": g["def"], "qty": int(g.get("qty", 1)),
				"x": g["x"], "y": g["y"], "policy": g["persistence"]})
	r = keeper.call_sync("world_load", {"region": region, "item_defs": defs, "objects": objects, "spawns": spawns}, 10.0)
	if not r.get("ok", false):
		_log("world load failed (%s)" % r.get("code", "?"))
		return ERR_CANT_CONNECT
	var data: Dictionary = r["data"]
	for id in data["states"]:
		if sim.entities.has(id):
			sim.entities[id].open = bool(data["states"][id].get("open", false)) and sim.entities[id].kind == "door"
	sim.items.load_rows(data["items"])
	sim.items._next_uid = maxi(sim.items._next_uid, int(data["max_item_id"]) + 1)
	if not data["orphaned"].is_empty():
		_log("WARNING: stored world objects no longer in the map (kept, not loaded): %s" % [data["orphaned"]])
	sim.interaction.transfers.persist = _persist_items
	sim.interaction.persist_world = _persist_world
	sim.interaction.item_guard = func() -> String: return "storage_unavailable" if not _unresolved.is_empty() else ""
	_log("persistent world loaded: %d items, seeded %s" % [data["items"].size(), data["seeded"]])
	return OK


## Durable gate for item operations: commit to PostgreSQL (via Keeper) BEFORE the
## in-memory change. Never retried blindly: an unknown outcome is resolved by op id.
func _persist_items(actor: String, plan: Dictionary, changes: Array) -> String:
	var op_id := KeeperClient.new_op_id()
	var args := {"op_id": op_id, "actor": actor, "kind": "transfer", "region": region, "changes": changes}
	var r := keeper.call_sync("commit_items", args, 2.0)
	if r.get("ok", false):
		return ""
	var code: String = r.get("code", "storage_unavailable")
	if code == "timeout":
		# sent, but we do not know whether it committed: ask, never re-send
		var st := keeper.call_sync("op_status", {"op_id": op_id}, 1.0)
		if st.get("ok", false):
			return "" if st["data"]["committed"] else "storage_unavailable"
		_unresolved = {"op_id": op_id, "plan": plan}
		_log("item op %s outcome unknown: item commands paused until storage answers" % op_id)
		return "storage_unavailable"
	if code in ["version_conflict", "conflict", "constraint"]:
		_log("storage refused item op (%s) - memory and database disagree; investigate" % code)
	return code


func _resolve_unresolved() -> void:
	var st := keeper.call_sync("op_status", {"op_id": _unresolved["op_id"]}, 0.5)
	if not st.get("ok", false):
		return
	var plan: Dictionary = _unresolved["plan"]
	if st["data"]["committed"]:
		sim.interaction.transfers.commit(plan)   # storage has it: make memory agree
		_items_dirty = true
		_log("unknown item op %s resolved: committed (applied in memory)" % _unresolved["op_id"])
	else:
		_log("unknown item op %s resolved: not committed (nothing to do)" % _unresolved["op_id"])
	_unresolved = {}


func _persist_world(object_id: String, state: Dictionary) -> String:
	var r := keeper.call_sync("world_state", {"object_id": object_id, "state": state}, 2.0)
	return "" if r.get("ok", false) else "storage_unavailable"


const AUTH_MESSAGES := {
	"invalid_credentials": "Unknown account or wrong password.",
	"locked": "Too many failed attempts. Try again in a little while.",
	"rate_limited": "Too many attempts. Please wait a minute.",
	"username_taken": "That account name is taken.",
	"bad_username": "Account names are 3-24 letters, digits or underscores.",
	"bad_password": "Passwords must be 8-128 characters.",
	"session_invalid": "Your session has expired. Please log in again.",
	"disabled": "This account is disabled.",
	"storage_unavailable": "The realm's records are unavailable. Try again shortly.",
	"name_taken": "That name is already taken.",
	"bad_name": "Names are 3-16 letters (spaces or apostrophes inside), and some names are reserved.",
	"bad_appearance": "Unknown appearance.",
	"too_many_characters": "You already have the maximum of 3 characters.",
	"not_found": "That character is not available.",
	"locked_elsewhere": "That character is busy on another server. Try again shortly.",
	"already_in_world": "That character is already in the world.",
	"not_logged_in": "Log in first.",
	"busy": "Please wait for the previous request.",
	"invalid": "Invalid request.",
}


func _reply(peer: int, t: String, rid: int, ok: bool, code := "", data := {}) -> void:
	net.send(peer, Protocol.make(t, {"rid": rid, "ok": ok, "code": code,
		"message": AUTH_MESSAGES.get(code, "That could not be done.") if not ok else "", "data": data}))


func _rate_ok(peer: int) -> bool:
	var now := Time.get_ticks_msec()
	var q: Array = _auth_rate.get_or_add(peer, [])
	while not q.is_empty() and now - int(q[0]) > 10000:
		q.pop_front()
	if q.size() >= 8:
		return false
	q.append(now)
	return true


func _on_auth(peer: int, s: Dictionary, msg: Dictionary) -> void:
	var rid: int = msg["rid"]
	var op: String = msg["op"]
	var args: Dictionary = msg["args"]
	if Protocol.validate_op(Protocol.AUTH_OPS, op, args) != "":
		return _reply(peer, Protocol.AUTH_RESULT, rid, false, "invalid")
	if s["busy"]:
		return _reply(peer, Protocol.AUTH_RESULT, rid, false, "busy")
	if not _rate_ok(peer):
		return _reply(peer, Protocol.AUTH_RESULT, rid, false, "rate_limited")
	if op == "logout":
		if s["token"] != "":
			keeper.request("logout", {"token": s["token"]}, func(_r): pass)
		s["account_id"] = 0
		s["username"] = ""
		s["token"] = ""
		s["state"] = "auth"
		return _reply(peer, Protocol.AUTH_RESULT, rid, true)
	if s["state"] != "auth":
		return _reply(peer, Protocol.AUTH_RESULT, rid, false, "invalid")
	var kargs := args.duplicate()
	kargs["ip"] = enet.get_peer(peer).get_remote_address() if enet.get_peer(peer) else "?"
	s["busy"] = true
	keeper.request(op, kargs, func(r: Dictionary) -> void:
		s["busy"] = false
		if not sessions.has(peer):
			return
		if not r.get("ok", false):
			return _reply(peer, Protocol.AUTH_RESULT, rid, false, r.get("code", "storage_unavailable"))
		var d: Dictionary = r["data"]
		if op == "register":
			return _reply(peer, Protocol.AUTH_RESULT, rid, true, "", {"username": d["username"]})
		s["account_id"] = int(d["account_id"])
		s["username"] = d["username"]
		if op == "login":
			s["token"] = d["token"]
		elif op == "resume":
			s["token"] = args["token"]
		s["state"] = "account"
		_log("account %d authenticated on peer %d" % [s["account_id"], peer])   # never log tokens/passwords
		var out := {"username": d["username"]}
		if op == "login":
			out["token"] = d["token"]   # client keeps it in memory to resume after a dropped connection
		_reply(peer, Protocol.AUTH_RESULT, rid, true, "", out))


func _on_chars(peer: int, s: Dictionary, msg: Dictionary) -> void:
	var rid: int = msg["rid"]
	var op: String = msg["op"]
	var args: Dictionary = msg["args"]
	if Protocol.validate_op(Protocol.CHAR_OPS, op, args) != "":
		return _reply(peer, Protocol.CHARS_RESULT, rid, false, "invalid")
	if s["account_id"] == 0:
		return _reply(peer, Protocol.CHARS_RESULT, rid, false, "not_logged_in")
	if op == "leave":
		if s["state"] == "active":
			_save_and_unload(s, "left the world")
			s["state"] = "account"
			s["actor"] = ""
			s["character_id"] = 0
			net.send(peer, Protocol.make(Protocol.LEFT_WORLD, {"reason": "You left the world."}))
		return _reply(peer, Protocol.CHARS_RESULT, rid, true)
	if s["state"] != "account":
		return _reply(peer, Protocol.CHARS_RESULT, rid, false, "invalid")
	if s["busy"]:
		return _reply(peer, Protocol.CHARS_RESULT, rid, false, "busy")
	if not _rate_ok(peer):
		return _reply(peer, Protocol.CHARS_RESULT, rid, false, "rate_limited")
	var acct: int = s["account_id"]     # ownership always from the authenticated session
	match op:
		"list":
			s["busy"] = true
			keeper.request("char_list", {"account_id": acct}, func(r: Dictionary) -> void:
				s["busy"] = false
				if sessions.has(peer):
					_reply(peer, Protocol.CHARS_RESULT, rid, r.get("ok", false), r.get("code", ""), r.get("data", {})))
		"create":
			s["busy"] = true
			var spawn := {"region": region, "x": sim.spawn_point.x, "y": sim.spawn_point.y}   # never from the client
			keeper.request("char_create", {"account_id": acct, "name": args["name"], "appearance": args["appearance"], "spawn": spawn},
				func(r: Dictionary) -> void:
					s["busy"] = false
					if sessions.has(peer):
						_reply(peer, Protocol.CHARS_RESULT, rid, r.get("ok", false), r.get("code", ""), r.get("data", {})))
		"enter":
			_enter_world(peer, s, rid, int(args["character_id"]))


func _session_of_actor(actor: String) -> int:
	for p in sessions:
		if sessions[p]["actor"] == actor and sessions[p]["state"] in ["active", "linkdead"]:
			return p
	return 0


func _enter_world(peer: int, s: Dictionary, rid: int, cid: int) -> void:
	var actor := "c%d" % cid
	var holder := _session_of_actor(actor)
	if holder:
		var hs: Dictionary = sessions[holder]
		if hs["account_id"] != s["account_id"]:
			return _reply(peer, Protocol.CHARS_RESULT, rid, false, "not_found")
		if hs["state"] == "active":
			# duplicate login: the session already in the world keeps authority
			_log("duplicate login refused for character %d (account %d)" % [cid, s["account_id"]])
			return _reply(peer, Protocol.CHARS_RESULT, rid, false, "already_in_world")
		# link-dead: the new connection takes the character over, without reloading
		sessions.erase(holder)
		s["actor"] = actor
		s["character_id"] = cid
		s["state"] = "active"
		s["last_input_time"] = time
		var ps: PlayerState = sim.players[actor]
		ps.linkdead = false
		_reply(peer, Protocol.CHARS_RESULT, rid, true, "", {"character_id": cid, "takeover": true})
		_send_welcome(peer, s)
		_broadcast(Protocol.make(Protocol.PLAYER_STATUS, {"actor": actor, "linkdead": false}))
		_log("character %d reclaimed from link-dead state by peer %d" % [cid, peer])
		return
	s["busy"] = true
	keeper.request("char_claim", {"account_id": s["account_id"], "character_id": cid, "server_id": server_id},
		func(r: Dictionary) -> void:
			s["busy"] = false
			if not sessions.has(peer):
				if r.get("ok", false):   # client vanished while loading: release the lock again
					keeper.request("char_release", {"character_id": cid, "server_id": server_id,
						"x": r["data"]["character"]["x"], "y": r["data"]["character"]["y"], "facing": r["data"]["character"]["facing"]}, func(_x): pass)
				return
			if not r.get("ok", false):
				return _reply(peer, Protocol.CHARS_RESULT, rid, false, r.get("code", "storage_unavailable"))
			if sim.players.has(actor):   # raced with another session of the same account
				return _reply(peer, Protocol.CHARS_RESULT, rid, false, "already_in_world")
			var c: Dictionary = r["data"]["character"]
			var pos := _validated_spawn(Vector2(c["x"], c["y"]))
			var ps := sim.add_player(actor, c["name"], pos, c["appearance"])
			ps.character_id = cid
			ps.facing = int(c["facing"])
			sim.items.load_rows(r["data"]["items"])
			s["actor"] = actor
			s["character_id"] = cid
			s["name"] = c["name"]
			s["state"] = "active"
			s["last_input_time"] = time
			if s["session"] == "":
				s["session"] = "%08x" % (randi() & 0x7fffffff)
			_reply(peer, Protocol.CHARS_RESULT, rid, true, "", {"character_id": cid})
			_send_welcome(peer, s)
			for o in sessions.values():
				if o["peer"] != peer and o["state"] == "active":
					net.send(o["peer"], Protocol.make(Protocol.PLAYER_JOIN, {"player": _player_record(ps)}))
			stats["joins"] += 1
			_log("%s (character %d, account %d) entered at (%.1f, %.1f)" % [c["name"], cid, s["account_id"], pos.x, pos.y]))


## Saved positions are trusted only if they are still legal; otherwise the
## documented safe spawn (nearest free spot to the region's spawn point).
func _validated_spawn(p: Vector2) -> Vector2:
	if is_finite(p.x) and is_finite(p.y) and not sim.is_blocked(p, WorldSim.PLAYER_RADIUS):
		return p
	_log("saved position (%.2f, %.2f) invalid - using safe spawn" % [p.x, p.y])
	return sim._free_drop_spot(sim.spawn_point)


func _send_welcome(peer: int, s: Dictionary) -> void:
	var players := []
	for a in sim.players:
		players.append(_player_record(sim.players[a]))
	var ents := []
	for id in sim.entities:
		ents.append([id, sim.entities[id].open])
	net.send(peer, Protocol.make(Protocol.WELCOME, {"session": s["session"], "actor": s["actor"], "name": s["name"],
		"tick_rate": tick_rate, "state_rate": state_rate, "time": time, "players": players, "entities": ents}))
	_known[peer] = {}
	_items_dirty = true
	_flush_items()


## Save position, release the lock, forget the character's items (they stay in storage).
func _save_and_unload(s: Dictionary, reason: String) -> void:
	var actor: String = s["actor"]
	var ps: PlayerState = sim.players.get(actor)
	if ps == null:
		return
	sim.interaction.close_all_for(actor)
	keeper.request("char_release", {"character_id": ps.character_id, "server_id": server_id,
		"x": ps.pos.x, "y": ps.pos.y, "facing": ps.facing}, func(r: Dictionary) -> void:
			if not r.get("ok", false):
				_log("could not save character %d on leave (%s); position since last checkpoint may be lost" % [ps.character_id, r.get("code", "?")]))
	sim.remove_player(actor, false)
	_items_dirty = true
	_broadcast(Protocol.make(Protocol.PLAYER_LEAVE, {"actor": actor, "reason": reason}))
	stats["leaves"] += 1
	_log("%s (character %d) %s; saved and unloaded" % [ps.display_name, ps.character_id, reason])


func _checkpoint() -> void:
	var positions := []
	for a in sim.players:
		var ps: PlayerState = sim.players[a]
		if ps.character_id:
			positions.append({"id": ps.character_id, "x": ps.pos.x, "y": ps.pos.y, "facing": ps.facing})
	if positions.is_empty():
		return
	keeper.request("checkpoint", {"server_id": server_id, "positions": positions}, func(r: Dictionary) -> void:
		if not r.get("ok", false):
			_log("position checkpoint failed (%s)" % r.get("code", "?")))


func _save_everyone(reason: String) -> void:
	for a in sim.players.keys():
		var ps: PlayerState = sim.players[a]
		if ps.character_id:
			keeper.call_sync("char_release", {"character_id": ps.character_id, "server_id": server_id,
				"x": ps.pos.x, "y": ps.pos.y, "facing": ps.facing}, 2.0)
	_log("saved %d character(s): %s" % [sim.players.size(), reason])



## Development DTLS: a self-signed certificate in <repo>/.dev/tls/ (gitignored),
## generated on first use. Local clients pin the same file. Production supplies
## its own certificate with --tls_cert/--tls_key.
static func dev_tls_options() -> TLSOptions:
	var dir := ProjectSettings.globalize_path("res://").path_join("../.dev/tls").simplify_path()
	DirAccess.make_dir_recursive_absolute(dir)
	var cert_path := dir.path_join("server.crt")
	var key_path := dir.path_join("server.key")
	if not FileAccess.file_exists(cert_path) or not FileAccess.file_exists(key_path):
		var c := Crypto.new()
		var key := c.generate_rsa(2048)
		var cert := c.generate_self_signed_certificate(key, "CN=localhost,O=MMO dev,C=US", "20250101000000", "20350101000000")
		key.save(key_path)
		cert.save(cert_path)
		print("[server] generated development DTLS certificate: %s" % cert_path)
	var k := CryptoKey.new()
	var x := X509Certificate.new()
	if k.load(key_path) != OK or x.load(cert_path) != OK:
		return null
	return TLSOptions.server(k, x)
