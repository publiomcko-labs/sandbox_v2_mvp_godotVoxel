extends SceneTree
# Two separate processes: native VoxelInstancer static removal to rigid body,
# save via terrain SQLite + sidecar; reopen validates identity/state/instances.
const TEST_AREA := Vector3(0, 7, 0)
const REMOVE_RADIUS := 28.0
const MAX_WAIT_MS := 60000

func _initialize() -> void:
    call_deferred("_verify")

func _fail(msg: String) -> void:
    push_error("A4_SMOKE_FAIL " + msg)
    quit(1)

func _phase() -> String:
    for arg in OS.get_cmdline_user_args():
        if arg == "--phase=write":
            return "write"
        if arg == "--phase=reopen":
            return "reopen"
    return ""

func _report(phase: String, values: Dictionary) -> void:
    var target := OS.get_environment("A4_RESULTS_DIR")
    if target.is_empty():
        return
    var f := FileAccess.open(target.path_join("a4_%s.json" % phase), FileAccess.WRITE)
    if f == null:
        push_error("A4_REPORT_WRITE_FAIL")
        return
    values["phase"] = phase
    values["visual_130_gate"] = "NOT_QUALIFIED"
    values["physics_terrain_collision_gate"] = "NOT_QUALIFIED"
    values["cpu_gpu_frame_gate"] = "NOT_QUALIFIED"
    f.store_string(JSON.stringify(values, "  "))
    f.close()

