extends VoxelInstanceLibraryMultiMeshItem
# The native VoxelInstancer supplies the original transform directly.
# Do not rely on a PackedScene root acquiring its transform before _ready.
var _logged := 0

func _on_instance_removed(instancer: VoxelInstancer, local_transform: Transform3D) -> void:
    # Godot's headless RenderingServer provides no usable per-instance
    # MultiMesh transform in this pinned engine build: callback transforms
    # repeatedly return identity even while remove-count bookkeeping works.
    # Never fabricate rigid bodies at the origin; qualify on graphical GPU.
    if DisplayServer.get_name() == "headless":
        if _logged == 0:
            print("A4_HEADLESS_MULTIMESH_TRANSFORM_UNAVAILABLE: GPU promotion not qualified")
        _logged += 1
        return
    if _logged < 3:
        print("A4_NATIVE_REMOVAL_TRANSFORM local=", local_transform.origin,
              " parent=", instancer.global_position)
        _logged += 1
    var manager := instancer.get_tree().get_first_node_in_group("a4_rock_manager")
    if manager == null:
        push_error("A4_PROMOTION_NO_MANAGER")
        return
    var world_transform := instancer.global_transform * local_transform
    manager.call_deferred("spawn_promoted", world_transform)
