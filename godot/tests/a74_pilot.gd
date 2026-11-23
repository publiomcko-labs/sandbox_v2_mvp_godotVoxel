extends SceneTree
# A7.4 EXPERIMENTAL PILOT ONLY. This is not an A5 gameplay or PERF-60 change.
# Independent-of-mesher prediction uses PRE-edit SDF samples plus analytic CSG.
# Desktop video and post-edit rendered pixels are NEVER used to build the oracle.

const RADIUS_M := 1.5
const SIDE := 11
const PIXEL_STEP := 14

func _initialize() -> void:
    call_deferred("_run")

func _arg(name: String, fallback: String) -> String:
    for a in OS.get_cmdline_user_args():
        if a.begins_with("--" + name + "="):
            return a.substr(name.length() + 3)
    return fallback

func _fail(message: String) -> void:
    push_error("A74_PILOT_FAIL " + message)
    quit(2)

func _xyz(v: Vector3) -> Array:
    return [v.x, v.y, v.z]

func _write_json(path: String, payload: Dictionary) -> bool:
    var f := FileAccess.open(path, FileAccess.WRITE)
    if f == null:
        return false
    f.store_string(JSON.stringify(payload, "  "))
    f.close()
    return true

func _mark(marker: ColorRect, events: FileAccess, index: int, rgb: String) -> void:
    marker.color = Color(0.0, 1.0, 0.0, 1.0) if rgb == "00ff00" else Color(1.0, 0.0, 1.0, 1.0)
    events.store_line(JSON.stringify({
        "type": "sync", "index": index, "marker_rgb": rgb,
        "event_epoch_s": Time.get_unix_time_from_system(),
        "clock": "Godot UTC system epoch; marker assignment, NOT presented pixel"
    }))