func _verify() -> void:
    var phase := _phase()
    if phase.is_empty() or OS.get_environment("A3_SAVE_PATH").is_empty() or OS.get_environment("A4_ROCK_STATE_PATH").is_empty():
        _fail("isolated save paths and phase required")
        return
    var world: Node3D = load("res://scenes/main.tscn").instantiate()
    root.add_child(world)
    await process_frame
    var terrain: VoxelLodTerrain = world.get_node("Terrain")
    var instancer: VoxelInstancer = world.get_node("Terrain/RockInstancer")
    var manager: Node3D = world.get_node("RockManager")
    var player: Node3D = world.get_node("Player")
    if instancer == null or not instancer.library is VoxelInstanceLibrary or manager == null:
        _fail("instancer/manager/library unavailable")
        return
    var item = instancer.library.get_item(100)
    if item == null or not item.persistent or item.lod_index != 2:
        _fail("rock item persistence or LOD is wrong")
        return
    player.global_position = Vector3(0, 21, 8)
    var limit := Time.get_ticks_msec() + MAX_WAIT_MS
    var static_count := 0
    while Time.get_ticks_msec() < limit:
        await process_frame
        static_count = int(instancer.debug_get_instance_counts().get(100, 0))
        if static_count >= 20:
            break
    if static_count < 20:
        _fail("native rocks did not load: " + str(static_count))
        return
    # Let the streamer stabilize for a fixed interval, no favorable snapshots.
    var settle := Time.get_ticks_msec() + 1000
    while Time.get_ticks_msec() < settle:
        await process_frame
    static_count = int(instancer.debug_get_instance_counts().get(100, 0))
    if phase == "write":
        if DisplayServer.get_name() != "headless":
            _fail("A4 E2E smoke is explicitly headless; graphical acceptance separate")
            return
        instancer.remove_instances_in_sphere(instancer.to_local(TEST_AREA), REMOVE_RADIUS)
        await process_frame
        await process_frame
        var after_count := int(instancer.debug_get_instance_counts().get(100, 0))
        if after_count >= static_count:
            _fail("native static count did not decrease after removal")
            return
        # The pinned headless renderer returns zero instance transforms.
        # The callback must NOT invent one physics body per static removal.
        if int(manager.call("persisted_body_count")) != 0:
            _fail("headless removal invented bodies from unavailable transforms")
            return
        # Exercise the same manager constructor with controlled, nonzero
        # transforms, and persist those bodies across a new Godot process.
        var origins := [
            Vector3(2.0, 14.0, 2.0),
            Vector3(-3.0, 14.0, 4.0),
            Vector3(6.0, 14.0, -4.0)
        ]
        for p in origins:
            manager.call("spawn_promoted", Transform3D(Basis(), p))
        await process_frame
        var promoted := int(manager.call("persisted_body_count"))
        if promoted != origins.size():
            _fail("explicit transform promotion lost identities: expected=%d actual=%d" % [origins.size(), promoted])
            return
        if int(manager.call("active_body_count")) > 24:
            _fail("active body budget exceeded")
            return
        var identities: Dictionary = {}
        for child in manager.get_children():
            if not (child is RigidBody3D):
                continue
            var body_id := String(child.get("rock_id"))
            if identities.has(body_id):
                _fail("duplicate controlled body: " + body_id)
                return
            identities[body_id] = true
            if child.global_position.distance_to(TEST_AREA) > REMOVE_RADIUS + 4.0:
                _fail("controlled body lost initial transform: " + str(child.global_position))
                return
        if identities.size() != promoted:
            _fail("unregistered promoted bodies")
            return
        var tracker: VoxelSaveCompletionTracker = terrain.save_modified_blocks()
        if tracker == null:
            _fail("terrain/instance save tracker absent")
            return
        var save_limit := Time.get_ticks_msec() + 60000
        while not tracker.is_complete() and not tracker.is_aborted():
            if Time.get_ticks_msec() > save_limit:
                _fail("native save tracker timed out")
                return
            await process_frame
        if tracker.is_aborted():
            _fail("native save tracker aborted")
            return
        terrain.stream.flush()
        if not bool(manager.call("save_states")):
            _fail("rock sidecar failed to write")
            return
        if not FileAccess.file_exists(OS.get_environment("A3_SAVE_PATH")) or not FileAccess.file_exists(OS.get_environment("A4_ROCK_STATE_PATH")):
            _fail("SQLite or rock JSON missing")
            return
        _report(phase, {
            "static_count_before": static_count,
            "static_count_after": after_count,
            "native_static_removed": static_count - after_count,
            "controlled_promoted_count": promoted,
            "promoted_count": promoted,
            "active_count": int(manager.call("active_body_count")),
            "native_blocks": instancer.debug_get_block_count(),
            "headless_native_transform_gate": "NOT_QUALIFIED",
            "graphical_promotion_gate": "NOT_QUALIFIED"
        })
        print("A4_HEADLESS_NATIVE_REMOVAL_PERSISTENCE_PASS before=", static_count,
              " after=", after_count, " controlled_bodies=", promoted)
    else:
        var loaded_bodies := int(manager.call("persisted_body_count"))
        if loaded_bodies <= 0 or loaded_bodies != int(manager.call("get_report").get("restored_bodies", 0)):
            _fail("promoted bodies not restored from sidecar")
            return
        if int(manager.call("active_body_count")) > 24:
            _fail("body budget exceeded on reopen")
            return
        var write_path := OS.get_environment("A4_RESULTS_DIR").path_join("a4_write.json")
        if not FileAccess.file_exists(write_path):
            _fail("write-process summary unavailable")
            return
        var original = JSON.parse_string(FileAccess.get_file_as_string(write_path))
        if not (original is Dictionary):
            _fail("malformed write summary")
            return
        # Same seed, viewport, path, warmup. Native persistent removals
        # must remain absent after fully rebuilding the instancer.
        if static_count >= int(original.get("static_count_before", 0)):
            _fail("native static rocks respawned after SQLite reopen")
            return
        if static_count > int(original.get("static_count_after", 0)) + 8:
            _fail("native removal persistence drifted after reopen")
            return
        # On reopen, native VoxelStreamSQLite must still have instancing
        # removals. Cross-process report compares live counts on same route.
        _report(phase, {
            "static_count_reopened": static_count,
            "promoted_count_reopened": loaded_bodies,
            "active_count": int(manager.call("active_body_count")),
            "native_blocks": instancer.debug_get_block_count(),
            "headless_native_transform_gate": "NOT_QUALIFIED",
            "graphical_promotion_gate": "NOT_QUALIFIED"
        })
        print("A4_REOPEN_PASS static=", static_count, " restored_bodies=", loaded_bodies)
    world.queue_free()
    quit(0)
