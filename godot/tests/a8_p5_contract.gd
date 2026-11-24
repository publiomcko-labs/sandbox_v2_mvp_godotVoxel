extends SceneTree
# CPU-only parse/load test. Does NOT validate renderer, NVENC, or real depth.
const A8P5Depth = preload("res://tests/a8_p5_depth_video.gd")
const A7Runtime = preload("res://tests/a7_route_runtime.gd")
const A7Runner = preload("res://tests/a7_route_runner.gd")

func _initialize() -> void:
    call_deferred("_start")

func _start() -> void:
    var obj: Node = A8P5Depth.new()
    var shader: Shader = load("res://shaders/a8_p4_depth_130.gdshader")
    if obj==null or shader==null or A7Runtime==null or A7Runner==null:
        push_error("A8_P5_HEADLESS_CONTRACT_RESOURCE_FAILED")
        quit(2)
        return
    obj.free()
    print("A8_P5_HEADLESS_GDSCRIPT_CONTRACT_PASS GPU_DEPTH_NOT_MEASURED strict=NOT_QUALIFIED")
    quit(0)
