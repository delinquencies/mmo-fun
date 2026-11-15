class_name Protocol
## Network protocol: every message is a Dictionary {"v": VERSION, "t": type, ...}.
## All schemas live here; both sides validate everything they receive.
## Documented in docs/NETWORK_PROTOCOL.md - keep the two in sync.

const VERSION := 3               # v3 (Slice 005): combat, creatures, vitals; v2: accounts
const DEFAULT_PORT := 24680
const MAP := "res://data/maps/homestead.json"

# Initial test settings (not permanent MMO targets) - overridable from the CLI.
const TICK_RATE := 30            # server simulation ticks / s (also client input rate)
const STATE_RATE := 12           # player-state replication / s
const INPUT_REDUNDANCY := 3      # each input packet repeats the last N inputs (packet-loss cover)
const MAX_INPUT_QUEUE := 4       # server-side buffered inputs per player; excess is dropped
const INTEREST_RADIUS := 48.0    # tiles; players/sounds/ground items beyond are not replicated
const HELLO_TIMEOUT := 5.0       # s a new connection has to identify itself
const LINGER := 8.0              # s a link-dead character stays in the world before removal
const CONNECT_TIMEOUT := 6.0
const MAX_NAME := 16
const RID_CACHE := 128           # recent command results kept for duplicate requests

# client -> server, reliable
const HELLO := "hello"           # {name: String}
const CMD := "cmd"               # {rid: int, cmd: {type, args}}
const PING := "ping"             # {time: float}
const BYE := "bye"               # {}
# client -> server, unreliable ordered
const INPUT := "input"           # {inputs: [[seq:int, dx:float, dy:float, run:bool], ...]}
# server -> client, reliable
const WELCOME := "welcome"       # {session, actor, name, tick_rate, state_rate, time, players:[P], entities:[[id, open]], npcs:[N]}
const REJECT := "reject"         # {reason}
const PLAYER_JOIN := "join"      # {player: P}
const PLAYER_LEAVE := "leave"    # {actor, reason}
const PLAYER_STATUS := "status"  # {actor, linkdead: bool}
const ENTITY := "entity"         # {id, open}
const ITEMS := "items"           # {up: [[uid, def, qty, loc]], rm: [uid]}
const EVENT := "event"           # {e: event dictionary (wire form)}
const RESULT := "result"         # {rid, ok, code, message}
const PONG := "pong"             # {time, server_time}
# Slice 004 (persistent realms): accounts and characters
const AUTH := "auth"             # C->S {rid, op: register|login|resume|logout, args}
const AUTH_RESULT := "auth_res"  # S->C {rid, ok, code, message, data}
const CHARS := "chars"           # C->S {rid, op: list|create|enter|leave, args}
const CHARS_RESULT := "chars_res"# S->C {rid, ok, code, message, data}
const REALM := "realm"           # S->C {persistent, realm, max_characters, secure}
const LEFT_WORLD := "left"       # S->C {reason}   (back to character selection)
const MAX_CHARACTERS := 3
# server -> client, unreliable ordered
const STATE := "state"           # {tick, time, ack, players: [[actor, x, y, facing, moving, running, hp_pct, dead]],
                                 #  npcs: [[id, x, y, facing, moving, hp_pct, dead]]}
# P = [actor, name, x, y, facing, linkdead, appearance]
# N = [id, archetype, x, y, facing, hp, hp_max, dead]

const SCHEMAS := {
	HELLO: {"name": TYPE_STRING},
	CMD: {"rid": TYPE_INT, "cmd": TYPE_DICTIONARY},
	PING: {"time": TYPE_FLOAT},
	BYE: {},
	INPUT: {"inputs": TYPE_ARRAY},
	WELCOME: {"session": TYPE_STRING, "actor": TYPE_STRING, "name": TYPE_STRING, "tick_rate": TYPE_INT,
		"state_rate": TYPE_INT, "time": TYPE_FLOAT, "players": TYPE_ARRAY, "entities": TYPE_ARRAY, "npcs": TYPE_ARRAY},
	REJECT: {"reason": TYPE_STRING},
	PLAYER_JOIN: {"player": TYPE_ARRAY},
	PLAYER_LEAVE: {"actor": TYPE_STRING, "reason": TYPE_STRING},
	PLAYER_STATUS: {"actor": TYPE_STRING, "linkdead": TYPE_BOOL},
	ENTITY: {"id": TYPE_STRING, "open": TYPE_BOOL},
	ITEMS: {"up": TYPE_ARRAY, "rm": TYPE_ARRAY},
	EVENT: {"e": TYPE_DICTIONARY},
	RESULT: {"rid": TYPE_INT, "ok": TYPE_BOOL, "code": TYPE_STRING, "message": TYPE_STRING},
	PONG: {"time": TYPE_FLOAT, "server_time": TYPE_FLOAT},
	STATE: {"tick": TYPE_INT, "time": TYPE_FLOAT, "ack": TYPE_INT, "players": TYPE_ARRAY, "npcs": TYPE_ARRAY},
	AUTH: {"rid": TYPE_INT, "op": TYPE_STRING, "args": TYPE_DICTIONARY},
	AUTH_RESULT: {"rid": TYPE_INT, "ok": TYPE_BOOL, "code": TYPE_STRING, "message": TYPE_STRING, "data": TYPE_DICTIONARY},
	CHARS: {"rid": TYPE_INT, "op": TYPE_STRING, "args": TYPE_DICTIONARY},
	CHARS_RESULT: {"rid": TYPE_INT, "ok": TYPE_BOOL, "code": TYPE_STRING, "message": TYPE_STRING, "data": TYPE_DICTIONARY},
	REALM: {"persistent": TYPE_BOOL, "realm": TYPE_STRING, "max_characters": TYPE_INT, "secure": TYPE_BOOL},
	LEFT_WORLD: {"reason": TYPE_STRING},
}

