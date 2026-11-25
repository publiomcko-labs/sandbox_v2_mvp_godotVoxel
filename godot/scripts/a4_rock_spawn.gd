extends Node3D
# IMPORTANT: VoxelInstancer sets a removal_scene root's transform BEFORE
# adding it to the tree. That root must remain Node3D, not RigidBody3D:
# physics initialization can reset the latter's transform to identity.
const ROCK_BODY_SCENE := preload("res://scenes/rock_body.tscn")

func _ready() -> void:
    var origin_transform := global_transform
    var source := origin_transform.origin
    var id := "x%d_y%d_z%d" % [
        roundi(source.x * 100.0),
        roundi(source.y * 100.0),
        roundi(source.z * 100.0)
    ]
    var manager := get_tree().get_first_node_in_group("a4_rock_manager") as Node3D
    if manager == null:
        push_error("A4_PROMOTION_FAIL: missing manager")
        queue_free()
        return
    var body := ROCK_BODY_SCENE.instantiate() as RigidBody3D
    if body == null:
        push_error("A4_PROMOTION_FAIL: missing RigidBody scene")
        queue_free()
        return
    body.set("rock_id", id)
    body.set("restored_from_disk", false)
    body.transform = manager.global_transform.affine_inverse() * origin_transform
    manager.add_child(body)
    # Write again after physics joins the scene, without changing identity.
    body.global_transform = origin_transform
    queue_free()
