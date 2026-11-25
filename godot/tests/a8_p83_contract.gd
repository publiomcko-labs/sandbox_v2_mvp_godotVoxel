extends SceneTree
# CPU parse/resource test only. Real GPU screen/depth sampling is not proven.
const Tags = preload("res://tests/a8_p83_object_tags.gd")
const Depth = preload("res://tests/a8_p81_metric_depth.gd")
const Runner = preload("res://tests/a7_edit_runner.gd")

func _initialize() -> void:
    call_deferred("_start")

func _start() -> void:
    var probe: Node=Depth.new()
    var rock: ShaderMaterial=Tags.make(Color.RED)
    var water: ShaderMaterial=Tags.make(Color.BLUE,true)
    var shader: Shader=load("res://shaders/a8_p83_semantic_depth.gdshader") as Shader
    var valid: bool=(not Tags.active() and rock.shader.resource_path=="res://shaders/a8_p83_object_tag.gdshader" and water.shader.resource_path=="res://shaders/a8_p83_water_tag.gdshader" and shader!=null and Runner!=null)
    probe.free()
    if not valid:
        push_error("A8_P83_HEADLESS_RESOURCE_FAIL")
        quit(2)
        return
    print("A8_P83_HEADLESS_RESOURCE_PASS GPU_MASK_NOT_MEASURED")
    quit(0)
