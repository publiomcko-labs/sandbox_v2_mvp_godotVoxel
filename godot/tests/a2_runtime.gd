extends Node
# A2 graphical or headless benchmark instrumentation. No changes to Voxel Tools
# streaming, meshing, LOD publication, or the normal free-flight scene.
const Routes = preload("res://tests/a2_routes.gd")

var route: String = ""
var duration_sec: float = 0.0
var warmup_sec: float = 45.0
var ci_smoke: bool = false
var capture_screenshots: bool = false

var _terrain: VoxelLodTerrain
var _player: Node3D
var _dir: String = ""
var _jsonl: FileAccess
var _start_usec: int = 0
var _route_start_usec: int = -1
var _last_frame_usec: int = -1
var _next_sample_sec: float = 1.0
var _next_capture_sec: float = 30.0
var _frames_ms: Array[float] = []
var _over_16_7: int = 0
var _over_20: int = 0
var _over_33: int = 0
var _worst_interval_ms: float = 0.0
var _minimum_probes: int = 8
var _final_probes: int = 0
var _warmup_probe_max: int = 0
var _samples_written: int = 0
var _record_prefix: String = ""

func _ready() -> void:
    _terrain = get_parent().get_node_or_null("Terrain") as VoxelLodTerrain
    _player = get_parent().get_node_or_null("Player") as Node3D
    if _terrain == null or _player == null or Routes.duration_for(route) <= 0.0 or duration_sec <= 0.0:
        push_error("A2_CONFIG_FAIL: invalid scene, route or duration")
        get_tree().quit(2)
        return

    # Disable keyboard movement only in this explicitly launched benchmark.
    _player.set_process(false)
    _player.set_process_input(false)
    _player.set_process_unhandled_input(false)
    _player.global_position = Routes.ORIGIN

    _dir = OS.get_environment("A2_OUTPUT_DIR")
    if _dir.is_empty():
        _dir = ProjectSettings.globalize_path("user://a2-reports")
    var rc := DirAccess.make_dir_recursive_absolute(_dir)
    if rc != OK:
        push_error("A2_IO_FAIL: cannot create output directory: " + _dir)
        get_tree().quit(2)
        return
    _record_prefix = "a2_%s_%d_%d" % [route, int(Time.get_unix_time_from_system()), OS.get_process_id()]
    var path := _dir.path_join(_record_prefix + ".jsonl")
    _jsonl = FileAccess.open(path, FileAccess.WRITE)
    if _jsonl == null:
        push_error("A2_IO_FAIL: " + path)
        get_tree().quit(2)
        return

    _start_usec = Time.get_ticks_usec()
    print("A2_BENCH_START route=", route, " warmup_s=", warmup_sec,
          " duration_s=", duration_sec, " headless=", DisplayServer.get_name() == "headless")
    print("A2_JSONL=", path)
    _emit({"type": "metadata", "schema": "a2_v1", "route": route,
           "seed": 20261119, "speed_mps": Routes.SPEED_MPS,
           "target_radius_m": 130, "requested_view_distance": _terrain.view_distance,
           "lod_count": _terrain.lod_count, "mesh_block_size": _terrain.mesh_block_size,
           "renderer": DisplayServer.get_name(),
           "viewport_px": str(get_viewport().get_visible_rect().size),
           "ci_smoke": ci_smoke, "capture_screenshots": capture_screenshots,
           "notes": "Interval metrics exclude startup; not GPU/present duration and not pixel coverage"})

func _emit(record: Dictionary) -> void:
    if _jsonl != null:
        _jsonl.store_line(JSON.stringify(record))

func _mesh_probes() -> int:
    # This only tests whether meshing has processed small samples at 130m.
    # It CANNOT establish that terrain is rendered or free of visible seams.
    var hits := 0
    for i in range(8):
        var angle := float(i) * TAU / 8.0
        var center := _player.global_position + Vector3(cos(angle) * 130.0, 0.0, sin(angle) * 130.0)
        var cell := AABB(Vector3(center.x - 2.0, -8.0, center.z - 2.0), Vector3(4.0, 16.0, 4.0))
        if _terrain.is_area_meshed(cell, 2) or _terrain.is_area_meshed(cell, 3):
            hits += 1
    return hits

func _emit_progress(phase: String, t: float) -> void:
    var st: Dictionary = _terrain.get_statistics()
    var probes := _mesh_probes()
    _final_probes = probes
    if phase == "warmup":
        _warmup_probe_max = maxi(_warmup_probe_max, probes)
    var row := {
        "type": "sample", "phase": phase, "time_sec": snappedf(t, 0.001),
        "player_x": _player.global_position.x, "player_y": _player.global_position.y,
        "player_z": _player.global_position.z,
        "meshed_probe_hits_8": probes,
        "mesh_blocks": _terrain.debug_get_mesh_block_count(),
        "data_blocks": _terrain.debug_get_data_block_count(),
        "engine_fps": Engine.get_frames_per_second(),
        "process_cpu_ms": Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
        "physics_cpu_ms": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
        "terrain_stats": st
    }
    _emit(row)
    _samples_written += 1

