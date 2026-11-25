extends Node
# A3 manual editor only; A2 benchmark does not run this controller's input.
# Click once to capture cursor; then hold left to carve/right to build at 10Hz.
# Ctrl+S requests async SQLite save and reports when it has completed.
const EDIT_INTERVAL_S := 0.1
const BRUSH_RADIUS_M := 1.5
const MAX_RAY_M := 36.0
var _elapsed: float = EDIT_INTERVAL_S
var _saving := false

@onready var world: Node3D = get_parent()
@onready var terrain: VoxelLodTerrain = get_parent().get_node("Terrain")
@onready var camera: Camera3D = get_parent().get_node("Player/Camera3D")
@onready var status: Label = get_parent().get_node("HUD/Status")

func _ready() -> void:
    _set_status("A5: G physical swim | F rock | LMB carve/RMB add | Ctrl+S save | Esc")

func _set_status(message: String) -> void:
    if status:
        status.text = message
    print(message)

func _unhandled_input(event: InputEvent) -> void:
    if event is InputEventKey and event.pressed and not event.echo:
        if event.keycode == KEY_S and event.ctrl_pressed:
            _save_requested()

func _process(delta: float) -> void:
    if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
        _elapsed = EDIT_INTERVAL_S
        return
    _elapsed += delta
    if _elapsed < EDIT_INTERVAL_S:
        return
    var add := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
    var remove := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
    if not add and not remove:
        return
    _elapsed = 0.0
    var tool: VoxelTool = terrain.get_voxel_tool()
    if tool == null:
        return
    var direction := -camera.global_transform.basis.z.normalized()
    var origin := camera.global_position
    var hit: VoxelRaycastResult = tool.raycast(origin, direction, MAX_RAY_M)
    if hit == null:
        if not add:
            _set_status("A3: no surface within 36m; move closer")
            return
        # Build in open air at a fixed distance when no surface is in range.
        var fallback := origin + direction * 12.0
        _do_edit(fallback, true)
        return
    var contact := origin + direction * hit.distance
    # Carve into the surface, or add just in front of it.
    var center := contact + direction * (BRUSH_RADIUS_M * (0.55 if not add else -0.55))
    _do_edit(center, add)

func _do_edit(center: Vector3, add: bool) -> void:
    if not world.edit_sphere(center, add, BRUSH_RADIUS_M):
        _set_status("A3: edit deferred (LOD0 not editable); no partial change")
        return
    var kind := "ADD" if add else "REMOVE"
    _set_status("A3 %s accepted | apply=%.3fms | save Ctrl+S | VISUAL <100ms NOT QUALIFIED" %
        [kind, world.get_last_edit_apply_ms()])
    print("A3_EDIT_ACCEPT type=", kind, " center=", center, " monotonic_us=",
          world.get_last_edit_started_usec(), " apply_ms=", world.get_last_edit_apply_ms())

func _save_requested() -> void:
    if _saving:
        return
    _save_async()

func _save_async() -> void:
    _saving = true
    _set_status("A3: SQLite save in progress...")
    var tracker: VoxelSaveCompletionTracker = terrain.save_modified_blocks()
    if tracker == null:
        _saving = false
        _set_status("A3: save tracker unavailable")
        return
    var begin := Time.get_ticks_msec()
    while not tracker.is_complete() and not tracker.is_aborted():
        if Time.get_ticks_msec() - begin > 30000:
            _saving = false
            _set_status("A3_SAVE_TIMEOUT: inspect logs")
            return
        await get_tree().process_frame
    if tracker.is_aborted():
        _set_status("A3_SAVE_ABORTED")
    else:
        _set_status("A3_SAVE_COMPLETE: changes committed to SQLite")
    _saving = false
