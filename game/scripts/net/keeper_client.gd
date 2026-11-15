class_name KeeperClient
extends Node
## Connection from the dedicated game server to Keeper (tools/keeper/keeper.py),
## the trusted persistence/authentication process. Newline-delimited JSON over
## loopback TCP, authenticated with KEEPER_SECRET.
##
## * call_sync()  - blocks (bounded timeout). Used for item/world commits so a
##                  gameplay change is applied only after it is durable.
## * request()    - asynchronous; the callback receives the response. Used for
##                  slow operations (Argon2 logins, character loads, checkpoints).

var host := "127.0.0.1"
var port := 24700
var secret := ""
var _tcp: StreamPeerTCP
var _buf := PackedByteArray()
var _next := 0
var _callbacks: Dictionary = {}     # id -> Callable(resp)
var _ready_responses: Dictionary = {}
var authenticated := false
var last_error := ""


func configure_from_env() -> void:
	host = OS.get_environment("KEEPER_HOST") if OS.get_environment("KEEPER_HOST") != "" else "127.0.0.1"
	port = int(OS.get_environment("KEEPER_PORT")) if OS.get_environment("KEEPER_PORT") != "" else 24700
	secret = OS.get_environment("KEEPER_SECRET")


func is_up() -> bool:
	return _tcp != null and authenticated and _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTED


## (Re)connect and authenticate. Blocking, bounded by timeout_s.
func ensure_connected(timeout_s := 1.0) -> bool:
	if is_up():
		return true
	authenticated = false
	_buf.clear()
	_tcp = StreamPeerTCP.new()
	_tcp.set_no_delay(true)
	if _tcp.connect_to_host(host, port) != OK:
		last_error = "connect failed"
		return false
	var t0 := Time.get_ticks_msec()
	while _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING:
		_tcp.poll()
		if Time.get_ticks_msec() - t0 > timeout_s * 1000.0:
			last_error = "connect timeout"
			return false
		OS.delay_msec(2)
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		last_error = "keeper unreachable"
		return false
	_write({"op": "hello", "secret": secret})
	var hello := _read_line_blocking(timeout_s)
	authenticated = hello.get("ok", false)
	last_error = "" if authenticated else "keeper refused the secret"
	# anything still waiting from the old connection is now lost: fail it
	for id in _callbacks.keys():
		var cb: Callable = _callbacks[id]
		_callbacks.erase(id)
		cb.call({"id": id, "ok": false, "code": "storage_unavailable", "data": {}})
	return authenticated


func _write(obj: Dictionary) -> void:
	_tcp.put_data((JSON.stringify(obj) + "\n").to_utf8_buffer())


func _read_line_blocking(timeout_s: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	while true:
		var line := _take_line()
		if line != "":
			var v: Variant = JSON.parse_string(line)
			return v if v is Dictionary else {}
		_tcp.poll()
		if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return {}
		var n := _tcp.get_available_bytes()
		if n > 0:
			var r: Array = _tcp.get_data(n)
			if r[0] == OK:
				_buf.append_array(r[1])
			continue
		if Time.get_ticks_msec() - t0 > timeout_s * 1000.0:
			return {}
		OS.delay_usec(300)
	return {}


func _take_line() -> String:
	var i := _buf.find(10)
	if i < 0:
		return ""
	var line := _buf.slice(0, i).get_string_from_utf8()
	_buf = _buf.slice(i + 1)
	return line


func _pump() -> void:
	if _tcp == null:
		return
	_tcp.poll()
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		if authenticated:
			authenticated = false
			for id in _callbacks.keys():
				var cb: Callable = _callbacks[id]
				_callbacks.erase(id)
				cb.call({"id": id, "ok": false, "code": "storage_unavailable", "data": {}})
		return
	var n := _tcp.get_available_bytes()
	if n > 0:
		var r: Array = _tcp.get_data(n)
		if r[0] == OK:
			_buf.append_array(r[1])
	while true:
		var line := _take_line()
		if line == "":
			break
		var resp: Variant = JSON.parse_string(line)
		if not (resp is Dictionary) or not resp.has("id"):
			continue
		var id := int(resp["id"])
		if _callbacks.has(id):
			var cb: Callable = _callbacks[id]
			_callbacks.erase(id)
			cb.call(resp)
		else:
			_ready_responses[id] = resp


func _process(_dt: float) -> void:
	_pump()


## Asynchronous request. callback(resp: Dictionary) always fires exactly once.
func request(op: String, args: Dictionary, callback: Callable) -> void:
	if not ensure_connected(0.5):
		callback.call({"ok": false, "code": "storage_unavailable", "data": {}})
		return
	_next += 1
	_callbacks[_next] = callback
	_write({"id": _next, "op": op, "args": args})


## Blocking request. Returns {"ok": false, "code": "timeout"} if no answer in time:
## the caller must treat that as "outcome unknown" for mutations.
func call_sync(op: String, args: Dictionary, timeout_s := 2.0) -> Dictionary:
	if not ensure_connected(0.5):
		return {"ok": false, "code": "storage_unavailable", "data": {}}
	_next += 1
	var id := _next
	_write({"id": id, "op": op, "args": args})
	var t0 := Time.get_ticks_msec()
	while true:
		_pump()
		if _ready_responses.has(id):
			var resp: Dictionary = _ready_responses[id]
			_ready_responses.erase(id)
			return resp
		if not is_up():
			return {"ok": false, "code": "timeout", "data": {}}   # sent, connection lost: unknown
		if Time.get_ticks_msec() - t0 > timeout_s * 1000.0:
			return {"ok": false, "code": "timeout", "data": {}}
		OS.delay_usec(200)
	return {}


static func new_op_id() -> String:
	var b := Crypto.new().generate_random_bytes(16)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	var h := b.hex_encode()
	return "%s-%s-%s-%s-%s" % [h.substr(0, 8), h.substr(8, 4), h.substr(12, 4), h.substr(16, 4), h.substr(20, 12)]