func _process(_delta: float) -> void:
    if _jsonl == null:
        return
    var now := Time.get_ticks_usec()
    if _route_start_usec < 0:
        var age := float(now - _start_usec) / 1000000.0
        if age >= _next_sample_sec:
            _emit_progress("warmup", age)
            _next_sample_sec += 1.0
        if age < warmup_sec:
            return
        # Explicit warmup never changes route time or speed; report any
        # incomplete startup separately rather than calling it qualified.
        _route_start_usec = now
        _last_frame_usec = now
        _next_sample_sec = 1.0
        _emit({"type": "warmup_end", "elapsed_sec": age,
               "max_meshed_probe_hits_8": _warmup_probe_max,
               "startup_coverage_pixel_verified": false})
        print("A2_ROUTE_BEGIN requested_speed_mps=", Routes.SPEED_MPS)
        return

    var elapsed := minf(duration_sec, float(now - _route_start_usec) / 1000000.0)
    _player.global_position = Routes.position_for(route, elapsed)
    # Keep the camera facing its instantaneous movement direction for evidence.
    var near_future := Routes.position_for(route, minf(elapsed + 0.04, duration_sec))
    var direction := near_future - _player.global_position
    if direction.length_squared() < 0.0001:
        direction = _player.global_position - Routes.position_for(route, maxf(0.0, elapsed - 0.04))
    if direction.length_squared() > 0.0001:
        _player.rotation.y = atan2(-direction.x, -direction.z)

    var interval_ms := float(now - _last_frame_usec) / 1000.0
    _last_frame_usec = now
    if interval_ms > 0.0:
        _frames_ms.append(interval_ms)
        _worst_interval_ms = maxf(_worst_interval_ms, interval_ms)
        if interval_ms > 16.7:
            _over_16_7 += 1
        if interval_ms > 20.0:
            _over_20 += 1
        if interval_ms > 33.0:
            _over_33 += 1

    if elapsed >= _next_sample_sec:
        _emit_progress("moving", elapsed)
        _next_sample_sec += 1.0
    if capture_screenshots and not ci_smoke and DisplayServer.get_name() != "headless" and elapsed >= _next_capture_sec:
        var image := get_viewport().get_texture().get_image()
        if image != null and not image.is_empty():
            var png := _dir.path_join("%s_frame_%04d.png" % [_record_prefix, int(elapsed)])
            var rc := image.save_png(png)
            _emit({"type": "screenshot", "time_sec": elapsed, "path": png, "save_error": rc,
                   "note": "Screenshot collection adds workload and is not a qualifying performance run"})
        _next_capture_sec += 30.0
    if elapsed >= duration_sec:
        _finish()

func _percentile(sorted: Array[float], q: float) -> float:
    if sorted.is_empty():
        return 0.0
    return sorted[int(ceil(float(sorted.size() - 1) * q))]

func _finish() -> void:
    _frames_ms.sort()
    var frames := _frames_ms.size()
    var summary := {
        "schema": "a2_v1", "type": "summary", "route": route,
        "seed": 20261119, "speed_mps": Routes.SPEED_MPS,
        "duration_sec": duration_sec, "warmup_sec": warmup_sec,
        "frame_intervals_observed": frames,
        "frame_interval_ms_p50": _percentile(_frames_ms, 0.50),
        "frame_interval_ms_p95": _percentile(_frames_ms, 0.95),
        "frame_interval_ms_p99": _percentile(_frames_ms, 0.99),
        "frame_interval_ms_p999": _percentile(_frames_ms, 0.999),
        "frame_interval_ms_max": _worst_interval_ms,
        "frames_interval_over_16_7_ms": _over_16_7,
        "frames_interval_over_20_ms": _over_20,
        "frames_interval_over_33_ms": _over_33,
        "meshed_probe_hits_8_final": _final_probes,
        "meshed_probe_hits_8_max_warmup": _warmup_probe_max,
        "stats_samples": _samples_written,
        "screenshots_enabled": capture_screenshots,
        "ci_smoke": ci_smoke,
        "perf_60_gate": "NOT_QUALIFIED",
        "view_130_pixel_gate": "NOT_QUALIFIED",
        "stream_18_visual_gate": "NOT_QUALIFIED",
        "notes": "Measured frame START intervals, not full CPU+GPU+present; meshed probes are NOT rendered pixels"
    }
    _emit(summary)
    _jsonl.close()
    _jsonl = null
    var summary_path := _dir.path_join(_record_prefix + ".json")
    var summary_file := FileAccess.open(summary_path, FileAccess.WRITE)
    if summary_file == null:
        push_error("A2_IO_FAIL: cannot write summary")
        get_tree().quit(2)
        return
    summary_file.store_string(JSON.stringify(summary, "  "))
    summary_file.close()
    print("A2_SUMMARY=", summary_path)
    if ci_smoke:
        print("A2_HEADLESS_TRACE_PASS samples=", _samples_written, " frames=", frames)
    else:
        print("A2_GRAPHICAL_TRACE_RECORDED: visual and GPU/present qualification pending")
    get_tree().quit(0)
