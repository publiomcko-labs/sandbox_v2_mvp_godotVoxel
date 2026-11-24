extends SceneTree
# A8-P4 independent rendering evidence. Uses the original A5 CPU16 World,
# original mesh and actual Compatibility opaque depth attachment. Readbacks
# are deliberately outside the FPS benchmark and cannot certify STREAM-18.
const TerrainSDF = preload("res://scripts/terrain_sdf.gd")
const VIEW_X := 1920
const VIEW_Y := 1080
const WARMUP_FRAMES := 1000
const SEED := 20261119
const ORIGIN := Vector3(192.0, 22.0, 18.0)
const DISTANCE_LIMIT_M := 130.0
const MARGIN_M := 1.0
const MAX_EXPECTED_RAY_M := 320.0
const STRIDE_M := 0.5
const COLUMNS := [240,480,720,960,1200,1440,1680]
const ROWS := [280,400,520,640,760]
const SHADER_PATH := "res://shaders/a8_p4_depth_130.gdshader"

var _outdir := ""
var _calibrations: Array = []
var _world: Node3D
var _terrain: VoxelLodTerrain
var _player: Node3D
var _camera: Camera3D
var _overlay: MeshInstance3D
var _generator: VoxelGeneratorGraph
var _warmup_observed := 0
var _warmup_s := 0.0
var _failure := ""

func _initialize() -> void:
    call_deferred("_start")

func _fail(reason: String) -> void:
    _failure = reason
    push_error("A8_P4_FAIL " + reason)
    if not _outdir.is_empty():
        var f := FileAccess.open(_outdir.path_join("a8_p4_failure.json"), FileAccess.WRITE)
        if f != null:
            f.store_string(JSON.stringify({
                "schema":"a8_p4_failure_v1", "reason":reason,
                "calibrations":_calibrations,
                "warmup_drawn_frames":_warmup_observed,
                "strict_view_130":"NOT_QUALIFIED"
            }, "  "))
            f.close()
    quit(2)

func _save_json(filename: String, value: Dictionary) -> bool:
    var f := FileAccess.open(_outdir.path_join(filename), FileAccess.WRITE)
    if f == null:
        return false
    f.store_string(JSON.stringify(value, "  "))
    f.close()
    return true

func _sample_color(c: Color) -> String:
    if c.g > 0.75 and c.r < 0.30 and c.b < 0.30:
        return "DEPTH_INSIDE_130"
    if c.r > 0.75 and c.g > 0.75 and c.b < 0.30:
        return "DEPTH_BORDERLINE_130"
    if c.r > 0.75 and c.g < 0.30 and c.b < 0.30:
        return "DEPTH_OUTSIDE_130"
    if c.b > 0.75 and c.g < 0.30 and c.r < 0.30:
        return "DEPTH_NO_OPAQUE_HIT"
    return "DEPTH_INVALID_COLOR"

func _new_counts() -> Dictionary:
    return {
        "DEPTH_INSIDE_130":0,"DEPTH_BORDERLINE_130":0,
        "DEPTH_OUTSIDE_130":0,"DEPTH_NO_OPAQUE_HIT":0,
        "DEPTH_INVALID_COLOR":0
    }

func _readback() -> Image:
    # Three complete frames make toggled overlay and new camera pose visible
    # before the readback. No GPU readback is used in any performance arm.
    for _i in range(3):
        await process_frame
    await RenderingServer.frame_post_draw
    var image: Image = root.get_texture().get_image()
    if image == null or image.is_empty() or image.get_width() != VIEW_X or image.get_height() != VIEW_Y:
        return null
    return image

func _new_calibration_panel() -> MeshInstance3D:
    var obj := MeshInstance3D.new()
    var box := BoxMesh.new()
    box.size = Vector3(10.0, 10.0, 0.25)
    obj.mesh = box
    var mat := StandardMaterial3D.new()
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.albedo_color = Color.WHITE
    obj.material_override = mat
    obj.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _camera.add_child(obj)
    return obj

