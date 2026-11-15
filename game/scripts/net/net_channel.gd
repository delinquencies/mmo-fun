class_name NetChannel
extends Node
## Transport for protocol messages over Godot's high-level multiplayer (ENet).
## Must be a direct child named "Net" of a node that owns a SceneMultiplayer
## branch, so RPC paths match on server and client.
##
## Optional artificial network conditions for testing: lag/jitter delay every
## outgoing message; loss drops unreliable messages and delays reliable ones
## (ENet would retransmit them). Reliable messages are never reordered.

signal received(peer: int, msg: Variant, reliable: bool)

var lag_ms := 0.0
var jitter_ms := 0.0
var loss := 0.0
var stats := {"sent": 0, "sent_bytes": 0, "received": 0, "sim_dropped": 0}
var _outbox: Array = []              # [due_ms, seq, peer, msg, reliable]
var _last_reliable_due: Dictionary = {}
var _rng := RandomNumberGenerator.new()
var _seq := 0


func _init() -> void:
	name = "Net"


func configure(p_lag: float, p_jitter: float, p_loss: float, seed_value := 0) -> void:
	lag_ms = p_lag
	jitter_ms = p_jitter
	loss = p_loss
	if seed_value:
		_rng.seed = seed_value


func send(peer: int, msg: Dictionary, reliable := true) -> void:
	if lag_ms <= 0.0 and jitter_ms <= 0.0 and loss <= 0.0:
		_deliver(peer, msg, reliable)
		return
	var now := Time.get_ticks_msec()
	var due := now + lag_ms + _rng.randf_range(0.0, jitter_ms)
	if not reliable and _rng.randf() < loss:
		stats["sim_dropped"] += 1
		return
	if reliable:
		if _rng.randf() < loss:
			due += lag_ms * 2.0 + 30.0   # simulated retransmission
		due = maxf(due, _last_reliable_due.get(peer, 0.0))
		_last_reliable_due[peer] = due
	_seq += 1
	_outbox.append([due, _seq, peer, msg, reliable])


func _process(_dt: float) -> void:
	if _outbox.is_empty():
		return
	var now := Time.get_ticks_msec()
	_outbox.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	while not _outbox.is_empty() and _outbox[0][0] <= now:
		var o: Array = _outbox.pop_front()
		_deliver(o[2], o[3], o[4])


func flush_all() -> void:
	for o in _outbox:
		_deliver(o[2], o[3], o[4])
	_outbox.clear()


func _deliver(peer: int, msg: Dictionary, reliable: bool) -> void:
	if not is_inside_tree() or multiplayer == null or multiplayer.multiplayer_peer == null or multiplayer.multiplayer_peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	if peer != 1 and not multiplayer.is_server():
		return
	if multiplayer.is_server() and peer != 0 and not multiplayer.get_peers().has(peer):
		return
	stats["sent"] += 1
	stats["sent_bytes"] += var_to_bytes(msg).size()
	if reliable:
		_r.rpc_id(peer, msg)
	else:
		_u.rpc_id(peer, msg)


@rpc("any_peer", "call_remote", "reliable")
func _r(msg: Variant) -> void:
	stats["received"] += 1
	received.emit(multiplayer.get_remote_sender_id(), msg, true)


@rpc("any_peer", "call_remote", "unreliable_ordered")
func _u(msg: Variant) -> void:
	stats["received"] += 1
	received.emit(multiplayer.get_remote_sender_id(), msg, false)
