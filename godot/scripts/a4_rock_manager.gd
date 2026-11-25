extends Node3D
# A4 only manages promoted rock bodies. Static rock batching/streaming and
# removal belong to VoxelInstancer. A capped set of RigidBody3Ds uses physics.
const MAX_ACTIVE_BODIES := 24
const ACTIVATE_RADIUS_M := 24.0
const FREEZE_RADIUS_M := 32.0
const MAX_INTERACT_DISTANCE_M := 24.0
const PROMOTE_RADIUS_M := 2.5
const TICK_INTERVAL_S := 0.25
const AUTOSAVE_INTERVAL_S := 5.0
const ROCK_SCENE := preload("res://scenes/rock_body.tscn")
const SAVE_VERSION := 1

var _bodies: Dictionary = {}
var _save_path := ""
var _elapsed := 0.0
var _autosave_elapsed := 0.0
var _restored := 0
var _last_promotion_count := 0
var _write_count := 0

@onready var terrain: VoxelLodTerrain = get_parent().get_node("Terrain")
@onready var instancer: VoxelInstancer = get_parent().get_node("Terrain/RockInstancer")
@onready var player: Node3D = get_parent().get_node("Player")
@onready var camera: Camera3D = get_parent().get_node("Player/Camera3D")

func _enter_tree() -> void:
    add_to_group("a4_rock_manager")

func _ready() -> void:
    _save_path = OS.get_environment("A4_ROCK_STATE_PATH")
    if _save_path.is_empty():
        var override_path := OS.get_environment("A3_SAVE_PATH")
        if not override_path.is_empty():
            _save_path = override_path + ".a4_rocks.json"
        else:
            _save_path = "user://worlds/a4_v1_seed_%d.json" % terrain.world_seed
    var base_dir := _save_path.get_base_dir()
    if DirAccess.make_dir_recursive_absolute(base_dir) != OK:
        push_error("A4_SAVE_FAIL: unable to create " + base_dir)
        return
    _restore_states()
    print("A4_MANAGER_READY state_path=", _save_path, " restored=", _restored)

func spawn_promoted(world_transform: Transform3D) -> void:
    var p := world_transform.origin
    if not p.is_finite():
        push_error("A4_PROMOTION_BAD_TRANSFORM: nonfinite original position")
        return
    var id := "x%d_y%d_z%d" % [
        roundi(p.x * 100.0), roundi(p.y * 100.0), roundi(p.z * 100.0)
    ]
    if _bodies.has(id):
        push_error("A4_PROMOTION_COLLISION id=" + id + " original=" + str(p))
        return
    var body := ROCK_SCENE.instantiate() as RigidBody3D
    body.set("rock_id", id)
    body.set("restored_from_disk", false)
    body.transform = global_transform.affine_inverse() * world_transform
    add_child(body)
    body.global_transform = world_transform

func register_body(body: RigidBody3D) -> void:
    var id: String = body.get("rock_id")
    if id.is_empty():
        push_error("A4_BODY_NO_ID")
        body.queue_free()
        return
    if _bodies.has(id):
        # Never expose two bodies with the same persisted identity.
        push_error("A4_DUPLICATE_PREVENTED id=", id)
        body.queue_free()
        return
    _bodies[id] = body
    body.freeze = true
    _refresh_activity()
    if not bool(body.get("restored_from_disk")):
        _last_promotion_count += 1
        print("A4_ROCK_PROMOTED id=", id, " pos=", body.global_position)

func active_body_count() -> int:
    var n := 0
    for rock in _bodies.values():
        if is_instance_valid(rock) and not rock.freeze:
            n += 1
    return n

func persisted_body_count() -> int:
    return _bodies.size()

func _refresh_activity() -> void:
    if player == null:
        return
    var active := 0
    # Sort IDs so body promotion order does not depend on dictionary iteration.
    var keys := _bodies.keys()
    keys.sort()
    for key in keys:
        var body: RigidBody3D = _bodies[key]
        if not is_instance_valid(body):
            continue
        var distance := player.global_position.distance_to(body.global_position)
        var near := distance <= ACTIVATE_RADIUS_M if body.freeze else distance <= FREEZE_RADIUS_M
        if near and active < MAX_ACTIVE_BODIES:
            if body.freeze:
                body.freeze = false
            active += 1
        else:
            if not body.freeze:
                body.freeze = true

func _process(delta: float) -> void:
    _elapsed += delta
    _autosave_elapsed += delta
    if _elapsed >= TICK_INTERVAL_S:
        _elapsed = 0.0
        _refresh_activity()
    if _autosave_elapsed >= AUTOSAVE_INTERVAL_S:
        _autosave_elapsed = 0.0
        if not _bodies.is_empty():
            save_states()

