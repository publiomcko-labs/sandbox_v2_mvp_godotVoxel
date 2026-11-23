extends Node
# A7 telemetry is enabled for *every* route. Screenshots are separate evidence
# runs and are never mixed into performance data.
const Routes = preload("res://tests/a7_routes.gd")
var route: String = ""
var duration_s := 0.0
var warmup_s := 45.0
var seed_value := 20261119
var ci_smoke := false
var capture := false
# Zero means no in-engine GPU readback; use external desktop recorder.
# The old 1Hz PNG readback induced large stalls on GTX 1050 Ti.
var screenshot_interval_s := 30.0
var vsync_off_requested := false
var voxel_threads_requested := 0

var _world: Node3D
var _terrain: VoxelLodTerrain
var _player: Node3D
var _camera: Camera3D
var _instancer: VoxelInstancer
var _water: Node3D
var _outdir := ""
var _trace: FileAccess
var _begin_us := 0
var _movement_begin_us := -1
var _previous_us := 0
var _next_sample_s := 0.0
var _next_screenshot_s := 0.0
var _ready_at_ms := -1.0
var _intervals: Array[float] = []
var _render_cpu_ms: Array[float] = []
var _render_gpu_ms: Array[float] = []
var _over16 := 0
var _over20 := 0
var _over33 := 0
var _min_probe := 8
var _samples := 0
var _captures := 0
var _camera_initial_fov := 0.0
var _measurement_epoch_begin := -1.0
var _video_sync_marker: ColorRect
var _video_sync_index := -1

func _ready() -> void:
    _world = get_parent()
    _terrain = _world.get_node("Terrain") as VoxelLodTerrain
    _player = _world.get_node("Player") as Node3D
    _camera = _world.get_node("Player/Camera3D") as Camera3D
    _instancer = _world.get_node("Terrain/RockInstancer") as VoxelInstancer
    _water = _world.get_node("Water") as Node3D
    _outdir = OS.get_environment("A7_OUTPUT_DIR")
    if _outdir.is_empty() or DirAccess.make_dir_recursive_absolute(_outdir) != OK:
        push_error("A7_ROUTE_FAIL: isolated A7_OUTPUT_DIR required")
        get_tree().quit(2)
        return
    _trace = FileAccess.open(_outdir.path_join("a7_route.jsonl"), FileAccess.WRITE)
    if _trace == null:
        push_error("A7_ROUTE_FAIL: trace IO")
        get_tree().quit(2)
        return
    _player.set_process(false)
    _player.set_physics_process(false)
    _player.set_process_unhandled_input(false)
    _player.global_position = Routes.position_for(route, 0.0)
    _camera_initial_fov = _camera.fov
    if capture and DisplayServer.get_name() != "headless":
        # Compact solid sync patch remains visible in desktop video. Its
        # transitions anchor *video* PTS to Godot events, not terrain pixels.
        _video_sync_marker = ColorRect.new()
        _video_sync_marker.position = Vector2(1860,22)
        _video_sync_marker.size = Vector2(42,40)
        _video_sync_marker.color = Color(0.15,0.15,0.15,1.0)
        _video_sync_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
        _world.get_node("HUD").add_child(_video_sync_marker)
    if DisplayServer.get_name() != "headless":
        RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
    _begin_us = Time.get_ticks_usec()
    _emit({
        "type":"metadata", "schema":"a7_route_v1",
        "route":route, "seed":seed_value, "warmup_s":warmup_s,
        "duration_s":duration_s, "speed_mps":Routes.SPEED_MPS,
        "render_method":RenderingServer.get_current_rendering_method(),
        "render_driver":RenderingServer.get_current_rendering_driver_name(),
        "viewport_px":str(get_viewport().get_visible_rect().size),
        "fov_degrees":_camera_initial_fov, "headless":DisplayServer.get_name()=="headless",
        "capture":capture, "screenshot_interval_s":screenshot_interval_s,
        "video_sync_marker_crop_xywh":[1888,42,8,8] if capture else null,
        "video_sync_marker_gate":"CLOCK_ALIGNMENT_ONLY",
        "ci_smoke":ci_smoke,
        "vsync_off_requested":vsync_off_requested,
        "vsync_mode_actual":int(DisplayServer.window_get_vsync_mode()) if DisplayServer.get_name()!="headless" else -1,
        "engine_max_fps":Engine.max_fps,
        "voxel_threads_requested":voxel_threads_requested,
        "voxel_threads_observed":VoxelEngine.get_thread_count(),
        "mesh_block_size":_terrain.mesh_block_size,
        "view_distance":_terrain.view_distance,
        "lod_count":_terrain.lod_count,
        "lod_distance":_terrain.lod_distance,
        "gpu_generator_requested":_terrain.use_gpu_generation,
        "method_note":"start-to-start intervals and viewport GPU/CPU render values are not complete presented-frame time"
    })
    print("A7_ROUTE_START route=", route, " seed=", seed_value,
          " warmup_s=", warmup_s, " run_s=", duration_s, " capture=", capture)

