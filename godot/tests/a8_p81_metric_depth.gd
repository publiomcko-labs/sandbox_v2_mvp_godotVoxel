extends Node
# Isolated diagnostic overlay. Calibration readbacks are before warmup only.
var overlay: MeshInstance3D
var calibrations: Array = []
var camera: Camera3D
var hud: Node
var bits: Array[ColorRect] = []

func setup(cam: Camera3D, hud_node: Node) -> bool:
    camera=cam
    hud=hud_node
    var shader: Shader=load("res://shaders/a8_p81_metric_depth.gdshader") as Shader
    if shader==null:
        return false
    var mat:=ShaderMaterial.new()
    mat.shader=shader
    mat.render_priority=127
    overlay=MeshInstance3D.new()
    var quad:=QuadMesh.new()
    quad.size=Vector2(2,2)
    quad.flip_faces=true
    overlay.mesh=quad
    overlay.material_override=mat
    overlay.extra_cull_margin=10000
    overlay.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    camera.add_child(overlay)
    overlay.position=Vector3(0,0,-1)
    overlay.visible=false
    for i in range(14):
        var b:=ColorRect.new()
        b.position=Vector2(24+i*24,24)
        b.size=Vector2(20,20)
        b.color=Color.BLACK
        b.mouse_filter=Control.MOUSE_FILTER_IGNORE
        hud.add_child(b)
        bits.append(b)
    return true

func stamp(id: int) -> void:
    # Fixed white start, 12-bit unsigned ID, fixed black end.
    bits[0].color=Color.WHITE
    for i in range(12):
        bits[i+1].color=Color.WHITE if (id & (1<<i))!=0 else Color.BLACK
    bits[13].color=Color.BLACK

func calibrate(folder: String) -> bool:
    var panel:=MeshInstance3D.new()
    var box:=BoxMesh.new()
    box.size=Vector3(8,8,0.2)
    panel.mesh=box
    var mat:=StandardMaterial3D.new()
    mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.albedo_color=Color.WHITE
    panel.material_override=mat
    camera.add_child(panel)
    var original:=camera.rotation
    camera.rotation=Vector3(deg_to_rad(25.0),0,0)
    overlay.visible=true
    var valid:=true
    var last:float=-1
    for distance in [5.0,10.0,15.0,20.0,25.0,30.0,35.0]:
        panel.position=Vector3(0,0,-distance)
        for i in range(5):
            await RenderingServer.frame_post_draw
        var img:Image=get_viewport().get_texture().get_image()
        if img==null or img.is_empty() or img.get_width()!=1920 or img.get_height()!=1080:
            valid=false
            break
        # Away from crosshair: exact radial distance to the front plane.
        var pixel:=Vector2(960,516)
        var direction:=camera.project_ray_normal(pixel)
        var forward:Vector3=-camera.global_transform.basis.z.normalized()
        var expected:float=(distance-0.1)/direction.dot(forward)
        var color:=img.get_pixel(960,516)
        var gray:float=(color.r+color.g+color.b)/3.0
        var filename:="a8_p81_cal_%02d.png"%int(distance)
        if img.save_png(folder.path_join(filename))!=OK or gray<=last+0.025 or absf(color.r-color.g)>0.03 or absf(color.r-color.b)>0.03:
            valid=false
            break
        calibrations.append({"distance_m":expected,"gray":gray,"pixel":[960,516],"file":filename})
        last=gray
    panel.queue_free()
    camera.rotation=original
    overlay.visible=false
    return valid and calibrations.size()==7

func enable_depth() -> void:
    overlay.visible=true
