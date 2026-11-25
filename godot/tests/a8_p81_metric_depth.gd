extends Node
# Isolated diagnostic overlay. Calibration readbacks are before warmup only.
var overlay: MeshInstance3D
var calibrations: Array = []
var camera: Camera3D
var hud: Node
var bits: Array[ColorRect] = []
var precise: bool = false
var semantic: bool = false
var mask_calibrations: Array = []

func setup(cam: Camera3D, hud_node: Node, precision_mode: bool = false, semantic_mode: bool = false) -> bool:
    precise=precision_mode
    semantic=semantic_mode
    camera=cam
    hud=hud_node
    var shader_path: String = "res://shaders/a8_p82_metric_depth.gdshader" if precise else "res://shaders/a8_p81_metric_depth.gdshader"
    if semantic:
        shader_path="res://shaders/a8_p83_semantic_depth.gdshader"
    var shader: Shader=load(shader_path) as Shader
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

func invalidate_stamp() -> void:
    for b in bits:
        b.color=Color.BLACK

func set_range_start(value: float) -> void:
    if precise:
        var material: ShaderMaterial=overlay.material_override as ShaderMaterial
        material.set_shader_parameter("range_start_m",value)

func snapshot(tool: VoxelTool, center: Vector3, radius: float) -> Dictionary:
    # All points are inside can_edit_sphere's radius+2 editable extent.
    # Capture pre-brush integer SDF lattice, independently evaluate CSG offline.
    var extent: float=radius+1.0
    var lo:=Vector3i(floori(center.x-extent),floori(center.y-extent),floori(center.z-extent))
    var hi:=Vector3i(ceili(center.x+extent),ceili(center.y+extent),ceili(center.z+extent))
    var values: Array=[]
    for z in range(lo.z,hi.z+1):
        for y in range(lo.y,hi.y+1):
            for x in range(lo.x,hi.x+1):
                values.append(tool.get_voxel_f(Vector3i(x,y,z)))
    return {"lo":[lo.x,lo.y,lo.z],"hi":[hi.x,hi.y,hi.z],"values":values,"order":"zyx_x_fastest"}

func calibrate(folder: String) -> bool:
    var panel:=MeshInstance3D.new()
    var box:=BoxMesh.new()
    box.size=Vector3(8,8,0.2)
    panel.mesh=box
    var mat:=StandardMaterial3D.new()
    mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.albedo_color=Color.WHITE
    panel.material_override=preload("res://tests/a8_p83_object_tags.gd").make(Color.GREEN) if semantic else mat
    camera.add_child(panel)
    var original:=camera.rotation
    camera.rotation=Vector3(deg_to_rad(25.0),0,0)
    overlay.visible=true
    var valid:=true
    var last:float=-1
    var distances: Array = [10.0,11.0,12.0,13.0,14.0,15.0,16.0] if precise else [5.0,10.0,15.0,20.0,25.0,30.0,35.0]
    if semantic:
        distances=[]
        for i in range(11):
            distances.append(9.4+0.45*i)
    if precise:
        set_range_start(9.0)
    for distance in distances:
        panel.position=Vector3(0,0,-distance)
        for i in range(5):
            await RenderingServer.frame_post_draw
        var cal_id: int=3900+calibrations.size()
        if precise:
            stamp(cal_id)
            for i in range(12):
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
        var filename:="a8_p83_cal_%02d.png"%calibrations.size() if semantic else "a8_p81_cal_%02d.png"%int(distance)
        if img.save_png(folder.path_join(filename))!=OK or gray<=last+0.025 or absf(color.r-color.g)>0.03 or absf(color.r-color.b)>0.03:
            valid=false
            break
        calibrations.append({"distance_m":expected,"gray":gray,"pixel":[960,516],"file":filename,"stamp_id":cal_id if precise else null,"range_start_m":9.0 if precise else 0.0})
        last=gray
        invalidate_stamp()
        await RenderingServer.frame_post_draw
    if semantic and valid:
        panel.position=Vector3(0,0,-11.5)
        var tags=preload("res://tests/a8_p83_object_tags.gd")
        for k in range(3):
            var label: String=["ROCK","WATER","UNKNOWN"][k]
            var tag_color: Color=[Color.RED,Color.BLUE,Color(0.5,0.5,0.5)][k]
            panel.material_override=tags.make(tag_color)
            for i in range(5):
                await RenderingServer.frame_post_draw
            var cal_id: int=3920+k
            stamp(cal_id)
            for i in range(12):
                await RenderingServer.frame_post_draw
            var img: Image=get_viewport().get_texture().get_image()
            if img==null or img.is_empty() or img.get_width()!=1920 or img.get_height()!=1080:
                valid=false
                break
            var c: Color=img.get_pixel(960,516)
            var mask_ok: bool=(c.r>0.8 and c.g<0.2 and c.b<0.2) if k==0 else ((c.b>0.8 and c.r<0.2 and c.g<0.2) if k==1 else (c.r>0.8 and c.b>0.8 and c.g<0.2))
            var name: String="a8_p83_mask_%02d.png"%k
            if not mask_ok or img.save_png(folder.path_join(name))!=OK:
                valid=false
                break
            mask_calibrations.append({"stamp_id":cal_id,"expected":label,"pixel":[960,516],"file":name})
            invalidate_stamp()
            await RenderingServer.frame_post_draw
    panel.queue_free()
    camera.rotation=original
    overlay.visible=false
    return valid and calibrations.size()==(11 if semantic else 7) and (not semantic or mask_calibrations.size()==3)

func enable_depth() -> void:
    overlay.visible=true
