extends RefCounted
# Used only by the opt-in P8.3 edit evidence scene.
static func active() -> bool:
    return OS.get_cmdline_user_args().has("--a8-p83")

static func make(color: Color, two_sided: bool = false) -> ShaderMaterial:
    var mat:=ShaderMaterial.new()
    mat.shader=preload("res://shaders/a8_p83_water_tag.gdshader") if two_sided else preload("res://shaders/a8_p83_object_tag.gdshader")
    mat.set_shader_parameter("tag_color",color)
    return mat
