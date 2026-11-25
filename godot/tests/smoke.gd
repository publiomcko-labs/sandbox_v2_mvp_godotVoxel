extends SceneTree

func _initialize() -> void:
    call_deferred("_verify")

func _verify() -> void:
    var failure := ""
    if not ClassDB.class_exists("VoxelLodTerrain"):
        failure = "Voxel Tools module is not available"
    elif not ClassDB.class_exists("WorldBootstrap"):
        failure = "C++ GDExtension WorldBootstrap is not available"
    else:
        var scene: PackedScene = load("res://scenes/main.tscn")
        if scene == null:
            failure = "main.tscn failed to load"
        else:
            var world := scene.instantiate()
            root.add_child(world)
            await process_frame
            if not world.has_method("is_voxel_ready") or not world.is_voxel_ready():
                failure = "C++ could not access VoxelLodTerrain.get_voxel_tool"
            world.queue_free()
    if failure != "":
        push_error("A0_SMOKE_FAIL: " + failure)
        quit(1)
    else:
        print("A0_SMOKE_PASS")
        quit(0)
