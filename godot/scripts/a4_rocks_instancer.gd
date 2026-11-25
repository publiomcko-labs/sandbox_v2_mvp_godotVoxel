extends VoxelInstancer
# A4: Voxel Tools owns instance generation, batching, streaming, LOD and
# removal. No second region manager or individually spawned distant rock nodes.
const ROCK_LAYER_ID := 100
const RockItem = preload("res://scripts/a4_rock_item.gd")
const ROCK_DENSITY_PER_M2 := 0.016

func _enter_tree() -> void:
    var gen := VoxelInstanceGenerator.new()
    gen.emit_mode = VoxelInstanceGenerator.EMIT_FROM_FACES
    gen.density = ROCK_DENSITY_PER_M2
    gen.min_slope_degrees = 0.0
    gen.max_slope_degrees = 48.0
    gen.min_height = -6.0
    gen.max_height = 85.0
    gen.min_scale = 0.75
    gen.max_scale = 1.35
    gen.random_rotation = true
    gen.snap_to_generator_sdf_enabled = true
    gen.snap_to_generator_sdf_sample_count = 4
    gen.snap_to_generator_sdf_search_distance = 2.0
    gen.offset_along_normal = -0.15

    var mesh := SphereMesh.new()
    mesh.radius = 0.7
    mesh.height = 1.4
    mesh.radial_segments = 8
    mesh.rings = 4
    var stone := StandardMaterial3D.new()
    stone.albedo_color = Color(0.37, 0.38, 0.39, 1.0)
    stone.roughness = 1.0
    # Opt-in diagnostic tags; static MultiMesh instances retain their mesh,
    # instance transforms, LOD and native removal callbacks.
    var tags=preload("res://tests/a8_p83_object_tags.gd")
    mesh.material = tags.make(Color.RED) if tags.active() else stone

    var item := RockItem.new()
    item.name = "a4_stone"
    item.mesh = mesh
    item.mesh_lod1 = mesh
    item.mesh_lod2 = mesh
    item.mesh_lod3 = mesh
    item.generator = gen
    # LOD 2 provides >130m coverage using the Voxel Tools terrain LOD grid.
    item.lod_index = 2
    # Native VoxelStreamSQLite records removals; modified blocks don't respawn.
    item.persistent = true
    item.removal_behavior = VoxelInstanceLibraryMultiMeshItem.REMOVAL_BEHAVIOR_CALLBACK
    # No colliders for hundreds of MultiMesh instances. Physics is promoted.
    item.collision_distance = 0.0

    var lib := VoxelInstanceLibrary.new()
    lib.add_item(ROCK_LAYER_ID, item)
    library = lib
    print("A4_INSTANCER_READY layer=", ROCK_LAYER_ID, " density=", ROCK_DENSITY_PER_M2)

func static_instance_count() -> int:
    var d: Dictionary = debug_get_instance_counts()
    return int(d.get(ROCK_LAYER_ID, 0))
