class_name NetClient
extends Node
## Client side of the multiplayer protocol.
##
## Holds a *replica* WorldSim that is only ever changed by server messages
## (plus local movement prediction, which the server corrects). Exposes the
## same surface GameUI uses offline - submit(cmd) and the event_emitted signal -
## so the UI does not know whether it is online.
##
## Must be the root of its own SceneMultiplayer branch (set up in _enter_tree),
## with its NetChannel child named "Net" - mirroring GameServer.

signal status_changed(state: String, detail: String)   # disconnected | connecting | connected | failed
signal world_ready
signal event_emitted(event: Dictionary)
signal command_resolved(result: Dictionary)
signal players_changed
signal realm_ready(info: Dictionary)          # persistent realm: log in next
signal auth_result(result: Dictionary)
signal chars_result(result: Dictionary)
signal left_world(reason: String)

var sim: WorldSim
var net := NetChannel.new()
var enet: ENetMultiplayerPeer
var state := "disconnected"
var detail := ""
var address := "127.0.0.1"
var port := Protocol.DEFAULT_PORT
var player_name := "Adventurer"
var session_id := ""
var actor := ""
var tick_rate := Protocol.TICK_RATE
var predict := true
var interp_delay := 0.12
var rtt := 0.0

var input_dir := Vector2.ZERO
var input_run := false
var _seq := 0
var _pending_inputs: Array = []    # [seq, dir, run] not yet acknowledged
var _tick_acc := 0.0
var _rid := 0
var _pending_cmds: Dictionary = {} # rid -> InteractionCommand
var _connect_deadline := 0.0
var _ping_acc := 0.0
var server_time := 0.0             # estimate of the server clock
var _buffers: Dictionary = {}      # remote actor -> Array[[t, pos, facing, moving, running]]
var _smooth := Vector2.ZERO        # local render correction offset
var corrections := 0
var max_correction := 0.0
var last_result: Dictionary = {}

# Slice 004
var realm: Dictionary = {}
var secure := false               # DTLS in use
var tls_cert_path := ""           # pinned server certificate; default: <repo>/.dev/tls/server.crt
var tls_hostname := "localhost"
var _token := ""                  # account session token: memory only, never written to disk
var _pending_auth_op: Dictionary = {}   # rid -> op
var last_auth: Dictionary = {}
var last_chars: Dictionary = {}


func _enter_tree() -> void:
	get_tree().set_multiplayer(SceneMultiplayer.new(), get_path())
	add_child(net)


func _set_state(s: String, d := "") -> void:
	state = s
	detail = d
	status_changed.emit(s, d)


func connect_to(p_address: String, p_port: int, p_name: String) -> Error:
	if state == "connecting" or state == "connected":
		disconnect_from_server()
	address = p_address
	port = p_port
	player_name = p_name
	enet = ENetMultiplayerPeer.new()
	var err := enet.create_client(address, port)
	if err != OK:
		_set_state("failed", "Could not start a connection (%s)." % error_string(err))
		return err
	secure = false
	var cert := _load_cert()
	if cert:
		err = enet.host.dtls_client_setup(tls_hostname, TLSOptions.client(cert))
		if err != OK:
			_set_state("failed", "Could not set up encryption (%s)." % error_string(err))
			return err
		secure = true
	var smp := multiplayer as SceneMultiplayer
	smp.allow_object_decoding = false
	multiplayer.multiplayer_peer = enet
	if not multiplayer.connected_to_server.is_connected(_on_connected):
		multiplayer.connected_to_server.connect(_on_connected)
		multiplayer.connection_failed.connect(_on_connection_failed)
		multiplayer.server_disconnected.connect(_on_server_disconnected)
		net.received.connect(_on_message)
	_connect_deadline = Time.get_ticks_msec() / 1000.0 + Protocol.CONNECT_TIMEOUT
	_set_state("connecting", "Connecting to %s:%d ..." % [address, port])
	return OK


func _load_cert() -> X509Certificate:
	var path := tls_cert_path
	if path == "":
		path = ProjectSettings.globalize_path("res://").path_join("../.dev/tls/server.crt").simplify_path()
	if not FileAccess.file_exists(path):
		return null
	var c := X509Certificate.new()
	return c if c.load(path) == OK else null


static func is_loopback(host: String) -> bool:
	return host == "127.0.0.1" or host == "localhost" or host == "::1"