func _emit(record: Dictionary) -> void:
    if _trace != null:
        _trace.store_line(JSON.stringify(record))

func _probes() -> int:
    var hits := 0
    for i in range(8):
        var angle := TAU * float(i) / 8.0
        var p := _player.global_position + Vector3(cos(angle)*130.0, 0.0, sin(angle)*130.0)
        var box := AABB(Vector3(p.x-2.0,-8.0,p.z-2.0),Vector3(4.0,16.0,4.0))
        if _terrain.is_area_meshed(box,2) or _terrain.is_area_meshed(box,3):
            hits += 1
    return hits

func _sample(phase: String, t: float) -> void:
    var hits := _probes()
    if phase == "moving":
        _min_probe = mini(_min_probe,hits)
    if hits == 8 and _ready_at_ms < 0.0:
        _ready_at_ms = float(Time.get_ticks_usec() - _begin_us)/1000.0
    var rid := get_viewport().get_viewport_rid()
    var voxel_stats: Dictionary = VoxelEngine.get_stats()
    var pools: Dictionary = voxel_stats.get("thread_pools", {})
    var general_pool: Dictionary = pools.get("general", {})
    _emit({
        "type":"sample", "phase":phase, "t_s":snappedf(t,0.001),
        "player_x":_player.global_position.x, "player_y":_player.global_position.y,
        "player_z":_player.global_position.z, "meshed_radial_probes":hits,
        "mesh_blocks":_terrain.debug_get_mesh_block_count(),
        "data_blocks":_terrain.debug_get_data_block_count(),
        "rocks_instanced":_instancer.debug_get_instance_counts(),
        "rock_instance_blocks":_instancer.debug_get_block_count(),
        "water":_water.call("get_report"),
        "voxel_workers":{"thread_count":VoxelEngine.get_thread_count(),
            "active_threads":int(general_pool.get("active_threads",-1)),
            "queued_tasks":int(general_pool.get("tasks",-1))},
        "process_ms":1000.0*Performance.get_monitor(Performance.TIME_PROCESS),
        "physics_ms":1000.0*Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS),
        "viewport_render_cpu_ms":RenderingServer.viewport_get_measured_render_time_cpu(rid) if not ci_smoke else 0.0,
        "viewport_render_gpu_ms":RenderingServer.viewport_get_measured_render_time_gpu(rid) if not ci_smoke else 0.0,
        "terrain":_terrain.get_statistics()
    })
    _samples += 1

