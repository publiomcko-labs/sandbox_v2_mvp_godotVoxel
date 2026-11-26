extends Node
# Explicit source-tree entrypoint. Do not change the A5 default main scene.
# WorldCore owns command IDs and revisions; Voxel Tools owns voxel streaming.
signal terrain_edited(bounds: AABB, revision: int, command: int)
const WORLD_SCENE := preload("res://scenes/main.tscn")
const EDITOR := preload("res://scripts/v3_edit_controller.gd")
const TICK_BUDGET := 4
@export var geology_enabled := false
@export var caves_enabled := false
var cave_config: Dictionary = {}
var geology_config: Dictionary = {}
var selected_material := 0
var session: V3WorldSession
var world: WorldBootstrap
var terrain: VoxelLodTerrain
var player: Node3D
var rocks: Node3D
var status: Label
var running := false
var saving := false
var closing := false
var last_revision := 0
var _last_usec := 0
var _next_command := 1

func _ready() -> void:
    get_tree().auto_accept_quit = false
    var first := ProjectSettings.globalize_path("res://mods/first-party")
    var mods := OS.get_environment("V3_MOD_ROOT")
    var worlds := OS.get_environment("V3_WORLD_ROOT")
    var world_id := OS.get_environment("V3_WORLD_ID")
    var seed_text := OS.get_environment("V3_WORLD_SEED")
    if mods.is_empty():
        mods = ProjectSettings.globalize_path("user://mods_v3")
    if worlds.is_empty():
        worlds = ProjectSettings.globalize_path("user://worlds_v33" if caves_enabled else ("user://worlds_v32" if geology_enabled else "user://worlds_v3"))
    if world_id.is_empty():
        world_id = "world"
    if seed_text.is_empty():
        seed_text = "20261119"
    if not seed_text.is_valid_int() or seed_text.to_int() < 0 or seed_text.to_int() > 2147483000:
        _fatal("invalid seed")
        return
    if not mods.is_absolute_path() or not worlds.is_absolute_path():
        _fatal("mod and world roots must be absolute")
        return
    if DirAccess.make_dir_recursive_absolute(mods) != OK or DirAccess.make_dir_recursive_absolute(worlds) != OK:
        _fatal("cannot create V3 directories")
        return
    session = V3WorldSession.new()
    var opened := false
    if geology_enabled:
        var profile := OS.get_environment("V3_GEOLOGY_PROFILE")
        if profile.is_empty():
            profile = "earth:temperate"
        if caves_enabled:
            var cave_profile := OS.get_environment("V3_CAVE_PROFILE")
            if cave_profile.is_empty():
                cave_profile = "karst:natural"
            opened = session.open_caves(first, mods, worlds, world_id, seed_text.to_int(),
                ProjectSettings.globalize_path("res://mods/geology"),profile,
                ProjectSettings.globalize_path("res://mods/caves"),cave_profile)
            if opened:
                var cave_parsed: Variant = JSON.parse_string(session.get_cave_json())
                if not cave_parsed is Dictionary:
                    _fatal("invalid compiled cave config")
                    return
                cave_config = cave_parsed
        else:
            opened = session.open_geology(first, mods, worlds, world_id, seed_text.to_int(),
                ProjectSettings.globalize_path("res://mods/geology"), profile)
        if opened:
            var parsed: Variant = JSON.parse_string(session.get_geology_json())
            if not parsed is Dictionary:
                _fatal("invalid compiled geology config")
                return
            geology_config = parsed
    else:
        opened = session.open(first, mods, worlds, world_id, seed_text.to_int())
    if not opened:
        _fatal("session open: " + session.get_last_error())
        return
    var path := session.get_world_path()
    OS.set_environment("A3_SAVE_PATH", path.path_join("terrain.sqlite"))
    OS.set_environment("A4_ROCK_STATE_PATH", path.path_join("rocks.json"))
    world = WORLD_SCENE.instantiate() as WorldBootstrap
    terrain = world.get_node("Terrain") as VoxelLodTerrain
    terrain.set("world_seed", seed_text.to_int())
    terrain.set("geology_config", geology_config)
    terrain.set("cave_config", cave_config)
    player = world.get_node("Player") as Node3D
    # Optional explicit exploratory spawn from validated fixture coordinates.
    if caves_enabled:
        var spawn := OS.get_environment("V3_CAVE_SPAWN").split(",")
        if spawn.size()==3 and spawn[0].is_valid_float() and spawn[1].is_valid_float() and spawn[2].is_valid_float():
            var pos := Vector3(float(spawn[0]),float(spawn[1]),float(spawn[2]))
            if pos.is_finite() and pos.length()<1000000.0:
                player.position=pos
    rocks = world.get_node("RockManager") as Node3D
    status = world.get_node("HUD/Status") as Label
    var editor := world.get_node("EditController")
    editor.set_script(EDITOR)
    editor.set("coordinator", self)
    add_child(world)
    if not bool(terrain.get("graph_ready")) or not session.bind_world(world):
        _fatal("world bind: " + session.get_last_error())
        return
    var state := session.get_state()
    last_revision = int(state.get("terrain_revision"))
    _next_command = int(state.get("last_command")) + 1
    _last_usec = Time.get_ticks_usec()
    running = true
    if geology_enabled:
        select_material(0)
    print("V3_RUNTIME_READY path=", path, " ids=", session.get_content_ids(), " state=", state)

