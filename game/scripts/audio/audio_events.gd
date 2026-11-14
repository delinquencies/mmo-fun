class_name AudioEvents
extends Node
## Plays named sound events (game/data/audio_events.json -> res://assets/audio/).
## Missing files are skipped silently so sounds stay optional placeholders.

const POOL := 8

var _streams: Dictionary = {}
var _cfg: Dictionary = {}
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var listener_pos := Vector2.ZERO   # world units; distant events are quieter
var last_played := ""              # for automated checks


func _ready() -> void:
	_cfg = JSON.parse_string(FileAccess.get_file_as_string("res://data/audio_events.json"))
	for k in _cfg:
		if k.begins_with("_"):
			continue
		var path := "res://assets/audio/%s" % _cfg[k]["file"]
		if ResourceLoader.exists(path):
			_streams[k] = load(path)
	for i in POOL:
		var p := AudioStreamPlayer.new()
		add_child(p)
		_players.append(p)


func play(event: String, world_pos: Variant = null) -> void:
	last_played = event
	if not _streams.has(event):
		return
	var p := _players[_next]
	_next = (_next + 1) % POOL
	p.stream = _streams[event]
	var vol := float(_cfg[event].get("volume_db", 0.0))
	if world_pos is Vector2 and world_pos != Vector2.INF:
		vol -= clampf(listener_pos.distance_to(world_pos) - 2.0, 0.0, 12.0) * 1.5
	p.volume_db = vol
	p.pitch_scale = randf_range(0.95, 1.05)
	p.play()