func _calibrate() -> bool:
    var panel := _new_calibration_panel()
    _camera.rotation.x = deg_to_rad(12.0) # Clear sky for a known test surface.
    for distance_m in [25.0, 165.0]:
        panel.position = Vector3(0.0, 0.0, -distance_m)
        _overlay.visible = true
        var image: Image = await _readback()
        if image == null:
            panel.queue_free()
            return false
        var center := image.get_pixel(960,540)
        var category := _sample_color(center)
        var file := "a8p4_calibration_%03dm.png" % int(distance_m)
        var save_ok := image.save_png(_outdir.path_join(file)) == OK
        var expected := "DEPTH_INSIDE_130" if distance_m < 130.0 else "DEPTH_OUTSIDE_130"
        _calibrations.append({
            "panel_camera_distance_m":distance_m,
            "observed_center_category":category,
            "expected_center_category":expected,
            "pixel_rgb":[center.r,center.g,center.b],
            "png":file,
            "passed":save_ok and category == expected
        })
        if not save_ok or category != expected:
            panel.queue_free()
            _overlay.visible = false
            return false
    panel.queue_free()
    _overlay.visible = false
    _camera.rotation.x = deg_to_rad(-22.0)
    return true

func _expected_sdf(ray_origin: Vector3, ray_dir: Vector3, anchor: Vector3) -> Dictionary:
    var dist := _generator.raycast_sdf_approx(
        ray_origin, ray_origin + ray_dir * MAX_EXPECTED_RAY_M, STRIDE_M)
    if not is_finite(dist) or dist < 0.0:
        return {"category":"SDF_NO_HIT","horizontal_m":null}
    var point: Vector3 = ray_origin + ray_dir * dist
    var horizontal_m := Vector2(point.x-anchor.x,point.z-anchor.z).length()
    var category := ("SDF_INSIDE_130" if horizontal_m < DISTANCE_LIMIT_M - MARGIN_M else
        "SDF_OUTSIDE_130" if horizontal_m > DISTANCE_LIMIT_M + MARGIN_M else
        "SDF_BORDERLINE_130")
    return {"category":category,"horizontal_m":snappedf(horizontal_m,0.001),
            "hit_world_xyz":[point.x,point.y,point.z]}

func _capture_heading(index: int) -> Dictionary:
    _player.rotation.y = -TAU * float(index) / 8.0
    _overlay.visible = false
    var normal: Image = await _readback()
    if normal == null:
        return {}
    var normal_name := "a8p4_heading_%02d_rgb.png" % index
    if normal.save_png(_outdir.path_join(normal_name)) != OK:
        return {}
    _overlay.visible = true
    var depth: Image = await _readback()
    if depth == null:
        return {}
    var depth_name := "a8p4_heading_%02d_depth.png" % index
    if depth.save_png(_outdir.path_join(depth_name)) != OK:
        return {}
    _overlay.visible = false
    var counted := _new_counts()
    var expected_inside := 0
    var matched_inside := 0
    var missing_inside := 0
    var candidates: Array = []
    for py in ROWS:
        for px in COLUMNS:
            var sample_pixel := Vector2(px,py)
            var ray_origin: Vector3 = _camera.project_ray_origin(sample_pixel)
            var ray_dir: Vector3 = _camera.project_ray_normal(sample_pixel).normalized()
            var sdf := _expected_sdf(ray_origin,ray_dir,_player.global_position)
            var color := depth.get_pixel(px,py)
            var observed := _sample_color(color)
            counted[observed] += 1
            if sdf["category"] == "SDF_INSIDE_130":
                expected_inside += 1
                if observed == "DEPTH_INSIDE_130":
                    matched_inside += 1
                else:
                    missing_inside += 1
            candidates.append({
                "pixel_1080":[px,py],
                "sdf_category":sdf["category"],
                "sdf_horizontal_m":sdf["horizontal_m"],
                "rendered_depth_category":observed,
                "rgb_depth":[snappedf(color.r,0.001),
                             snappedf(color.g,0.001),snappedf(color.b,0.001)],
                "sampled_agreement":sdf["category"] == "SDF_INSIDE_130" and
                    observed == "DEPTH_INSIDE_130"
            })
    return {
        "heading_index":index, "yaw_deg":-45.0*float(index),
        "player_xyz":[_player.global_position.x,_player.global_position.y,_player.global_position.z],
        "camera_pitch_deg":-22.0,"camera_fov_deg":_camera.fov,
        "expected_ground_inside_130_sampled":expected_inside,
        "depth_inside_130_sampled":counted["DEPTH_INSIDE_130"],
        "expected_ground_inside_and_depth_inside":matched_inside,
        "expected_ground_inside_but_depth_not_inside":missing_inside,
        "observed_depth_categories":counted,
        "rgb_image":normal_name, "depth_image":depth_name,
        "sample_count":candidates.size(), "samples":candidates,
        "independent_sources":{
            "ground_expectation":"BASELINE_VOXEL_GENERATOR_SDF_RAYCAST",
            "visual_observation":"GL_COMPATIBILITY_ACTUAL_OPAQUE_DEPTH_ATTACHMENT"
        }
    }

