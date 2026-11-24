extends Node
# A8-P5 isolated real GPU depth-video producer, attached only to A7 visual
# evidence runs. This shader postprocess must NEVER enter performance runs.
const TerrainSDF = preload("res://scripts/terrain_sdf.gd")
const DEPTH_SHADER = "res://shaders/a8_p4_depth_130.gdshader"
const COLUMNS := [240,480,720,960,1200,1440,1680]
const ROWS := [280,400,520,640,760]
var calibrations: Array = []
var sample_count := 0
var _camera: Camera3D
var _player: Node3D
var _generator: VoxelGeneratorGraph
var _overlay: MeshInstance3D

func setup(player: Node3D,camera: Camera3D,seed_value: int) -> bool:
    _camera=camera
    _player=player
    var shader: Shader = load(DEPTH_SHADER) as Shader
    if shader==null:
        return false
    _generator=TerrainSDF.build_generator(seed_value)
    if _generator==null:
        return false
    var material := ShaderMaterial.new()
    material.shader=shader
    material.render_priority=127
    _overlay=MeshInstance3D.new()
    var quad := QuadMesh.new()
    quad.size=Vector2(2.0,2.0)
    quad.flip_faces=true
    _overlay.mesh=quad
    _overlay.material_override=material
    _overlay.extra_cull_margin=10000.0
    _overlay.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _camera.add_child(_overlay)
    _overlay.position=Vector3(0.0,0.0,-1.0)
    _overlay.visible=false
    return true

func _category(color: Color) -> String:
    if color.g>0.75 and color.r<0.30 and color.b<0.30:
        return "DEPTH_INSIDE_130"
    if color.r>0.75 and color.g>0.75 and color.b<0.30:
        return "DEPTH_BORDERLINE_130"
    if color.r>0.75 and color.g<0.30 and color.b<0.30:
        return "DEPTH_OUTSIDE_130"
    if color.b>0.75 and color.g<0.30 and color.r<0.30:
        return "DEPTH_NO_OPAQUE_HIT"
    return "DEPTH_INVALID_COLOR"

func calibrate() -> bool:
    var panel := MeshInstance3D.new()
    var box := BoxMesh.new()
    box.size=Vector3(10.0,10.0,0.25)
    panel.mesh=box
    var mat := StandardMaterial3D.new()
    mat.shading_mode=BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.albedo_color=Color.WHITE
    panel.material_override=mat
    panel.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _camera.add_child(panel)
    var original_pitch := _camera.rotation.x
    _camera.rotation.x=deg_to_rad(12.0)
    var valid := true
    for distance_m in [25.0,165.0]:
        panel.position=Vector3(0.0,0.0,-distance_m)
        _overlay.visible=true
        for _frame in range(3):
            await get_tree().process_frame
        await RenderingServer.frame_post_draw
        var img: Image=get_viewport().get_texture().get_image()
        if img==null or img.is_empty() or img.get_width()!=1920 or img.get_height()!=1080:
            valid=false
            break
        var observed := _category(img.get_pixel(960,540))
        var expected := "DEPTH_INSIDE_130" if distance_m==25.0 else "DEPTH_OUTSIDE_130"
        calibrations.append({
            "distance_m":distance_m,"observed":observed,"expected":expected,
            "passed":observed==expected})
        if observed!=expected:
            valid=false
            break
    _overlay.visible=false
    _camera.rotation.x=original_pitch
    panel.queue_free()
    return valid and calibrations.size()==2

func begin_video() -> void:
    _overlay.visible=true

func expectation(t: float) -> Dictionary:
    _player.force_update_transform()
    _camera.force_update_transform()
    var samples: Array=[]
    var expected_inside := 0
    for py in ROWS:
        for px in COLUMNS:
            var uv := Vector2(float(px),float(py))
            var origin: Vector3=_camera.project_ray_origin(uv)
            var direction: Vector3=_camera.project_ray_normal(uv).normalized()
            var ray_m: float=_generator.raycast_sdf_approx(origin,origin+direction*320.0,0.5)
            var horizontal := -1.0
            if is_finite(ray_m) and ray_m>=0.0:
                var hit := origin+direction*ray_m
                horizontal=Vector2(hit.x-_player.global_position.x,
                                   hit.z-_player.global_position.z).length()
            # ±5m is deliberately larger than camera travel during 50ms of
            # NVENC PTS/HUD alignment uncertainty (<1m at 18m/s).
            var kind := ("SDF_INSIDE_125" if horizontal>=0.0 and horizontal<125.0 else
                "SDF_BOUNDARY_125_135" if horizontal>=125.0 and horizontal<=135.0 else
                "SDF_OUTSIDE_135" if horizontal>135.0 else "SDF_NO_HIT")
            if kind=="SDF_INSIDE_125":
                expected_inside+=1
            samples.append({
                "pixel_1080":[px,py],"sdf_category":kind,
                "sdf_horizontal_m":snappedf(horizontal,0.001) if horizontal>=0.0 else null})
    sample_count+=1
    return {
        "type":"a8_p5_sdf_expectation",
        "index":int(floor(t)),"route_t_s":snappedf(t,0.0001),
        "frame_drawn":Engine.get_frames_drawn(),
        "player_xyz":[_player.global_position.x,_player.global_position.y,_player.global_position.z],
        "yaw_rad":_player.rotation.y,"pitch_rad":_camera.rotation.x,
        "expected_inside_125":expected_inside,"sample_count":samples.size(),
        "samples":samples,
        "ground_source":"GENERATOR_ONLY_NOT_RENDERED",
        "video_synchronization":"HUD_MARKER_AND_NVENC_PTS_APPROXIMATE"
    }