func _set_path(t: float) -> void:
    _player.global_position = Routes.position_for(route,t)
    if Routes.is_stationary(route):
        # 360-degree coverage rotation over eight fixed headings.
        _player.rotation.y = -TAU * fposmod(t,45.0)/45.0
    else:
        var future := Routes.position_for(route,minf(t+0.04,duration_s))
        var motion := future - _player.global_position
        if motion.length_squared()<0.0001:
            motion = _player.global_position - Routes.position_for(route,maxf(0.0,t-0.04))
        if motion.length_squared()>0.0001:
            _player.rotation.y = atan2(-motion.x,-motion.z)

func _capture(t: float) -> void:
    var img: Image = get_viewport().get_texture().get_image()
    if img==null or img.is_empty():
        _emit({"type":"screenshot_failed","t_s":t,"reason":"empty_viewport_image"})
        return
    var name := "a7_%s_ms%08d.png" % [route,int(round(t*1000.0))]
    var captured_epoch_s := Time.get_unix_time_from_system()
    var captured_ticks_us := Time.get_ticks_usec()
    var err := img.save_png(_outdir.path_join(name))
    if err == OK:
        _captures += 1
        _emit({
            "type":"screenshot","t_s":t,"name":name,
            "capture_epoch_s":captured_epoch_s,
            "capture_ticks_us":captured_ticks_us,
            "player_xyz":[_player.global_position.x,_player.global_position.y,_player.global_position.z],
            "camera_yaw_rad":_player.rotation.y,
            "camera_pitch_rad":_camera.rotation.x,
            "view_130_geometric_probe_hits":_probes(),
            "screen_size_px":[img.get_width(),img.get_height()],
            "pixel_depth_verified":false,
            "note":"Viewport readback is sampled and may perturb frame timings. External 60fps desktop video + depth review is required for strict STREAM-18 and VIEW-130."
        })
    else:
        _emit({"type":"screenshot_failed","t_s":t,"error":err})

func _process(_delta: float) -> void:
    if _trace == null:
        return
    var now := Time.get_ticks_usec()
    if _movement_begin_us < 0:
        var age := float(now-_begin_us)/1000000.0
        if age>=_next_sample_s:
            _sample("warmup",age)
            _next_sample_s+=1.0
        if age<warmup_s:
            return
        _movement_begin_us=now
        _measurement_epoch_begin=Time.get_unix_time_from_system()
        _previous_us=now
        _next_sample_s=0.0
        _next_screenshot_s=0.0
        _emit({"type":"warmup_end","age_s":age,
               "measurement_epoch_begin_s":_measurement_epoch_begin,
               "startup_eight_mesh_probes_ms":_ready_at_ms,
               "startup_pixels_verified":false})
        return
    var t := minf(duration_s,float(now-_movement_begin_us)/1000000.0)
    _set_path(t)
    if is_instance_valid(_video_sync_marker):
        # Alternate two high-contrast colors every elapsed second. A separate
        # decoder can verify consecutive transitions and estimate the offset
        # between FFmpeg PTS and Godot epoch, without GPU readback.
        var sync_index := int(floor(t))
        if sync_index != _video_sync_index:
            _video_sync_index = sync_index
            var green := sync_index%2 == 0
            _video_sync_marker.color = Color(0.0,1.0,0.0,1.0) if green else Color(1.0,0.0,1.0,1.0)
            _emit({
                "type":"video_sync","index":sync_index,"route_t_s":t,
                "event_epoch_s":Time.get_unix_time_from_system(),
                "event_ticks_us":Time.get_ticks_usec(),
                "marker_rgb":"00ff00" if green else "ff00ff",
                "alignment_only":true
            })
    var dt_ms := float(now-_previous_us)/1000.0
    _previous_us=now
    if dt_ms>0.0:
        _intervals.append(dt_ms)
        if dt_ms>16.7: _over16+=1
        if dt_ms>20.0: _over20+=1
        if dt_ms>33.0: _over33+=1
        if not ci_smoke and DisplayServer.get_name()!="headless":
            var rid := get_viewport().get_viewport_rid()
            var cpu := RenderingServer.viewport_get_measured_render_time_cpu(rid)
            var gpu := RenderingServer.viewport_get_measured_render_time_gpu(rid)
            if cpu>0.0: _render_cpu_ms.append(cpu)
            if gpu>0.0: _render_gpu_ms.append(gpu)
    if t>=_next_sample_s:
        _sample("moving",t)
        _next_sample_s+=1.0
    if capture and screenshot_interval_s>0.0 and not ci_smoke and t>=_next_screenshot_s:
        # Diagnostic-only, opt-in readback. An external 60fps recorder is the
        # default for continuous evidence because get_image() blocks rendering.
        # Never use sampled PNG intervals as a PERF-60 measurement.
        _capture(t)
        _next_screenshot_s+=screenshot_interval_s
    if t>=duration_s:
        _finish()