func _run() -> void:
    var scenario := _arg("scenario", "static_remove")
    var warmup := float(_arg("warmup", "45"))
    var seed := int(_arg("seed", "20261119"))
    if not ["static_remove", "static_add", "boundary_remove", "boundary_add"].has(scenario):
        _fail("unknown scenario")
        return
    if warmup < 5.0 or warmup > 180.0:
        _fail("warmup outside [5,180]")
        return
    if DisplayServer.get_name() == "headless":
        _fail("GPU desktop is mandatory; headless is not visual evidence")
        return
    if RenderingServer.get_current_rendering_method() != "gl_compatibility":
        _fail("A5 GL Compatibility renderer required")
        return
    var folder := OS.get_environment("A74_OUTPUT_DIR")
    if folder.is_empty() or DirAccess.make_dir_recursive_absolute(folder) != OK:
        _fail("A74_OUTPUT_DIR must be isolated")
        return
    DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
    DisplayServer.window_set_position(Vector2i.ZERO)
    DisplayServer.window_set_size(Vector2i(1920, 1080))
    root.size = Vector2i(1920, 1080)
    var world: Node3D = load("res://scenes/main.tscn").instantiate()
    var terrain: VoxelLodTerrain = world.get_node("Terrain") as VoxelLodTerrain
    if terrain == null or terrain.mesh_block_size != 16 or terrain.use_gpu_generation:
        _fail("A5 CPU16 invariants changed")
        return
    terrain.set("world_seed", seed)
    root.add_child(world)
    await process_frame
    var player: Node3D = world.get_node("Player")
    var camera: Camera3D = world.get_node("Player/Camera3D")
    player.set_process(false)
    player.set_physics_process(false)
    player.set_process_unhandled_input(false)
    var tool: VoxelTool = terrain.get_voxel_tool()
    if tool == null or not bool(world.call("is_voxel_ready")):
        _fail("native voxel brush missing")
        return
    var x := 15.5 if scenario.begins_with("boundary") else 10.0
    var z := 15.0
    player.global_position = Vector3(x, 22.0, z + 12.0)
    var begin := Time.get_ticks_msec()
    var center := Vector3(INF, INF, INF)
    while Time.get_ticks_msec() - begin < int(warmup * 1000.0):
        await process_frame
        var above := Vector3(x, 55.0, z)
        var hit: VoxelRaycastResult = tool.raycast(above, Vector3.DOWN, 100.0)
        if hit != null:
            var candidate := above + Vector3.DOWN * (hit.distance + 0.6)
            if bool(world.call("can_edit_sphere", candidate, RADIUS_M)):
                center = candidate
    if not center.is_finite():
        _fail("surface/LOD0 not ready after warmup")
        return
    player.global_position = center + Vector3(0.0, 5.0, 12.0)
    camera.look_at(center, Vector3.UP)
    await process_frame
    await process_frame
    if camera.is_position_behind(center):
        _fail("camera is not facing brush")
        return

    # The baseline is measured BEFORE the edit and frozen to disk.
    # z-major, then y, then x; Python's trilinear oracle consumes the same order.
    var origin := Vector3i(floori(center.x) - 5, floori(center.y) - 5, floori(center.z) - 5)
    var lattice: Array = []
    for iz in range(SIDE):
        for iy in range(SIDE):
            for ix in range(SIDE):
                var pos := origin + Vector3i(ix, iy, iz)
                var sdf := tool.get_voxel_f(pos)
                if not is_finite(sdf):
                    _fail("nonfinite pre-edit SDF sample")
                    return
                lattice.append(sdf)
    var rays: Array = []
    for gy in range(-5, 6):
        for gx in range(-5, 6):
            var px := Vector2(960 + gx * PIXEL_STEP, 540 + gy * PIXEL_STEP)
            rays.append({
                "pixel": [int(px.x), int(px.y)],
                "origin": _xyz(camera.project_ray_origin(px)),
                "direction": _xyz(camera.project_ray_normal(px).normalized())
            })
    var ref := {
        "schema": "a74_preedit_reference_v1",
        "scenario": scenario, "seed": seed, "screen_size": [1920, 1080],
        "camera_fixed": true, "pixel_step": PIXEL_STEP,
        "brush": {"center": _xyz(center), "radius_m": RADIUS_M,
                  "operation": "add" if scenario.ends_with("add") else "remove"},
        "baseline": {"origin": [origin.x, origin.y, origin.z],
                     "side": SIDE, "values": lattice,
                     "source": "PRE_EDIT_VOXELTOOL_SDF_LATTICE"},
        "rays": rays, "marker_crop_xywh": [1888, 42, 8, 8],
        "oracle": "independent analytic sphere CSG + trilinear pre-edit SDF",
        "limits": "Terrain baseline sampled from Godot SDF, not independent base-generator verification. Pixel color is not depth ground truth."
    }
    if not _write_json(folder.path_join("a74_reference.json"), ref):
        _fail("reference write failed")
        return
    var events := FileAccess.open(folder.path_join("a74_events.jsonl"), FileAccess.WRITE)
    if events == null:
        _fail("events write failed")
        return
    events.store_line(JSON.stringify({
        "type": "metadata", "schema": "a74_pilot_events_v1",
        "scenario": scenario, "camera_fixed": true,
        "input_kind": "SCRIPTED_BRUSH_NOT_HID",
        "strict_edit_100_gate": "NOT_QUALIFIED"
    }))
    var marker := ColorRect.new()
    marker.position = Vector2(1860, 22)
    marker.size = Vector2(42, 40)
    marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
    marker.color = Color(0.15, 0.15, 0.15, 1.0)
    world.get_node("HUD").add_child(marker)
    await create_timer(1.0).timeout
    for i in range(4):
        _mark(marker, events, i, "00ff00" if i % 2 == 0 else "ff00ff")
        await create_timer(0.7).timeout
    # Only one edit in each campaign; the analytic oracle is frozen already.
    var add := scenario.ends_with("add")
    var start_us := Time.get_ticks_usec()
    var brush_epoch := Time.get_unix_time_from_system()
    var accepted: bool = bool(world.call("edit_sphere", center, add, RADIUS_M))
    var return_epoch := Time.get_unix_time_from_system()
    var native_apply_ms := float(Time.get_ticks_usec() - start_us) / 1000.0
    if not accepted:
        events.close()
        _fail("pilot brush rejected")
        return
    _mark(marker, events, 4, "00ff00")
    events.store_line(JSON.stringify({
        "type": "edit", "index": 0, "accepted": true, "add": add,
        "brush_call_epoch_s": brush_epoch, "brush_return_epoch_s": return_epoch,
        "native_apply_ms": native_apply_ms,
        "first_correct_presented_pixel_ms": null,
        "edit_100_gate": "NOT_QUALIFIED"
    }))
    await create_timer(0.7).timeout
    for i in range(5, 8):
        _mark(marker, events, i, "ff00ff" if i % 2 == 1 else "00ff00")
        await create_timer(0.7).timeout
    await create_timer(0.5).timeout
    events.close()
    var summary := {
        "schema": "a74_pilot_result_v1", "scenario": scenario,
        "accepted_count": 1, "native_apply_ms": native_apply_ms,
        "camera_fixed": true, "pre_edit_reference_saved": true,
        "first_correct_presented_pixel_ms": null,
        "edit_100_gate": "NOT_QUALIFIED",
        "note": "Reference fixture only, video/depth/ETW qualification required."
    }
    if not _write_json(folder.path_join("a74_result.json"), summary):
        _fail("summary write failed")
        return
    print("A74_PILOT_OK scenario=", scenario, " accepted=1 strict=NOT_QUALIFIED")
    world.queue_free()
    quit(0)
