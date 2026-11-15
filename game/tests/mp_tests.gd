extends SceneTree
## Multiplayer acceptance tests: a real ENet dedicated server and two real
## clients in one process (separate SceneMultiplayer branches, localhost UDP).
##   godot --headless --path game --script res://tests/mp_tests.gd
## Exit code 0 = all passed.

func _initialize() -> void:
	var r: Node = load("res://tests/mp_test_runner.gd").new()
	r.name = "MPTestRunner"
	root.add_child(r)
