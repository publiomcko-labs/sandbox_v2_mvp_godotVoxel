extends Node
# Same 12s warmup, 18m/s B9 survey (east then north), and six scripted edits.
# Measurements are monotonic frame-start intervals, not monitor presentation.
const SPEED_MPS := 18.0
const DURATION_S := 46.0
const WARMUP_S := 12.0
const EDIT_TIMES := [25.0, 28.0, 31.0, 34.0, 37.0, 40.0]
const RADIUS_M := 1.5
var _player: Node3D
var _camera: Camera3D
var _terrain: VoxelLodTerrain
var _world: Node3D
var _origin: Vector3
var _start_usec := 0
var _last_usec := 0
var _samples: Array[Vector2] = []
var _next_edit := 0
var _accepted := 0
var _rejected := 0
var _max_apply_ms := 0.0
var _probe_samples: Array[int] = []
var _next_probe_s := 12.0
var _save_tracker: VoxelSaveCompletionTracker
var _save_start_usec := -1
var _save_status := "not_started"
var _done := false
# V3.0 opt-in: bounded in-memory trace, flushed only after measurement.
const TRACE_CAP := 20000
const TRACE_WIDTH := 10
var _trace_enabled := false
var _trace_rows := PackedInt64Array()
var _trace_count := 0
var _trace_overflow := 0
var _trace_context: Array = []
var _utc_anchor_usec := 0
var _mono_anchor_usec := 0
var _anchor_span_usec := 0

func _ready() -> void:
    _world = get_parent() as Node3D
    _player = _world.get_node_or_null("Player") as Node3D
    _terrain = _world.get_node_or_null("Terrain") as VoxelLodTerrain
    if _player == null or _terrain == null or not _world.has_method("edit_sphere"):
        push_error("COMPARISON_V1_INVALID_SCENE")
        get_tree().quit(2)
        return
    _camera = _player.get_node_or_null("Camera3D") as Camera3D
    if _camera == null or OS.get_environment("COMPARISON_V1_CSV").is_empty() or OS.get_environment("COMPARISON_V1_NATIVE_JSON").is_empty():
        push_error("COMPARISON_V1_INVALID_OUTPUT")
        get_tree().quit(2)
        return
    _player.set_process(false)
    _player.set_process_input(false)
    _player.set_process_unhandled_input(false)
    _origin = _player.global_position
    _trace_enabled = not OS.get_environment("V3_0_TRACE").is_empty()
    if _trace_enabled:
        _trace_rows.resize(TRACE_CAP * TRACE_WIDTH)
        var before := Time.get_ticks_usec()
        _utc_anchor_usec = int(Time.get_unix_time_from_system() * 1000000.0)
        var after := Time.get_ticks_usec()
        _mono_anchor_usec = before + (after - before) / 2
        _anchor_span_usec = after - before
    _start_usec = Time.get_ticks_usec()
    _last_usec = _start_usec
    print("COMPARISON_V1_START duration_s=46 warmup_s=12 speed_mps=18 edits=6")

func _position_at(t: float) -> Vector3:
    if t < 12.0:
        return _origin
    if t < 30.0:
        return _origin + Vector3((t - 12.0) * SPEED_MPS, 0.0, 0.0)
    return _origin + Vector3(324.0, 0.0, -(minf(t, 46.0) - 30.0) * SPEED_MPS)

func _edit() -> void:
    var add := _next_edit % 2 == 1
    var accepted := false
    var tool: VoxelTool = _terrain.get_voxel_tool()
    if tool != null:
        var origin := Vector3(_player.global_position.x, 70.0, _player.global_position.z)
        var hit: VoxelRaycastResult = tool.raycast(origin, Vector3.DOWN, 150.0)
        if hit != null:
            var contact := origin + Vector3.DOWN * hit.distance
            var depth := -0.55 * RADIUS_M if add else 0.55 * RADIUS_M
            accepted = bool(_world.call("edit_sphere", contact + Vector3.DOWN * depth, add, RADIUS_M))
    if accepted:
        _accepted += 1
        _max_apply_ms = maxf(_max_apply_ms, float(_world.call("get_last_edit_apply_ms")))
    else:
        _rejected += 1
    print("COMPARISON_V1_EDIT index=", _next_edit, " accepted=", accepted)
    _next_edit += 1

func _probe() -> void:
    var hits := 0
    for i in range(8):
        var angle := float(i) * TAU / 8.0
        var p := _player.global_position + Vector3(cos(angle) * 130.0, 0, sin(angle) * 130.0)
        var bounds := AABB(Vector3(p.x-2.0, -8, p.z-2.0), Vector3(4,16,4))
        if _terrain.is_area_meshed(bounds, 2) or _terrain.is_area_meshed(bounds, 3):
            hits += 1
    _probe_samples.append(hits)