## Account requests (register / login / resume / logout). Returns the rid.
func send_auth(op: String, args: Dictionary) -> int:
	if (op == "login" or op == "register") and not secure and not is_loopback(address):
		var r := {"rid": 0, "ok": false, "code": "insecure", "message": "Refusing to send a password over an unencrypted connection. Install the server's certificate.", "data": {}}
		auth_result.emit(r)
		return 0
	_rid += 1
	_pending_auth_op[_rid] = op
	net.send(1, Protocol.make(Protocol.AUTH, {"rid": _rid, "op": op, "args": args}))
	if op == "logout":
		_token = ""
	return _rid


## Character requests (list / create / enter / leave). Returns the rid.
func send_chars(op: String, args: Dictionary = {}) -> int:
	_rid += 1
	net.send(1, Protocol.make(Protocol.CHARS, {"rid": _rid, "op": op, "args": args}))
	return _rid


func has_token() -> bool:
	return _token != ""


func forget_token() -> void:
	_token = ""


func disconnect_from_server(reason := "You left the world.") -> void:
	if enet and state in ["connected", "login", "account"]:
		net.send(1, Protocol.make(Protocol.BYE))
		net.flush_all()
		enet.get_peer(1).peer_disconnect_later()
		await get_tree().create_timer(0.1).timeout
	_teardown("disconnected", reason)


## Synchronous goodbye for application exit (no awaits possible).
func goodbye_now() -> void:
	if enet and state == "connected":
		net.send(1, Protocol.make(Protocol.BYE))
		net.flush_all()
		var p := enet.get_peer(1)
		if p:
			p.peer_disconnect_later()   # ENet sends queued packets (the BYE) first
		for i in 25:
			enet.poll()
			if enet.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
				break
			OS.delay_msec(4)
		enet.close()
		state = "disconnected"


## Drop the connection without saying goodbye (tests: unexpected disconnect).
func drop_connection() -> void:
	_teardown("disconnected", "Connection dropped.")


func _teardown(s: String, why: String) -> void:
	if enet:
		enet.close()
	multiplayer.multiplayer_peer = null
	enet = null
	_pending_inputs.clear()
	_pending_cmds.clear()
	_buffers.clear()
	sim = null if s != "connected" else sim
	_set_state(s, why)


func _on_connected() -> void:
	var p := enet.get_peer(1)
	if p:
		p.set_timeout(0, 2000, 6000)
	net.send(1, Protocol.make(Protocol.HELLO, {"name": player_name}))
	_connect_deadline = Time.get_ticks_msec() / 1000.0 + 1e9


func _on_connection_failed() -> void:
	_teardown("failed", "Could not reach %s:%d." % [address, port])


func _on_server_disconnected() -> void:
	_teardown("disconnected", "Lost connection to the server." if detail == "" else detail)


# --- authority surface used by GameUI -------------------------------------------

## Send an InteractionCommand. The returned result is provisional (ok = sent);
## the real outcome arrives as RESULT plus events.
func submit(cmd: InteractionCommand) -> CommandResult:
	if state != "connected":
		var f := CommandResult.failure(cmd, "offline", "Not connected.")
		event_emitted.emit({"type": "failed", "actor": actor, "code": "offline", "message": f.message, "pos": sim.actor_pos(actor) if sim else Vector2.INF})
		return f
	_rid += 1
	_pending_cmds[_rid] = cmd
	var wire := cmd.to_wire()
	net.send(1, Protocol.make(Protocol.CMD, {"rid": _rid, "cmd": {"type": wire["type"], "args": wire["args"]}}))
	return CommandResult.success(cmd, [])


## Raw access for tests: send an arbitrary CMD with an explicit rid.
func send_raw_command(rid: int, type: String, args: Dictionary) -> void:
	net.send(1, Protocol.make(Protocol.CMD, {"rid": rid, "cmd": {"type": type, "args": args}}))


func next_rid() -> int:
	_rid += 1
	return _rid


func set_input(dir: Vector2, run: bool) -> void:
	input_dir = dir.normalized() if dir.length_squared() > 0.0001 else Vector2.ZERO
	input_run = run


# --- incoming -------------------------------------------------------------------

