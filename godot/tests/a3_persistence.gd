extends SceneTree
# Two separate Godot processes share only the SQLite file A3_SAVE_PATH.
const REMOVE_CENTER := Vector3(8, -4, 15)
const ADD_CENTER := Vector3(15, 26, 15)
const REMOVE_PROBE := Vector3i(8, -4, 15)
const ADD_PROBE := Vector3i(16, 26, 15) # Crosses X=16 block boundary.
const BRUSH_RADIUS := 4.0

func _initialize() -> void:
    call_deferred("_test")

func _phase() -> String:
    for arg in OS.get_cmdline_user_args():
        if arg == "--phase=write":
            return "write"
        if arg == "--phase=reopen":
            return "reopen"
    return ""

func _fail(reason: String) -> void:
    push_error("A3_PERSISTENCE_FAIL: " + reason)
    quit(1)

func _record(phase: String, removed: float, added: float, edit_cpu_ms: float) -> void:
    var dir := OS.get_environment("A3_RESULTS_DIR")
    if dir.is_empty():
        return
    var file := FileAccess.open(dir.path_join("a3_%s.json" % phase), FileAccess.WRITE)
    if file == null:
        push_error("A3_REPORT_FAIL: " + phase)
        return
    file.store_string(JSON.stringify({
        "phase": phase, "removed_center_sdf": removed, "added_boundary_sdf": added,
        "native_apply_ms": edit_cpu_ms, "visual_first_presented_ms": null,
        "visual_gate": "NOT_QUALIFIED", "collision_gate": "NOT_QUALIFIED",
        "save_path": OS.get_environment("A3_SAVE_PATH")
    }, "  "))
    file.close()

func _test() -> void:
    var phase := _phase()
    if phase.is_empty():
        _fail("missing phase")
        return
    var path := OS.get_environment("A3_SAVE_PATH")
    if path.is_empty():
        _fail("isolated A3_SAVE_PATH is mandatory")
        return
    var packed: PackedScene = load("res://scenes/main.tscn")
    if packed == null:
        _fail("main scene missing")
        return
    var world := packed.instantiate()
    root.add_child(world)
    await process_frame
    var terrain := world.get_node("Terrain") as VoxelLodTerrain
    var player := world.get_node("Player") as Node3D
    if terrain == null or player == null or not world.is_voxel_ready():
        _fail("scene/native edit API unavailable")
        return
    player.global_position = Vector3(10, 12, 15)
    var deadline := Time.get_ticks_msec() + 60000
    while not (world.can_edit_sphere(REMOVE_CENTER, BRUSH_RADIUS) and
               world.can_edit_sphere(ADD_CENTER, BRUSH_RADIUS)):
        if Time.get_ticks_msec() > deadline:
            _fail("LOD0 did not become editable within 60s")
            return
        await process_frame
    var tool: VoxelTool = terrain.get_voxel_tool()
    if tool == null:
        _fail("VoxelTool missing")
        return
    if phase == "write":
        if world.can_edit_sphere(Vector3(30000, 10000, 30000), 1.5):
            _fail("unloaded area incorrectly editable")
            return
        if world.edit_sphere(REMOVE_CENTER, false, -1.0):
            _fail("invalid radius accepted")
            return
        var solid_before := tool.get_voxel_f(REMOVE_PROBE)
        var air_before := tool.get_voxel_f(ADD_PROBE)
        if solid_before >= -0.2 or air_before <= 0.2:
            _fail("bad baseline: solid=%f air=%f" % [solid_before, air_before])
            return
        if not world.edit_sphere(REMOVE_CENTER, false, BRUSH_RADIUS):
            _fail("native subtract rejected")
            return
        if not world.edit_sphere(ADD_CENTER, true, BRUSH_RADIUS):
            _fail("native add rejected")
            return
        if world.get_successful_edits() != 2:
            _fail("unexpected accepted edit count")
            return
        await process_frame
        var removed := tool.get_voxel_f(REMOVE_PROBE)
        var added := tool.get_voxel_f(ADD_PROBE)
        if removed <= 0.2 or added >= -0.2:
            _fail("wrong post-edit SDF signs: remove=%f add=%f" % [removed, added])
            return
        var tracker: VoxelSaveCompletionTracker = terrain.save_modified_blocks()
        if tracker == null:
            _fail("save tracker unavailable")
            return
        var save_deadline := Time.get_ticks_msec() + 60000
        while not tracker.is_complete() and not tracker.is_aborted():
            if Time.get_ticks_msec() > save_deadline:
                _fail("save exceeded 60s")
                return
            await process_frame
        if tracker.is_aborted():
            _fail("save aborted")
            return
        terrain.stream.flush()
        if not FileAccess.file_exists(path):
            _fail("SQLite file missing after save")
            return
        _record("write", removed, added, world.get_last_edit_apply_ms())
        print("A3_WRITE_PASS removed=", removed, " added=", added,
              " apply_ms=", world.get_last_edit_apply_ms(), " sqlite=", path)
    else:
        var removed := tool.get_voxel_f(REMOVE_PROBE)
        var added := tool.get_voxel_f(ADD_PROBE)
        if removed <= 0.2 or added >= -0.2:
            _fail("reopen lost edits: remove=%f add=%f" % [removed, added])
            return
        _record("reopen", removed, added, 0.0)
        print("A3_REOPEN_PASS removed=", removed, " added=", added, " sqlite=", path)
    world.queue_free()
    quit(0)