func _process(_delta: float) -> void:
    if _done or _start_usec <= 0:
        return
    var now := Time.get_ticks_usec()
    var t := float(now - _start_usec) / 1000000.0
    _player.global_position = _position_at(t)
    if t >= 12.0:
        var forward := Vector3.RIGHT if t < 30.0 else Vector3.FORWARD
        _camera.look_at(_camera.global_position + forward * 20.0 + Vector3(0, -9, 0), Vector3.UP)
    var movement_end := Time.get_ticks_usec() if _trace_enabled else now
    if t < WARMUP_S:
        _last_usec = now
        return
    if t <= DURATION_S and _last_usec > 0:
        _samples.append(Vector2(t, float(now - _last_usec) / 1000.0))
    var previous := _last_usec
    _last_usec = now
    var edit_before := _next_edit
    while _next_edit < EDIT_TIMES.size() and t >= float(EDIT_TIMES[_next_edit]):
        _edit()
    var edit_end := Time.get_ticks_usec() if _trace_enabled else now
    var did_probe := t >= _next_probe_s and t <= DURATION_S
    if did_probe:
        _probe()
        _next_probe_s += 1.0
    if _trace_enabled and t <= DURATION_S:
        var probe_end := Time.get_ticks_usec()
        # Reuse A7's existing VoxelEngine and terrain statistics once per probe.
        if did_probe:
            _trace_context.append({
                "mono_usec": probe_end,
                "voxel": VoxelEngine.get_stats(),
                "terrain": _terrain.get_statistics(),
                "mesh_blocks": _terrain.debug_get_mesh_block_count(),
                "static_memory_bytes": Performance.get_monitor(Performance.MEMORY_STATIC),
                "physics_active_objects": Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS)
            })
        var context_end := Time.get_ticks_usec()
        if _trace_count < TRACE_CAP:
            var k := _trace_count * TRACE_WIDTH
            _trace_rows[k] = previous
            _trace_rows[k + 1] = now
            _trace_rows[k + 2] = movement_end
            _trace_rows[k + 3] = edit_end
            _trace_rows[k + 4] = probe_end
            _trace_rows[k + 5] = context_end
            _trace_rows[k + 6] = _next_edit - edit_before
            _trace_rows[k + 7] = int(did_probe)
            _trace_rows[k + 8] = int(Performance.get_monitor(Performance.TIME_PROCESS) * 1000000.0)
            _trace_rows[k + 9] = int(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000000.0)
            _trace_count += 1
        else:
            _trace_overflow += 1
    if t < DURATION_S:
        return
    if _save_start_usec < 0:
        _save_start_usec = now
        _save_tracker = _terrain.save_modified_blocks()
        _save_status = "pending" if _save_tracker != null else "tracker_unavailable"
    if _save_tracker != null:
        if _save_tracker.is_complete():
            _save_status = "completed"
        elif _save_tracker.is_aborted():
            _save_status = "aborted"
        elif now - _save_start_usec < 30000000:
            return
        else:
            _save_status = "timeout"
    _finish()

func _finish() -> void:
    _done = true
    if _trace_enabled and not _write_v3_trace():
        push_error("V3_0_TRACE_WRITE_FAILED")
        get_tree().quit(5)
        return
    var csv_file := FileAccess.open(OS.get_environment("COMPARISON_V1_CSV"), FileAccess.WRITE)
    if csv_file == null:
        get_tree().quit(3)
        return
    csv_file.store_line("t_s,interval_ms")
    for item in _samples:
        csv_file.store_line("%.6f,%.6f" % [item.x, item.y])
    csv_file.close()
    var native := {
        "edits_requested": _next_edit,
        "edits_accepted": _accepted,
        "edits_rejected": _rejected,
        "edit_apply_sync_max_ms": _max_apply_ms,
        "first_correct_presented_pixel_ms": null,
        "meshed_probe_samples": _probe_samples.size(),
        "meshed_probe_hits_min_8": _probe_samples.min() if not _probe_samples.is_empty() else null,
        "save_status": _save_status,
        "note": "Native synchronous brush duration and data meshing probes do not prove presented pixels"
    }
    var out := FileAccess.open(OS.get_environment("COMPARISON_V1_NATIVE_JSON"), FileAccess.WRITE)
    if out == null:
        get_tree().quit(3)
        return
    out.store_string(JSON.stringify(native, "  "))
    out.close()
    print("COMPARISON_V1_DONE frames=", _samples.size(), " edits_accepted=", _accepted)
    get_tree().quit(0 if _samples.size() >= 100 and _next_edit == 6 else 4)

func _write_v3_trace() -> bool:
    var path := OS.get_environment("V3_0_TRACE")
    var out := FileAccess.open(path, FileAccess.WRITE)
    if out == null:
        return false
    out.store_line("previous_usec,now_usec,movement_end_usec,edit_end_usec,probe_end_usec,context_end_usec,edits,probe,process_monitor_usec,physics_monitor_usec")
    for i in range(_trace_count):
        var row := PackedStringArray()
        for j in range(TRACE_WIDTH):
            row.append(str(_trace_rows[i * TRACE_WIDTH + j]))
        out.store_line(",".join(row))
    out.close()
    var before := Time.get_ticks_usec()
    var utc_end := int(Time.get_unix_time_from_system() * 1000000.0)
    var after := Time.get_ticks_usec()
    var meta := FileAccess.open(path + ".json", FileAccess.WRITE)
    if meta == null:
        return false
    meta.store_string(JSON.stringify({
        "schema": "v3_0_survey_trace_v1",
        "start_usec": _start_usec,
        "anchor_utc_usec": _utc_anchor_usec,
        "anchor_mono_usec": _mono_anchor_usec,
        "anchor_span_usec": _anchor_span_usec,
        "end_anchor_utc_usec": utc_end,
        "end_anchor_mono_usec": before + (after - before) / 2,
        "end_anchor_span_usec": after - before,
        "rows": _trace_count,
        "overflow": _trace_overflow,
        "context": _trace_context,
        "note": "Callback boundaries only; monitors and worker counters are contextual, not per-job attribution."
    }, "  "))
    meta.close()
    return _trace_overflow == 0