func _percentile(values: Array[float], pct: float) -> float:
    if values.is_empty():
        return 0.0
    return values[int(ceil(float(values.size()-1)*pct))]

func _finish() -> void:
    _intervals.sort()
    _render_cpu_ms.sort()
    _render_gpu_ms.sort()
    var summary := {
        "schema":"a7_route_v1","route":route,"seed":seed_value,
        "duration_s":duration_s,"warmup_s":warmup_s,
        "ci_smoke":ci_smoke, "capture":capture,
        "screenshot_interval_s":screenshot_interval_s,
        "vsync_off_requested":vsync_off_requested,
        "vsync_mode_actual":int(DisplayServer.window_get_vsync_mode()) if DisplayServer.get_name()!="headless" else -1,
        "engine_max_fps":Engine.max_fps,
        "voxel_threads_requested":voxel_threads_requested,
        "voxel_threads_actual":VoxelEngine.get_thread_count(),
        "measurement_epoch_begin_s":_measurement_epoch_begin,
        "measurement_epoch_end_s":Time.get_unix_time_from_system(),
        "frame_count":_intervals.size(),
        "frame_start_p50_ms":_percentile(_intervals,0.5),
        "frame_start_p95_ms":_percentile(_intervals,0.95),
        "frame_start_p99_ms":_percentile(_intervals,0.99),
        "frame_start_p999_ms":_percentile(_intervals,0.999),
        "frame_start_max_ms":_intervals.back() if not _intervals.is_empty() else 0.0,
        "frame_intervals_over_16_7_ms":_over16,
        "frame_intervals_over_20_ms":_over20,
        "frame_intervals_over_33_ms":_over33,
        "viewport_render_cpu_p99_ms":_percentile(_render_cpu_ms,0.99),
        "viewport_render_gpu_p99_ms":_percentile(_render_gpu_ms,0.99),
        "gpu_render_samples":_render_gpu_ms.size(),
        "min_radial_probe_hits_8":_min_probe,
        "first_eight_mesh_probes_ms":_ready_at_ms,
        "samples":_samples,
        "screenshots":_captures,
        "frame_start_interval_target_16_7":
            "EXCEEDED" if _over16>0 else "NOT_EXCEEDED",
        "perf_60_full_present_gate":"NOT_QUALIFIED",
        "stream_18_pixel_gate":"NOT_QUALIFIED",
        "view_130_pixel_depth_gate":"NOT_QUALIFIED"
    }
    _emit({"type":"summary","stats":summary})
    _trace.close()
    _trace=null
    var f:=FileAccess.open(_outdir.path_join("a7_route.json"),FileAccess.WRITE)
    if f==null:
        push_error("A7_ROUTE_FAIL: summary save")
        get_tree().quit(2)
        return
    f.store_string(JSON.stringify(summary,"  "))
    f.close()
    print("A7_ROUTE_REPORT_OK route=",route," seed=",seed_value,
          " frames=",summary["frame_count"]," over16.7=",_over16,
          " min_probes=",_min_probe," full_present=NOT_QUALIFIED")
    get_tree().quit(0)
