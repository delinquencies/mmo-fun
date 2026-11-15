extends Node
## Dedicated server entry point (scenes/server.tscn). Run headless:
##   godot --headless --path game res://scenes/server.tscn -- --port=24680
## Options: --port --bind (default 127.0.0.1; use 0.0.0.0 or a LAN IP for LAN play)
##          --tick --state_rate --linger --max_clients --lag --jitter --loss --stats=<seconds>
## Unauthenticated development server: never expose it to the public internet.

var server: GameServer
var _stats_every := 30.0
var _stats_acc := 0.0


func _ready() -> void:
	var cli := {}
	for a in OS.get_cmdline_user_args():
		var kv := String(a).trim_prefix("--").split("=", true, 1)
		cli[kv[0]] = kv[1] if kv.size() > 1 else "true"
	server = GameServer.new()
	server.name = "Server"
	server.tick_rate = int(cli.get("tick", Protocol.TICK_RATE))
	server.state_rate = int(cli.get("state_rate", Protocol.STATE_RATE))
	server.linger = float(cli.get("linger", Protocol.LINGER))
	server.max_clients = int(cli.get("max_clients", 16))
	_stats_every = float(cli.get("stats", 30))
	add_child(server)
	server.net.configure(float(cli.get("lag", 0)), float(cli.get("jitter", 0)), float(cli.get("loss", 0)))
	var bind := String(cli.get("bind", "127.0.0.1"))
	if bind != "127.0.0.1" and bind != "localhost":
		print("[server] WARNING: listening beyond localhost (%s). Development server: LAN only, no authentication." % bind)
	server.bind_ip = bind
	if server.start(int(cli.get("port", Protocol.DEFAULT_PORT))) != OK:
		get_tree().quit(1)


func _process(dt: float) -> void:
	_stats_acc += dt
	if _stats_every > 0 and _stats_acc >= _stats_every:
		_stats_acc = 0.0
		print("[server] tick %d  sessions %d  players %d  items %d  mem %.1f MB  %s" % [server.tick,
			server.sessions.size(), server.sim.players.size(), server.sim.items.items.size(),
			Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, JSON.stringify(server.stats)])


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		if server:
			server.stop()