func _on_message(peer: int, msg: Variant, _reliable: bool) -> void:
	if peer != 1:
		return
	var err := Protocol.validate(msg)
	if err != "":
		push_warning("dropped invalid server message: %s" % err)
		return
	match msg["t"]:
		Protocol.WELCOME:
			_on_welcome(msg)
		Protocol.REALM:
			realm = msg
			_set_state("login", "Connected to %s (%s)." % [msg["realm"], "encrypted" if secure else "unencrypted, local only"])
			realm_ready.emit(msg)
			if _token != "":
				send_auth("resume", {"token": _token})
		Protocol.AUTH_RESULT:
			var op: String = _pending_auth_op.get(msg["rid"], "")
			_pending_auth_op.erase(msg["rid"])
			if msg["ok"]:
				if msg["data"].has("token"):
					_token = msg["data"]["token"]
				if op in ["login", "resume"]:
					player_name = msg["data"].get("username", player_name)
					_set_state("account", "Logged in as %s." % msg["data"].get("username", "?"))
				elif op == "logout":
					_set_state("login", "Logged out.")
			elif op == "resume":
				_token = ""
			last_auth = msg
			auth_result.emit(msg)
		Protocol.CHARS_RESULT:
			last_chars = msg
			chars_result.emit(msg)
		Protocol.LEFT_WORLD:
			sim = null
			_pending_inputs.clear()
			_buffers.clear()
			_set_state("account", msg["reason"])
			left_world.emit(msg["reason"])
		Protocol.REJECT:
			_teardown("failed", "Server refused: %s" % msg["reason"])
		Protocol.PLAYER_JOIN:
			_add_player(msg["player"])
			players_changed.emit()
		Protocol.PLAYER_LEAVE:
			if sim and sim.players.has(msg["actor"]) and msg["actor"] != actor:
				sim.players.erase(msg["actor"])
				_buffers.erase(msg["actor"])
				event_emitted.emit({"type": "system", "message": "%s %s." % [_name_of(msg["actor"]), msg["reason"]]})
				players_changed.emit()
		Protocol.PLAYER_STATUS:
			if sim and sim.players.has(msg["actor"]):
				sim.players[msg["actor"]].linkdead = msg["linkdead"]
				if msg["linkdead"]:
					event_emitted.emit({"type": "system", "message": "%s has lost their connection." % _name_of(msg["actor"])})
		Protocol.ENTITY:
			if sim and sim.entities.has(msg["id"]):
				sim.entities[msg["id"]].open = msg["open"]
		Protocol.ITEMS:
			if sim:
				sim.items.replica_apply(msg["up"], msg["rm"])
		Protocol.EVENT:
			_on_event(Protocol.event_from_wire(msg["e"]))
		Protocol.RESULT:
			_pending_cmds.erase(msg["rid"])
			last_result = msg
			command_resolved.emit(msg)
		Protocol.PONG:
			rtt = Time.get_ticks_msec() / 1000.0 - float(msg["time"])
		Protocol.STATE:
			_on_state(msg)


func _name_of(a: String) -> String:
	return sim.players[a].display_name if sim and sim.players.has(a) else "Someone"


func _on_welcome(msg: Dictionary) -> void:
	session_id = msg["session"]
	actor = msg["actor"]
	player_name = msg["name"]
	tick_rate = msg["tick_rate"]
	server_time = msg["time"]
	sim = WorldSim.new()
	sim.load_map(Protocol.MAP, false, false)
	sim.local_actor = actor
	for p in msg["players"]:
		_add_player(p)
	for e in msg["entities"]:
		if sim.entities.has(e[0]):
			sim.entities[e[0]].open = e[1]
	for n in msg["npcs"]:
		var npc: NpcState = sim.npcs.get(n[0])
		if npc:
			npc.pos = Vector2(n[2], n[3])
			npc.render_pos = npc.pos
			npc.facing = n[4]
			npc.combat.hp = n[5]
			npc.combat.hp_max = n[6]
			npc.combat.dead = n[7]
	_seq = 0
	_pending_inputs.clear()
	_set_state("connected", "Connected to %s:%d as %s." % [address, port, player_name])
	world_ready.emit()


func _add_player(p: Array) -> void:
	if sim == null or sim.players.has(p[0]):
		return
	var ps := sim.add_player(p[0], p[1], Vector2(p[2], p[3]), p[6] if p.size() > 6 and p[6] is Dictionary else {})
	ps.facing = p[4]
	ps.linkdead = p[5]
	ps.sync_render()


