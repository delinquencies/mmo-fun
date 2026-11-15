extends Node
## Dedicated server entry point (scenes/server.tscn). Run headless:
##   godot --headless --path game res://scenes/server.tscn -- --port=24680
## Options: --port --bind (default 127.0.0.1; use 0.0.0.0 or a LAN IP for LAN play)
##          --persistent (accounts + PostgreSQL via Keeper; needs KEEPER_SECRET in the environment)
##          --server_id=homestead-1   --tls_cert=<pem> --tls_key=<pem>   --dev_tls (generate .dev/tls/*)
##          --tick --state_rate --linger --max_clients --lag --jitter --loss --stats=<seconds>
## Unauthenticated development server: never expose it to the public internet.

var server: GameServer
var _stats_every := 30.0
var _stats_acc := 0.0
var _stop_file := ""
var _stop_acc := 0.0


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
	server.persistent = cli.has("persistent")
	server.server_id = String(cli.get("server_id", "homestead-1"))
	server.tls = _tls_options(cli)
	# Godot exits on SIGINT/SIGTERM without notifying scripts, so graceful
	# shutdown is requested through a file (tools/net/run_server.sh does this).
	_stop_file = String(cli.get("stop_file", ""))
	if _stop_file != "" and FileAccess.file_exists(_stop_file):
		DirAccess.remove_absolute(_stop_file)
	add_child(server)
	server.net.configure(float(cli.get("lag", 0)), float(cli.get("jitter", 0)), float(cli.get("loss", 0)))
	var bind := String(cli.get("bind", "127.0.0.1"))
	if bind != "127.0.0.1" and bind != "localhost":
		print("[server] WARNING: listening beyond localhost (%s). Development server: LAN only, no authentication." % bind)
	server.bind_ip = bind
	if server.start(int(cli.get("port", Protocol.DEFAULT_PORT))) != OK:
		get_tree().quit(1)


func _process(dt: float) -> void:
	_stop_acc += dt
	if _stop_file != "" and _stop_acc > 0.5:
		_stop_acc = 0.0
		if FileAccess.file_exists(_stop_file):
			DirAccess.remove_absolute(_stop_file)
			print("[server] graceful shutdown requested")
			server.stop()
			get_tree().quit()
			return
	_stats_acc += dt
	if _stats_every > 0 and _stats_acc >= _stats_every:
		_stats_acc = 0.0
		print("[server] tick %d  sessions %d  players %d  items %d  mem %.1f MB  %s" % [server.tick,
			server.sessions.size(), server.sim.players.size(), server.sim.items.items.size(),
			Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, JSON.stringify(server.stats)])




## DTLS: explicit cert/key files, or the development certificate (--dev_tls).
func _tls_options(cli: Dictionary) -> TLSOptions:
	var cert_path := String(cli.get("tls_cert", ""))
	var key_path := String(cli.get("tls_key", ""))
	if cert_path == "" and cli.has("dev_tls"):
		return GameServer.dev_tls_options()
	if cert_path == "":
		return null
	var k := CryptoKey.new()
	var x := X509Certificate.new()
	if k.load(key_path) != OK or x.load(cert_path) != OK:
		push_error("cannot load TLS key/certificate")
		return null
	return TLSOptions.server(k, x)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if server:
			server.stop()
		get_tree().quit()