const AUTH_OPS := {"register": {"username": TYPE_STRING, "password": TYPE_STRING},
	"login": {"username": TYPE_STRING, "password": TYPE_STRING},
	"resume": {"token": TYPE_STRING}, "logout": {}}
const CHAR_OPS := {"list": {}, "create": {"name": TYPE_STRING, "appearance": TYPE_DICTIONARY},
	"enter": {"character_id": TYPE_INT}, "leave": {}}
const APPEARANCE_CLOTH: PackedStringArray = ["olive", "crimson", "azure", "umber", "plum"]


## Validate {op, args} of AUTH / CHARS against the table: exact keys, types, sizes.
static func validate_op(table: Dictionary, op: String, args: Dictionary) -> String:
	if not table.has(op):
		return "unknown_op"
	var want: Dictionary = table[op]
	if args.size() != want.size():
		return "bad_args"
	for k in want:
		if not args.has(k) or typeof(args[k]) != want[k]:
			return "bad_" + k
		if args[k] is String and (args[k] as String).length() > 128:
			return "too_long_" + k
	if args.has("appearance"):
		var a: Dictionary = args["appearance"]
		if a.size() != 1 or not (a.get("cloth") is String) or not APPEARANCE_CLOTH.has(a["cloth"]):
			return "bad_appearance"
	return ""

const CLIENT_TO_SERVER: PackedStringArray = [HELLO, CMD, PING, BYE, INPUT, AUTH, CHARS]


static func make(t: String, fields := {}) -> Dictionary:
	var d := fields.duplicate()
	d["v"] = VERSION
	d["t"] = t
	return d


## "" if valid, otherwise a reason. Checks envelope, version, type and field types.
static func validate(msg: Variant, allowed: PackedStringArray = PackedStringArray()) -> String:
	if not (msg is Dictionary):
		return "not_a_dictionary"
	if msg.get("v") != VERSION:
		return "bad_version"
	var t: Variant = msg.get("t")
	if not (t is String) or not SCHEMAS.has(t):
		return "unknown_type"
	if not allowed.is_empty() and not allowed.has(t):
		return "not_allowed"
	var schema: Dictionary = SCHEMAS[t]
	for k in schema:
		if not msg.has(k):
			return "missing_" + k
		var want: int = schema[k]
		var got := typeof(msg[k])
		if got != want and not (want == TYPE_FLOAT and got == TYPE_INT):
			return "type_" + k
	if msg.size() > schema.size() + 2:
		return "unexpected_fields"
	return ""


static func _num(v: Variant) -> bool:
	return (v is float or v is int) and is_finite(float(v))


static func _loc_ok(l: Variant) -> bool:
	if not (l is Dictionary):
		return false
	match l.get("kind"):
		"container":
			return l.get("container") is String and l.get("slot") is int and l.size() == 3
		"world":
			var p: Variant = l.get("pos")
			return p is Array and p.size() == 2 and _num(p[0]) and _num(p[1]) and l.size() == 2
		"equipment":
			return l.get("owner") is String and l.get("slot") is String and l.size() == 3
	return false


## Validate the payload of a CMD message (an InteractionCommand in wire form).
static func validate_command(c: Dictionary) -> String:
	var type: Variant = c.get("type")
	if not (type is String) or not InteractionSystem.COMMAND_TYPES.has(type):
		return "unknown_command"
	var a: Variant = c.get("args")
	if not (a is Dictionary) or a.size() > 6:
		return "bad_args"
	for k in a:
		var v: Variant = a[k]
		match k:
			"uid", "qty":
				if not (v is int) or v < 0:
					return "bad_" + k
			"from", "to":
				if not _loc_ok(v):
					return "bad_" + k
			"entity", "container", "slot", "target":
				if not (v is String) or (v as String).length() > 64:
					return "bad_" + k
			"open":
				if not (v is bool):
					return "bad_open"
			"pos":
				if not (v is Array and v.size() == 2 and _num(v[0]) and _num(v[1])):
					return "bad_pos"
			_:
				return "unknown_arg_" + str(k)
	return ""


## Validate one movement input [seq, dx, dy, run]. Direction magnitude must be <= 1.
static func validate_input(i: Variant) -> String:
	if not (i is Array) or i.size() != 4:
		return "shape"
	if not (i[0] is int) or not _num(i[1]) or not _num(i[2]) or not (i[3] is bool):
		return "types"
	if Vector2(float(i[1]), float(i[2])).length() > 1.01:
		return "magnitude"
	return ""


static func sanitize_name(n: String) -> String:
	var out := ""
	for ch in n.strip_edges():
		var c := ch.unicode_at(0)
		if (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or ch == " " or ch == "-" or ch == "_":
			out += ch
	out = out.strip_edges().substr(0, MAX_NAME)
	return out if out.length() >= 2 else ""


# --- wire conversion for events (Vector2 -> [x, y], locations -> wire form) ---

static func event_to_wire(e: Dictionary) -> Dictionary:
	var o := {}
	for k in e:
		var v: Variant = e[k]
		if v is Vector2:
			o[k] = [v.x, v.y] if is_finite(v.x) else []
		elif v is Dictionary and v.has("kind"):
			o[k] = ItemLocation.to_wire(v)
		else:
			o[k] = v
	return o


static func event_from_wire(o: Dictionary) -> Dictionary:
	var e := {}
	for k in o:
		var v: Variant = o[k]
		if k == "pos" and v is Array:
			e[k] = Vector2(v[0], v[1]) if v.size() == 2 else Vector2.INF
		elif v is Dictionary and v.has("kind"):
			e[k] = ItemLocation.from_wire(v)
		else:
			e[k] = v
	return e