func _on_event(e: Dictionary) -> void:
	match e["type"]:
		"combat":
			_apply_combat(e)
		"vitals":
			var me: PlayerState = sim.players.get(actor)
			if me and me.combat and e.get("actor") == actor:
				var v: Array = e["v"]
				me.combat.hp = v[0]
				me.combat.hp_max = v[1]
				me.combat.st = v[2]
				me.combat.st_max = v[3]
				me.combat.mn = v[4]
				me.combat.mn_max = v[5]
				me.combat.dead = e["dead"]
		"skill":
			var me2: PlayerState = sim.players.get(actor)
			if me2:
				me2.skills[e["skill"]] = float(e["value"])
		"entity_spawned":
			_spawn_entity(e)
		"entity_removed":
			var ent: Interactable = sim.entities.get(e["id"])
			if ent:
				for uid in sim.items.items.keys():
					if sim.items.location(uid).get("container", "") == ent.container_id:
						sim.items._destroy(uid)
				sim.items.containers.erase(ent.container_id)
				sim.interaction.open_containers.get(actor, []).erase(ent.container_id)
				sim.entities.erase(e["id"])
		"container_opened":
			if not sim.interaction.is_open(actor, e["container"]):
				sim.interaction.open_containers.get_or_add(actor, []).append(e["container"])
		"container_closed":
			sim.interaction.open_containers.get(actor, []).erase(e["container"])
	event_emitted.emit(e)


## Replica-side bookkeeping for authoritative combat events (presentation reads it).
func _apply_combat(e: Dictionary) -> void:
	var tid: String = e.get("target", "")
	var tc: Combatant = null
	if tid.begins_with("n:"):
		tc = sim.npcs[tid].combat if sim.npcs.has(tid) else null
	elif sim.players.has(tid):
		tc = sim.players[tid].combat
	match e["kind"]:
		"damage":
			if tc:
				tc.hp = float(e["hp"])
				tc.hp_max = float(e["hp_max"])
		"death":
			if tc:
				tc.dead = true
				tc.hp = 0
		"respawn", "npc_respawn":
			if tc:
				tc.dead = false
			if tid.begins_with("n:") and sim.npcs.has(tid):
				sim.npcs[tid].pos = e["pos"]
				sim.npcs[tid].render_pos = e["pos"]
				_buffers.erase(tid)
				tc.hp = tc.hp_max
		"swing":
			var src: String = e["source"]
			if src.begins_with("n:") and sim.npcs.has(src):
				sim.npcs[src].swing_started = Time.get_ticks_msec() / 1000.0


func _spawn_entity(e: Dictionary) -> void:
	if sim.entities.has(e["id"]):
		return
	var ent := Interactable.new()
	ent.id = e["id"]
	ent.def_id = "corpse"
	ent.def = e["def"]
	ent.kind = e["kind"]
	ent.policy = "temporary"
	ent.pos = e["pos"]
	ent.container_id = e["container"]
	sim.items.add_container(ContainerComponent.new(e["container"], e["title"], e["id"], int(e["capacity"]), int(e["columns"])))
	sim.entities[ent.id] = ent


func _on_state(msg: Dictionary) -> void:
	if sim == null:
		return
	var t: float = msg["time"]
	if absf(server_time - t) > 0.5:
		server_time = t
	else:
		server_time = lerpf(server_time, t, 0.1)
	for rec in msg["npcs"]:
		if not (rec is Array) or rec.size() != 7 or not sim.npcs.has(rec[0]):
			continue
		var npc: NpcState = sim.npcs[rec[0]]
		npc.pos = Vector2(rec[1], rec[2])
		npc.combat.hp = npc.combat.hp_max * float(rec[5]) / 100.0
		npc.combat.dead = rec[6]
		var nb: Array = _buffers.get_or_add(rec[0], [])
		nb.append([t, npc.pos, int(rec[3]), bool(rec[4]), false])
		while nb.size() > 30:
			nb.pop_front()
	for rec in msg["players"]:
		if not (rec is Array) or rec.size() < 6:
			continue
		var pc: Combatant = sim.players[rec[0]].combat if sim.players.has(rec[0]) else null
		if pc and rec.size() >= 8 and rec[0] != actor:
			pc.hp = pc.hp_max * float(rec[6]) / 100.0
			pc.dead = rec[7]
		var a: String = rec[0]
		var ps: PlayerState = sim.players.get(a)
		if ps == null:
			continue
		var spos := Vector2(rec[1], rec[2])
		if a == actor:
			_reconcile(ps, spos, int(msg["ack"]), int(rec[3]), bool(rec[4]))
		else:
			ps.pos = spos   # latest authoritative position (range checks, picking)
			var buf: Array = _buffers.get_or_add(a, [])
			buf.append([t, spos, int(rec[3]), bool(rec[4]), bool(rec[5])])
			while buf.size() > 30:
				buf.pop_front()