func _unhandled_input(event: InputEvent) -> void:
    if not (event is InputEventKey and event.pressed and not event.echo):
        return
    if event.keycode == KEY_F and not event.ctrl_pressed:
        promote_looked_at()
    if event.keycode == KEY_S and event.ctrl_pressed:
        save_states()

func promote_looked_at() -> void:
    var tool := terrain.get_voxel_tool()
    if tool == null:
        return
    var dir := -camera.global_transform.basis.z.normalized()
    var hit := tool.raycast(camera.global_position, dir, MAX_INTERACT_DISTANCE_M)
    if hit == null:
        print("A4_NO_ROCK_SURFACE: aim near a rock on the ground")
        return
    var hit_pos := camera.global_position + dir * hit.distance
    # The terrain-relative center is required by the native instancer.
    var target := instancer.to_local(hit_pos)
    instancer.remove_instances_in_sphere(target, PROMOTE_RADIUS_M)
    print("A4_PROMOTION_REQUEST position=", hit_pos, " radius=", PROMOTE_RADIUS_M)

func _state_for(body: RigidBody3D) -> Dictionary:
    var p := body.global_position
    var q := body.quaternion
    var v := body.linear_velocity
    var av := body.angular_velocity
    return {
        "id": String(body.get("rock_id")),
        "p": [p.x, p.y, p.z],
        "q": [q.x, q.y, q.z, q.w],
        "v": [v.x, v.y, v.z],
        "av": [av.x, av.y, av.z],
        "sleeping": body.sleeping
    }

func save_states() -> bool:
    if _save_path.is_empty():
        return false
    var data: Array[Dictionary] = []
    var ids := _bodies.keys()
    ids.sort()
    for id in ids:
        var body: RigidBody3D = _bodies[id]
        if is_instance_valid(body):
            data.append(_state_for(body))
    var path_tmp := _save_path + ".tmp"
    var f := FileAccess.open(path_tmp, FileAccess.WRITE)
    if f == null:
        push_error("A4_SAVE_FAIL: cannot write temp file")
        return false
    f.store_string(JSON.stringify({
        "version": SAVE_VERSION,
        "seed": int(terrain.get("world_seed")),
        "rocks": data
    }, "  "))
    f.flush()
    f.close()
    var result := DirAccess.rename_absolute(path_tmp, _save_path)
    if result != OK:
        push_error("A4_SAVE_FAIL: cannot replace state file, code=" + str(result))
        return false
    _write_count += 1
    print("A4_SAVE_PASS rocks=", data.size(), " path=", _save_path)
    return true

func _vector3(v: Array) -> Vector3:
    return Vector3(float(v[0]), float(v[1]), float(v[2]))

func _restore_states() -> void:
    if not FileAccess.file_exists(_save_path):
        return
    var f := FileAccess.open(_save_path, FileAccess.READ)
    if f == null:
        push_error("A4_RESTORE_FAIL: unable to open rock save")
        return
    var parsed = JSON.parse_string(f.get_as_text())
    f.close()
    if not (parsed is Dictionary) or int(parsed.get("version", -1)) != SAVE_VERSION or int(parsed.get("seed", -1)) != int(terrain.get("world_seed")):
        push_error("A4_RESTORE_FAIL: version or seed mismatch")
        return
    var entries: Array = parsed.get("rocks", [])
    for data in entries:
        if not (data is Dictionary):
            push_error("A4_RESTORE_FAIL: malformed record")
            continue
        var id := String(data.get("id", ""))
        var pos: Array = data.get("p", [])
        var rot: Array = data.get("q", [])
        if id.is_empty() or pos.size() != 3 or rot.size() != 4:
            push_error("A4_RESTORE_FAIL: malformed transform")
            continue
        var body := ROCK_SCENE.instantiate() as RigidBody3D
        body.set("rock_id", id)
        body.set("restored_from_disk", true)
        body.position = _vector3(pos)
        body.quaternion = Quaternion(float(rot[0]), float(rot[1]), float(rot[2]), float(rot[3]))
        add_child(body)
        if _bodies.has(id):
            var velocity: Array = data.get("v", [])
            var angular: Array = data.get("av", [])
            if velocity.size() == 3:
                body.linear_velocity = _vector3(velocity)
            if angular.size() == 3:
                body.angular_velocity = _vector3(angular)
            body.sleeping = bool(data.get("sleeping", true))
            _restored += 1
    print("A4_RESTORE_PASS count=", _restored)

func get_report() -> Dictionary:
    return {
        "static_instances": int(instancer.call("static_instance_count")),
        "native_instancer_blocks": instancer.debug_get_block_count(),
        "promoted_rock_bodies": _bodies.size(),
        "active_dynamic_bodies": active_body_count(),
        "restored_bodies": _restored,
        "promotion_events": _last_promotion_count,
        "save_count": _write_count
    }