func _fatal(reason: String) -> void:
    running = false
    push_error("V3_RUNTIME_FAIL: " + reason)
    get_tree().quit(1)

func _set_status(message: String) -> void:
    if is_instance_valid(status):
        status.text = message
    print(message)

func _process(_delta: float) -> void:
    if not running or closing:
        return
    var now := Time.get_ticks_usec()
    var elapsed := maxi(0, now - _last_usec)
    _last_usec = now
    if not session.update_interest(player.global_position) or session.advance_ticks(elapsed * 1000, TICK_BUDGET) < 0:
        _fatal("scheduler/interest: " + session.get_last_error())

func submit_brush(center: Vector3, add: bool, radius: float) -> String:
    if not running or saving or closing:
        return "deferred"
    var result: String
    if geology_enabled:
        result = session.submit_material(world, _next_command, center, add, radius, selected_material_id())
    else:
        result = session.submit(world, _next_command, center, add, radius)
    if result == "accepted" or result == "no_effect":
        _next_command += 1
    if result == "accepted":
        var e := session.peek_terrain_event()
        if e.is_empty() or int(e.get("revision", -1)) != last_revision + 1:
            _fatal("unexpected terrain event revision")
            return "rejected"
        last_revision = int(e["revision"])
        # Synchronous notification contract for later engine-owned systems.
        # No fluid/tree simulation is claimed or invoked in V3.1.
        terrain_edited.emit(e["bounds"], last_revision, int(e["command"]))
        if not session.ack_terrain_event(last_revision):
            _fatal("terrain event acknowledgement failed")
            return "rejected"
    return result

func selected_material_id() -> String:
    if not geology_enabled:
        return ""
    var palette: Array = geology_config["palette"]
    return String(palette[selected_material])

func select_material(slot: int) -> bool:
    if not geology_enabled or slot < 0 or slot >= 6 or closing:
        return false
    selected_material = slot
    _set_status("V3.2 material: " + selected_material_id() + " | keys 1-6 | LMB/RMB | Ctrl+S")
    return true

func _input(event: InputEvent) -> void:
    if not running:
        return
    if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_S and event.ctrl_pressed:
        get_viewport().set_input_as_handled()
        request_flush()
    elif closing:
        get_viewport().set_input_as_handled()
    elif geology_enabled and event is InputEventKey and event.pressed and not event.echo and event.keycode >= KEY_1 and event.keycode <= KEY_6:
        select_material(int(event.keycode) - KEY_1)
        get_viewport().set_input_as_handled()

func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_CLOSE_REQUEST and running:
        request_close()

func request_flush() -> void:
    if running and not saving and not closing:
        _save_async()

func request_close() -> void:
    if not running or closing:
        return
    closing = true
    Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
    player.set_process(false)
    player.set_physics_process(false)
    player.set_process_unhandled_input(false)
    rocks.set_process(false)
    rocks.set_process_unhandled_input(false)
    world.get_node("EditController").set_process(false)
    world.get_node("EditController").set_process_unhandled_input(false)
    for child in rocks.get_children():
        if child is RigidBody3D:
            child.freeze = true
    if not saving:
        _save_async()

func _save_failure(reason: String) -> void:
    saving = false
    _set_status("V3_SAVE_FAIL: " + reason)
    # A dirty session marker remains; never claim a clean checkpoint.
    if closing:
        _fatal(reason)

func _save_async() -> void:
    saving = true
    _set_status("V3: flushing terrain and rock stores...")
    var tracker: VoxelSaveCompletionTracker = terrain.save_modified_blocks()
    if tracker == null:
        _save_failure("tracker unavailable")
        return
    var deadline := Time.get_ticks_msec() + 60000
    while not tracker.is_complete() and not tracker.is_aborted():
        if Time.get_ticks_msec() > deadline:
            _save_failure("terrain save timeout")
            return
        await get_tree().process_frame
    if tracker.is_aborted():
        _save_failure("terrain save aborted")
        return
    terrain.stream.flush()
    if not rocks.call("save_states"):
        _save_failure("rock save failed")
        return
    saving = false
    if not closing:
        _set_status("V3_FLUSH_PASS: stores flushed; close window for clean checkpoint")
        return
    running = false
    world.queue_free()
    await get_tree().process_frame
    if not session.finish(true, true):
        _fatal("checkpoint finish: " + session.get_last_error())
        return
    print("V3_RUNTIME_CLEAN_CLOSE_PASS state=", session.get_state())
    get_tree().quit(0)
