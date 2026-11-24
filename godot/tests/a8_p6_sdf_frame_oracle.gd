extends SceneTree
# A8-P6 frame-grid SDF oracle; CPU-only, 0..30s at 60Hz, 7 fixed rays.
# This reconstructs expected procedural ground only, NOT actual mesh/depth.
# It intentionally does NOT load the private MKV or modify active terrain.
const TerrainSDF = preload("res://scripts/terrain_sdf.gd")
const Routes = preload("res://tests/a7_routes.gd")
const OUTPUT_NAME := "a8_p6_expected_sdf_60hz.json"
const SEED := 20261119
const FPS := 60
const DURATION_S := 30
const FRAME_COUNT := FPS * DURATION_S
const MAX_SDF_RAY_M := 320.0
const STRIDE_M := 0.5
const PIXELS := [
    Vector2i(240,400), Vector2i(960,400), Vector2i(1680,400),
    Vector2i(480,640), Vector2i(960,640), Vector2i(1440,640),
    Vector2i(960,760)
]

func _initialize() -> void:
    call_deferred("_start")

func _fail(reason: String) -> void:
    push_error("A8_P6_ORACLE_FAIL "+reason)
    quit(2)

func _start() -> void:
    var path := OS.get_environment("A8_P6_OUTPUT_DIR")
    if path.is_empty() or DirAccess.make_dir_recursive_absolute(path) != OK:
        _fail("A8_P6_OUTPUT_DIR required; refuse ambiguous output")
        return
    var generator: VoxelGeneratorGraph = TerrainSDF.build_generator(SEED)
    if generator == null:
        _fail("VoxelGeneratorGraph compile failed")
        return
    root.size = Vector2i(1920,1080)
    var rig := Node3D.new()
    root.add_child(rig)
    var camera := Camera3D.new()
    camera.fov = 75.0
    camera.far = 320.0
    camera.rotation.x = deg_to_rad(-22.0)
    rig.add_child(camera)
    camera.make_current()
    await process_frame
    await process_frame
    if get_root().get_visible_rect().size != Vector2(1920,1080):
        _fail("Unexpected headless viewport size: "+str(get_root().get_visible_rect().size))
        return
    var distances_cm: Array=[]
    var valid_hits := 0
    var no_hits := 0
    for n in range(FRAME_COUNT):
        var t := float(n)/float(FPS)
        var pos: Vector3 = Routes.position_for("turns_18mps_300s",t)
        var future: Vector3 = Routes.position_for("turns_18mps_300s",minf(t+0.04,30.0))
        var motion := future-pos
        if motion.length_squared()<0.0001:
            motion=pos-Routes.position_for("turns_18mps_300s",maxf(0.0,t-0.04))
        if motion.length_squared()<0.0001:
            _fail("Invalid route yaw at t="+str(t))
            return
        rig.global_position=pos
        rig.rotation.y=atan2(-motion.x,-motion.z)
        rig.force_update_transform()
        camera.force_update_transform()
        var distances: Array=[]
        for pixel in PIXELS:
            var origin: Vector3 = camera.project_ray_origin(Vector2(float(pixel.x),float(pixel.y)))
            var direction: Vector3 = camera.project_ray_normal(Vector2(float(pixel.x),float(pixel.y))).normalized()
            if not origin.is_finite() or not direction.is_finite():
                _fail("Invalid camera ray at frame "+str(n))
                return
            var hit_distance: float = generator.raycast_sdf_approx(
                origin,origin+direction*MAX_SDF_RAY_M,STRIDE_M)
            if is_finite(hit_distance) and hit_distance>=0.0:
                var hit: Vector3 = origin+direction*hit_distance
                var horizontal: float = Vector2(hit.x-pos.x,hit.z-pos.z).length()
                if not is_finite(horizontal) or horizontal<0.0 or horizontal>MAX_SDF_RAY_M+0.5:
                    _fail("SDF distance out of bounds at frame "+str(n))
                    return
                distances.append(int(round(horizontal*100.0)))
                valid_hits+=1
            else:
                distances.append(-1)
                no_hits+=1
        distances_cm.append(distances)
        if n%300==0:
            print("A8_P6_ORACLE_PROGRESS n=",n," hits=",valid_hits," no_hits=",no_hits)
    var result := {
        "schema":"a8_p6_sdf_60hz_v1",
        "seed":SEED,"route":"turns_18mps_300s","duration_s":DURATION_S,
        "fixed_fps":FPS,"frame_count":FRAME_COUNT,
        "source":"A5_CPU16_PROCEDURAL_GENERATOR_RECONSTRUCTION",
        "screen_px":[1920,1080],
        "camera_fov_vertical_deg":75.0,"camera_pitch_deg":-22.0,
        "camera_raycast_stride_m":STRIDE_M,"max_ray_m":MAX_SDF_RAY_M,
        "pixel_grid_px": [
            [240,400],[960,400],[1680,400],
            [480,640],[960,640],[1440,640],[960,760]
        ],
        "distance_units":"horizontal_centimeters", "no_hit_sentinel":-1,
        "rays_cm":distances_cm,
        "valid_sdf_hit_count":valid_hits,
        "no_sdf_hit_count":no_hits,
        "source_video_not_provided_to_cpu_ci":true,
        "this_oracle_does_not_measure_rendered_mesh_or_pixels":true,
        "grid_time_can_differ_from_video_capture_pts":true,
        "strict_perf_60":"NOT_QUALIFIED",
        "strict_stream_18":"NOT_QUALIFIED",
        "strict_view_130":"NOT_QUALIFIED",
        "strict_edit_100":"NOT_QUALIFIED",
        "automatic_acceptance":false
    }
    var f:=FileAccess.open(path.path_join(OUTPUT_NAME),FileAccess.WRITE)
    if f==null:
        _fail("Cannot persist independent 60Hz oracle")
        return
    f.store_string(JSON.stringify(result))
    f.close()
    print("A8_P6_EXPECTED_SDF_READY fixed_frames=",FRAME_COUNT,
          " pixel_rays=",valid_hits+no_hits," hits=",valid_hits,
          " no_hit=",no_hits," strict=NOT_QUALIFIED")
    quit(0)