func _start() -> void:
    var ci_only := OS.get_cmdline_user_args().has("--ci-contract")
    if ci_only:
        var loaded_shader: Shader = load(SHADER_PATH) as Shader
        if loaded_shader == null:
            _fail("A8-P4 depth shader resource missing")
            return
        print("A8_P4_CI_CONTRACT_PASS shader_loaded=true GPU_depth_not_measured=true")
        quit(0)
        return
    _outdir = OS.get_environment("A8_P4_OUTPUT_DIR")
    if _outdir.is_empty() or DirAccess.make_dir_recursive_absolute(_outdir) != OK:
        _fail("dedicated A8_P4_OUTPUT_DIR required")
        return
    if DisplayServer.get_name() == "headless" or
            RenderingServer.get_current_rendering_method() != "gl_compatibility" or
            RenderingServer.get_current_rendering_driver_name().to_lower() != "opengl3":
        _fail("real Compatibility OpenGL3 GPU renderer required")
        return
    DisplayServer.window_set_size(Vector2i(VIEW_X,VIEW_Y))
    DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS,true)
    DisplayServer.window_set_position(Vector2i.ZERO)
    root.size = Vector2i(VIEW_X,VIEW_Y)
    var packed: PackedScene = load("res://scenes/main.tscn")
    if packed == null:
        _fail("baseline scene not found")
        return
    _world = packed.instantiate()
    _terrain = _world.get_node("Terrain") as VoxelLodTerrain
    _player = _world.get_node("Player") as Node3D
    _camera = _world.get_node("Player/Camera3D") as Camera3D
    if _terrain == null or _player == null or _camera == null:
        _fail("missing A5 baseline nodes")
        return
    if _terrain.mesh_block_size != 16 or _terrain.lod_count != 4 or
            _terrain.view_distance != 192 or
            absf(_terrain.lod_distance-48.0) > 0.001 or
            _terrain.use_gpu_generation or _terrain.world_seed != SEED:
        _fail("baseline A5 CPU16 mesh4 / view192 mismatch")
        return
    var savepath := OS.get_environment("A3_SAVE_PATH")
    if savepath.is_empty():
        _fail("isolated A3_SAVE_PATH required")
        return
    root.add_child(_world)
    _player.set_process(false)
    _player.set_physics_process(false)
    _player.set_process_unhandled_input(false)
    _player.global_position = ORIGIN
    _world.get_node("HUD").visible = false
    _world.get_node("Terrain/RockInstancer").visible = false
    _world.get_node("RockManager").visible = false
    _world.get_node("Water").visible = false
    _generator = TerrainSDF.build_generator(SEED)
    if _generator == null:
        _fail("native independent generator compile failed")
        return
    var shader: Shader = load(SHADER_PATH)
    if shader == null:
        _fail("depth shader resource not available")
        return
    var material := ShaderMaterial.new()
    material.shader = shader
    material.render_priority = 127
    _overlay = MeshInstance3D.new()
    var quad := QuadMesh.new()
    quad.size = Vector2(2.0,2.0)
    quad.flip_faces = true
    _overlay.mesh = quad
    _overlay.material_override = material
    _overlay.extra_cull_margin = 10000.0
    _overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    _camera.add_child(_overlay)
    _overlay.position = Vector3(0.0,0.0,-1.0)
    _overlay.visible = false
    var warmup_begin := Time.get_ticks_msec()
    var initial_frames := Engine.get_frames_drawn()
    while Engine.get_frames_drawn() - initial_frames < WARMUP_FRAMES:
        await process_frame
        if Time.get_ticks_msec() - warmup_begin > 180000:
            _fail("1000 actual drawn frame watchdog exceeded 180s")
            return
    _warmup_observed = Engine.get_frames_drawn()-initial_frames
    _warmup_s = float(Time.get_ticks_msec()-warmup_begin)/1000.0
    if not await _calibrate():
        _fail("actual GL depth reconstruction failed calibrated 25m/165m panels")
        return
    var headings: Array = []
    for i in range(8):
        var observation: Dictionary = await _capture_heading(i)
        if observation.is_empty() or observation.get("sample_count",-1) != COLUMNS.size()*ROWS.size():
            _fail("missing heading pair or pixel observations for heading "+str(i))
            return
        headings.append(observation)
    var total_expected := 0
    var total_matched := 0
    var total_missing := 0
    for h in headings:
        total_expected += int(h["expected_ground_inside_130_sampled"])
        total_matched += int(h["expected_ground_inside_and_depth_inside"])
        total_missing += int(h["expected_ground_inside_but_depth_not_inside"])
    var report := {
        "schema":"a8_p4_opaque_depth_evidence_v1",
        "source_baseline":"A5_CPU16_GL_COMPATIBILITY",
        "world_seed":SEED,"camera_origin_xyz":[ORIGIN.x,ORIGIN.y,ORIGIN.z],
        "warmup_frames_requested":WARMUP_FRAMES,
        "warmup_frames_observed":_warmup_observed,
        "warmup_elapsed_s":_warmup_s,
        "renderer":RenderingServer.get_current_rendering_method(),
        "driver":RenderingServer.get_current_rendering_driver_name(),
        "capture_size_px":[VIEW_X,VIEW_Y],
        "headings":8,"horizontal_radius_m":DISTANCE_LIMIT_M,
        "margin_m":MARGIN_M,
        "pixels_per_heading":COLUMNS.size()*ROWS.size(),
        "calibrations":_calibrations,"observations":headings,
        "ground_expected_inside_130_samples":total_expected,
        "ground_expected_inside_and_depth_inside":total_matched,
        "ground_expected_inside_but_depth_not_inside":total_missing,
        "ground_reference":"SDF_RAYCAST_EXPECTED_NOT_MESH",
        "raster_reference":"POST_OPAQUE_REAL_GL_DEPTH_TEXTURE_UNPROJECTED",
        "depth_shader":"res://shaders/a8_p4_depth_130.gdshader",
        "rocks_water_hidden_during_capture":true,
        "hud_hidden":true,
        "screenshot_readback_perf_invalid":true,
        "stationary_probe_only_no_continuous_18mps_video":true,
        "opaque_depth_not_object_identity":true,
        "sample_coverage_not_full_screen_guarantee":true,
        "perf_60":"NOT_QUALIFIED","stream_18":"NOT_QUALIFIED",
        "view_130":"NOT_QUALIFIED","edit_100":"NOT_QUALIFIED",
        "automatic_acceptance":false
    }
    if not _save_json("a8_p4_depth_evidence.json",report):
        _fail("cannot persist calibrated depth evidence")
        return
    print("A8_P4_CAPTURE_OK warmup=", _warmup_observed,
        " headings=8 samples=",8*COLUMNS.size()*ROWS.size(),
        " expected_ground_inside=",total_expected,
        " observed_depth_inside=",total_matched,
        " depth_mismatch=",total_missing,
        " strict=NOT_QUALIFIED")
    quit(0)
