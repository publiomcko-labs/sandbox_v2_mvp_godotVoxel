extends RigidBody3D
# Spawned by native VoxelInstancer.remove_instances_in_sphere(). The same
# transform is assigned BEFORE add_child. A4 manager owns persistence.
@export var rock_id: String = ""
var restored_from_disk: bool = false

func _ready() -> void:
    var tags=preload("res://tests/a8_p83_object_tags.gd")
    if tags.active():
        var visual: MeshInstance3D=get_node("MeshInstance3D") as MeshInstance3D
        visual.material_override=tags.make(Color.RED)
    # 0.7m radius: geometric volume 1.437m3; at 3600kg the rock sinks
    # in 1000kg/m3 water. Collision scale stays as configured by the scene.
    var s := global_transform.basis.get_scale()
    var scale_volume := absf(s.x * s.y * s.z)
    set_meta("a5_displaced_volume_m3", 1.436755 * scale_volume)
    set_meta("a5_water_radius_m", 0.7 * maxf(s.x, maxf(s.y, s.z)))
    if rock_id.is_empty():
        var p := global_position
        rock_id = "x%d_y%d_z%d" % [roundi(p.x * 100.0), roundi(p.y * 100.0), roundi(p.z * 100.0)]
    var manager := get_tree().get_first_node_in_group("a4_rock_manager")
    if manager != null:
        manager.call("register_body", self)
    elif not OS.get_cmdline_user_args().has("--a4-standalone-physics"):
        push_error("A4_BODY_ORPHAN: no rock manager")
