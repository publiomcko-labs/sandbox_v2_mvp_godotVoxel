extends SceneTree
# Launch: godot.exe --path godot --script res://tests/a2_benchmark.gd -- --route=...
# A separate main loop leaves the regular interactive scene untouched.
const Routes = preload("res://tests/a2_routes.gd")
const Runtime = preload("res://tests/a2_runtime.gd")

func _initialize() -> void:
    call_deferred("_boot")

func _get_arg(name: String, fallback: String) -> String:
    var prefix := "--" + name + "="
    for arg in OS.get_cmdline_user_args():
        if arg.begins_with(prefix):
            return arg.substr(prefix.length())
    return fallback

func _has_arg(name: String) -> bool:
    for arg in OS.get_cmdline_user_args():
        if arg == "--" + name:
            return true
    return false

func _boot() -> void:
    var route := _get_arg("route", "out_and_back_18mps_300s")
    var nominal := Routes.duration_for(route)
    if nominal <= 0.0:
        push_error("A2_CONFIG_FAIL: unknown route " + route)
        quit(2)
        return
    var duration_s := float(_get_arg("duration", str(nominal)))
    var warmup_s := float(_get_arg("warmup", "45.0"))
    if duration_s <= 0.0 or duration_s > nominal or warmup_s < 0.0 or warmup_s > 180.0:
        push_error("A2_CONFIG_FAIL: invalid duration or warmup")
        quit(2)
        return

    if DisplayServer.get_name() != "headless":
        DisplayServer.window_set_size(Vector2i(1920, 1080))
        root.size = Vector2i(1920, 1080)

    var packed: PackedScene = load("res://scenes/main.tscn")
    if packed == null:
        push_error("A2_CONFIG_FAIL: cannot load main scene")
        quit(2)
        return
    var world := packed.instantiate()
    root.add_child(world)
    var runner := Runtime.new()
    runner.route = route
    runner.duration_sec = duration_s
    runner.warmup_sec = warmup_s
    runner.ci_smoke = _has_arg("ci-smoke")
    runner.capture_screenshots = _has_arg("capture")
    world.add_child(runner)