## Server-authoritative position + re-apply inputs the server has not seen yet.
func _reconcile(ps: PlayerState, spos: Vector2, ack: int, facing: int, moving: bool) -> void:
	while not _pending_inputs.is_empty() and _pending_inputs[0][0] <= ack:
		_pending_inputs.pop_front()
	var predicted := ps.pos
	if not predict:
		ps.pos = spos
		ps.facing = facing
		ps.moving = moving
		return
	ps.pos = spos
	var dt := 1.0 / tick_rate
	for inp in _pending_inputs:
		sim.step_actor(actor, dt, inp[1], inp[2])
	var err := predicted - ps.pos
	if err.length() > 0.001:
		corrections += 1
		max_correction = maxf(max_correction, err.length())
	if err.length() > 1.5:
		_smooth = Vector2.ZERO      # far off: snap
	else:
		_smooth += err              # small: blend away visually


# --- per-frame -------------------------------------------------------------------

func _process(delta: float) -> void:
	if state == "connecting" and Time.get_ticks_msec() / 1000.0 > _connect_deadline:
		_teardown("failed", "Connection to %s:%d timed out." % [address, port])
		return
	if state != "connected" or sim == null:
		return
	server_time += delta
	var dt := 1.0 / tick_rate
	_tick_acc += delta
	var n := 0
	while _tick_acc >= dt and n < 4:
		_tick_acc -= dt
		n += 1
		_client_tick(dt)
	if n == 4:
		_tick_acc = 0.0
	_ping_acc += delta
	if _ping_acc > 1.0:
		_ping_acc = 0.0
		net.send(1, Protocol.make(Protocol.PING, {"time": Time.get_ticks_msec() / 1000.0}))
	_update_render(delta)
	sim.step_sheep(delta)   # ambient, client-side only (no gameplay state)


func _client_tick(dt: float) -> void:
	var me: PlayerState = sim.players.get(actor)
	if me == null:
		return
	_seq += 1
	_pending_inputs.append([_seq, input_dir, input_run])
	if _pending_inputs.size() > 120:
		_pending_inputs.pop_front()
	if predict:
		sim.step_actor(actor, dt, input_dir, input_run)
	var packet := []
	for k in range(maxi(0, _pending_inputs.size() - Protocol.INPUT_REDUNDANCY), _pending_inputs.size()):
		var i: Array = _pending_inputs[k]
		packet.append([i[0], i[1].x, i[1].y, i[2]])
	net.send(1, Protocol.make(Protocol.INPUT, {"inputs": packet}), false)


func _update_render(delta: float) -> void:
	var rt := server_time - interp_delay
	for id in sim.npcs:
		var n: NpcState = sim.npcs[id]
		var nb: Array = _buffers.get(id, [])
		if nb.is_empty():
			n.render_pos = n.pos
			n.render_facing = n.facing
			continue
		var j := nb.size() - 1
		while j > 0 and nb[j][0] > rt:
			j -= 1
		var a0: Array = nb[j]
		var a1: Array = nb[mini(j + 1, nb.size() - 1)]
		var fr := clampf((rt - a0[0]) / (a1[0] - a0[0]), 0.0, 1.0) if a1[0] > a0[0] else 0.0
		n.render_pos = (a0[1] as Vector2).lerp(a1[1], fr)
		n.render_facing = a1[2] if fr > 0.5 else a0[2]
		n.render_moving = a0[3] or a1[3]
		if n.render_moving:
			n.anim_time += delta
	for a in sim.players:
		var ps: PlayerState = sim.players[a]
		if a == actor:
			_smooth *= exp(-delta * 12.0)
			ps.render_pos = ps.pos + _smooth
			ps.render_facing = ps.facing
			ps.render_moving = ps.moving
			ps.render_running = ps.running
			continue
		var buf: Array = _buffers.get(a, [])
		if buf.is_empty():
			ps.sync_render()
			continue
		var i := buf.size() - 1
		while i > 0 and buf[i][0] > rt:
			i -= 1
		var s0: Array = buf[i]
		var s1: Array = buf[mini(i + 1, buf.size() - 1)]
		var f := 0.0
		if s1[0] > s0[0]:
			f = clampf((rt - s0[0]) / (s1[0] - s0[0]), 0.0, 1.0)
		ps.render_pos = (s0[1] as Vector2).lerp(s1[1], f)
		ps.render_facing = s1[2] if f > 0.5 else s0[2]
		ps.render_moving = s0[3] or s1[3]
		ps.render_running = s1[4]
		if ps.render_moving:
			ps.anim_time += delta * (1.75 if ps.render_running else 1.0)


func local_state() -> PlayerState:
	return sim.players.get(actor) if sim else null
