extends SceneTree
# A5 independent write/reopen processes. SDF and ocean mesh identity are
# observable headlessly; shoreline pixels and EDIT-100 remain NOT QUALIFIED.
const CENTER := Vector3(8, -2, 15)
const PROBE := Vector3i(8, -2, 15)
const RADIUS := 4.0

func _initialize() -> void:
    call_deferred("_verify")

func _fail(message: String) -> void:
    push_error("A5_SHORE_FAIL: " + message)
    quit(1)

func _phase() -> String:
    for arg in OS.get_cmdline_user_args():
        if arg == "--phase=write":
            return "write"
        if arg == "--phase=reopen":
            return "reopen"
    return ""

func _report(phase: String, sdf: float, instance_id: int) -> void:
    var output := OS.get_environment("A5_RESULTS_DIR")
    if output.is_empty():
        return
    var file := FileAccess.open(output.path_join("a5_shore_%s.json" % phase), FileAccess.WRITE)
    if file == null:
        push_error("A5_REPORT_FAIL: " + phase)
        return
    file.store_string(JSON.stringify({
        "phase": phase, "probe_sdf": sdf, "surface_y": 0.0,
        "plane_mesh_id": instance_id, "plane_mesh_count": 1,
        "visual_shoreline_gate": "NOT_QUALIFIED",
        "edit_first_presented_gate": "NOT_QUALIFIED"
    }, "  "))
    file.close()

func _verify() -> void:
    var phase := _phase()
    if phase.is_empty() or OS.get_environment("A3_SAVE_PATH").is_empty():
        _fail("phase and isolated A3_SAVE_PATH required")
        return
    var packed: PackedScene = load("res://scenes/main.tscn")
    if packed == null:
        _fail("scene unavailable")
        return
    var world := packed.instantiate()
    root.add_child(world)
    await process_frame
    var terrain := world.get_node_or_null("Terrain") as VoxelLodTerrain
    var player := world.get_node_or_null("Player") as CharacterBody3D
    var water := world.get_node_or_null("Water") as Node3D
    if terrain == null or player == null or water == null or not world.is_voxel_ready():
        _fail("terrain, swimmer, water or C++ edit missing")
        return
    var plane := water.get_node_or_null("OceanMesh") as MeshInstance3D
    if plane == null or not (plane.mesh is PlaneMesh):
        _fail("ocean must use one fixed PlaneMesh")
        return
    var mesh_id := plane.mesh.get_instance_id()
    player.global_position = Vector3(8, 7, 15)
    await process_frame
    if plane.global_position.distance_to(Vector3(8, 0, 15)) > 0.001:
        _fail("water plane not tracking camera at constant y0")
        return
    if absf(float(water.call("surface_height_at", CENTER))) > 0.00001:
        _fail("render and physics water level disagree")
        return

    var limit := Time.get_ticks_msec() + 60000
    while not world.can_edit_sphere(CENTER, RADIUS):
        if Time.get_ticks_msec() > limit:
            _fail("LOD0 shoreline area not editable")
            return
        await process_frame
    var tool: VoxelTool = terrain.get_voxel_tool()
    if tool == null:
        _fail("VoxelTool missing")
        return
    var before := tool.get_voxel_f(PROBE)
    if phase == "write":
        if before >= -0.2:
            _fail("baseline shore sample must be solid " + str(before))
            return
        if not world.edit_sphere(CENTER, false, RADIUS):
            _fail("shoreline subtraction rejected")
            return
        await process_frame
        var after := tool.get_voxel_f(PROBE)
        if after <= 0.2:
            _fail("shoreline SDF not removed: " + str(after))
            return
        if plane.mesh.get_instance_id() != mesh_id or plane.global_position.y != 0.0:
            _fail("water mesh replaced or shifted vertically after editing")
            return
        var tracker: VoxelSaveCompletionTracker = terrain.save_modified_blocks()
        if tracker == null:
            _fail("SQLite save tracker missing")
            return
        var deadline := Time.get_ticks_msec() + 60000
        while not tracker.is_complete() and not tracker.is_aborted():
            if Time.get_ticks_msec() > deadline:
                _fail("save timed out")
                return
            await process_frame
        if tracker.is_aborted():
            _fail("save aborted")
            return
        terrain.stream.flush()
        if not FileAccess.file_exists(OS.get_environment("A3_SAVE_PATH")):
            _fail("SQLite absent after save")
            return
        _report("write", after, mesh_id)
        print("A5_SHORE_EDIT_PASS before=", before, " after=", after,
              " mesh_reused=true water_y=0")
    else:
        if before <= 0.2:
            _fail("reopened shoreline SDF not persisted: " + str(before))
            return
        if plane.mesh.get_instance_id() != mesh_id or plane.global_position.y != 0.0:
            _fail("reopened ocean geometry wrong")
            return
        _report("reopen", before, mesh_id)
        print("A5_SHORE_REOPEN_PASS sdf=", before, " water_y=0")
    world.queue_free()
    quit(0)
