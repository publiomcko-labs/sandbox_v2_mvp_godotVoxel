extends SceneTree
# Exercise the real V3 entrypoint and the same brush/flush/close path as UI.
const REMOVE_CENTER := Vector3(8,-4,15)
const ADD_CENTER := Vector3(15,26,15)
const RADIUS := 4.0
var _events: Array[int] = []

func _initialize() -> void:
    call_deferred("_test")

func _fail(reason: String) -> void:
    push_error("V3_RUNTIME_FIXTURE_FAIL: " + reason)
    quit(1)

func _test() -> void:
    var write := "--phase=write" in OS.get_cmdline_user_args()
    var scene: PackedScene = load("res://scenes/v3_main.tscn")
    var runtime = scene.instantiate()
    root.add_child(runtime)
    if not runtime.running:
        _fail("runtime failed to start")
        return
    runtime.terrain_edited.connect(func(_bounds: AABB, revision: int, _command: int): _events.append(revision))
    var world: WorldBootstrap = runtime.world
    var terrain: VoxelLodTerrain = runtime.terrain
    runtime.player.set_process(false)
    runtime.player.set_physics_process(false)
    runtime.player.global_position = Vector3(10,12,15)
    var deadline := Time.get_ticks_msec() + 60000
    while not (world.can_edit_sphere(REMOVE_CENTER,RADIUS) and world.can_edit_sphere(ADD_CENTER,RADIUS)):
        if Time.get_ticks_msec() > deadline:
            _fail("LOD0 timeout")
            return
        await process_frame
    var state: Dictionary = runtime.session.get_state()
    if state.get("active_regions") != 27 or state.get("aggregate_regions") != 98 or state.get("dormant_regions") != 218:
        _fail("interest counts")
        return
    var tool := terrain.get_voxel_tool()
    if write:
        if runtime.submit_brush(REMOVE_CENTER,false,RADIUS) != "accepted" or runtime.submit_brush(ADD_CENTER,true,RADIUS) != "accepted":
            _fail("actual brush path")
            return
        if _events != [1,2]:
            _fail("terrain event delivery")
            return
        runtime.request_flush()
        while runtime.saving:
            await process_frame
        if not FileAccess.file_exists(runtime.session.get_world_path().path_join("session_pending/intent.json")):
            _fail("flush must keep dirty marker")
            return
    elif int(state.get("terrain_revision")) != 2 or int(state.get("checkpoint_generation")) != 1 or not _events.is_empty():
        _fail("reopen counters")
        return
    if tool.get_voxel_f(Vector3i(8,-4,15)) <= 0.2 or tool.get_voxel_f(Vector3i(16,26,15)) >= -0.2:
        _fail("persisted SDF signs")
        return
    print("V3_RUNTIME_FIXTURE_PASS phase=", "write" if write else "reopen")
    runtime.request_close()
