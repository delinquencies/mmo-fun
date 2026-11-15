extends SceneTree
## Slice 004 acceptance tests with real processes: PostgreSQL, Keeper and the
## dedicated server run as separate OS processes (restarted and killed by the
## tests); two DTLS clients run in-process. Use tests/persist/run.sh.

func _initialize() -> void:
	var r: Node = load("res://tests/persist_test_runner.gd").new()
	r.name = "PersistTestRunner"
	root.add_child(r)
