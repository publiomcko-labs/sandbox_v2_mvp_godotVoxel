extends SceneTree
# Opt-in fixture: actual VoxelTool and isolated SQLite, no visual gate.
const REMOVE_CENTER := Vector3(8, -4, 15)
const ADD_CENTER := Vector3(15, 26, 15)
const REMOVE_PROBE := Vector3i(8, -4, 15)
const ADD_PROBE := Vector3i(16, 26, 15)
const RADIUS := 4.0

func _initialize() -> void:
    call_deferred("_test")

func _fail(reason: String) -> void:
    push_error("V3_SESSION_FAIL: " + reason)
    quit(1)

func _test() -> void:
    var phase := ""
    for arg in OS.get_cmdline_user_args():
        if arg == "--phase=write":
            phase = "write"
        if arg == "--phase=reopen":
            phase = "reopen"
    var worlds := OS.get_environment("V3_TEST_WORLD_ROOT")
    var external := OS.get_environment("V3_TEST_EXTERNAL_MODS")
    if phase.is_empty() or worlds.is_empty() or external.is_empty():
        _fail("isolated fixture paths/phase required")
        return
    var session := V3WorldSession.new()
    if not session.open(ProjectSettings.globalize_path("res://mods/first-party"),
            external, worlds, "fixture", 20261119):
        _fail("open: " + session.get_last_error())
        return
    var ids := session.get_content_ids()
    if ids.size() != 5 or not ids.has("geology_demo:rock") or not ids.has("life_demo:grazer"):
        _fail("external package registry")
        return
    var rock: Variant = JSON.parse_string(session.get_record_json("geology_demo:rock"))
    if not rock is Dictionary or rock.get("type") != "procedural_rock":
        _fail("typed record lookup")
        return
    var path := session.get_world_path()
    OS.set_environment("A3_SAVE_PATH", path.path_join("terrain.sqlite"))
    OS.set_environment("A4_ROCK_STATE_PATH", path.path_join("rocks.json"))
    var scene: PackedScene = load("res://scenes/main.tscn")
    var world := scene.instantiate() as WorldBootstrap
    root.add_child(world)
    await process_frame
    var terrain := world.get_node("Terrain") as VoxelLodTerrain
    var player := world.get_node("Player") as Node3D
    player.set_process(false)
    player.set_physics_process(false)
    player.global_position = Vector3(10, 12, 15)
    if not session.bind_world(world):
        _fail("bind: " + session.get_last_error())
        return
    var deadline := Time.get_ticks_msec() + 60000
    while not (world.can_edit_sphere(REMOVE_CENTER, RADIUS) and world.can_edit_sphere(ADD_CENTER, RADIUS)):
        if Time.get_ticks_msec() > deadline:
            _fail("LOD0 readiness timeout")
            return
        await process_frame
    var tool := terrain.get_voxel_tool()
    if phase == "write":
        if session.submit(world, 1, REMOVE_CENTER, false, -1.0) != "rejected":
            _fail("invalid command accepted")
            return
        if session.submit(world, 1, Vector3(30000,10000,30000), false, RADIUS) != "deferred":
            _fail("unloaded edit not deferred")
            return
        if tool.get_voxel_f(REMOVE_PROBE) >= -0.2 or tool.get_voxel_f(ADD_PROBE) <= 0.2:
            _fail("unexpected baseline SDF")
            return
        if session.submit(world, 1, REMOVE_CENTER, false, RADIUS) != "accepted" or \
                session.submit(world, 1, REMOVE_CENTER, false, RADIUS) != "duplicate" or \
                session.submit(world, 2, ADD_CENTER, true, RADIUS) != "accepted":
            _fail("ordered command contract")
            return
        for revision in [1,2]:
            var e := session.peek_terrain_event()
            if e.get("revision") != revision or e.get("command") != revision or \
                    not e.get("bounds") is AABB or not session.ack_terrain_event(revision):
                _fail("event/revision contract")
                return
        if world.get_successful_edits() != 2 or not session.peek_terrain_event().is_empty():
            _fail("adapter edit count or queue")
            return
        if session.advance_ticks(1200000000, 2) != 2 or session.get_state().get("backlog_ticks") != 10 or \
                session.advance_ticks(0, 10) != 10:
            _fail("scheduler")
            return
    else:
        var state := session.get_state()
        if state.get("terrain_revision") != 2 or state.get("last_command") != 2 or \
                state.get("completed_tick") != 12 or state.get("checkpoint_generation") != 1:
            _fail("reopened core counters")
            return
        if session.submit(world, 2, ADD_CENTER, true, RADIUS) != "duplicate" or world.get_successful_edits() != 0:
            _fail("duplicate applied on reopen")
            return
    await process_frame
    var removed := tool.get_voxel_f(REMOVE_PROBE)
    var added := tool.get_voxel_f(ADD_PROBE)
    if removed <= 0.2 or added >= -0.2:
        _fail("actual SDF sign mismatch")
        return
    var tracker: VoxelSaveCompletionTracker = terrain.save_modified_blocks()
    if tracker == null:
        _fail("save tracker missing")
        return
    deadline = Time.get_ticks_msec() + 60000
    while not tracker.is_complete() and not tracker.is_aborted():
        if Time.get_ticks_msec() > deadline:
            _fail("save timeout")
            return
        await process_frame
    if tracker.is_aborted():
        _fail("save aborted")
        return
    terrain.stream.flush()
    if not world.get_node("RockManager").save_states():
        _fail("rock sidecar save")
        return
    if not FileAccess.file_exists(path.path_join("terrain.sqlite")):
        _fail("SQLite missing")
        return
    world.queue_free()
    await process_frame
    if not session.finish(true,true):
        _fail("finish: " + session.get_last_error())
        return
    print("V3_SESSION_%s_PASS removed=%f added=%f state=%s" % [phase.to_upper(),removed,added,session.get_state()])
    quit(0)
