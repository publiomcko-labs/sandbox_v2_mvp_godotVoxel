extends SceneTree
# Benchmark opt-in; normal game scene is not modified.
const Runner = preload("res://tests/comparison_v1_runtime.gd")
func _initialize() -> void:
    call_deferred("_boot")
func _boot() -> void:
    if DisplayServer.get_name() != "headless":
        DisplayServer.window_set_size(Vector2i(1920, 1080))
        root.size = Vector2i(1920, 1080)
    var packed: PackedScene = load("res://scenes/main.tscn")
    if packed == null:
        quit(2)
        return
    var world: Node3D = packed.instantiate()
    root.add_child(world)
    world.add_child(Runner.new())
