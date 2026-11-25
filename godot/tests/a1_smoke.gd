extends SceneTree
# Headless structural/SDF tests; neither rendered pixels nor timing gates.
const TerrainScript = preload("res://scripts/terrain_sdf.gd")
const SEED := 20261119

func _initialize() -> void:
    call_deferred("_verify")

func _sdf_at(graph: VoxelGeneratorGraph, xyz: Vector3) -> float:
    var buffer := VoxelBuffer.new()
    buffer.create(1, 1, 1)
    graph.generate_block(buffer, xyz, 0)
    return buffer.get_voxel_f(0, 0, 0, VoxelBuffer.CHANNEL_SDF)

func _fail(message: String) -> void:
    push_error("A1_GRAPH_FAIL: " + message)
    quit(1)

func _verify() -> void:
    var graph: VoxelGeneratorGraph = TerrainScript.build_generator(SEED)
    if graph == null:
        _fail("graph did not compile")
        return
    var inside_cave := _sdf_at(graph, Vector3(0, -11, 0))
    var solid := _sdf_at(graph, Vector3(0, -20, 20))
    var sky := _sdf_at(graph, Vector3(0, 64, 20))
    var entrance := _sdf_at(graph, Vector3(38, 0, 0))
    if not (inside_cave > 1.0 and solid < -1.0 and sky > 1.0 and entrance > 1.0):
        _fail("invalid geometry: cave=%f solid=%f sky=%f entrance=%f" % [inside_cave, solid, sky, entrance])
        return

    var same_seed: VoxelGeneratorGraph = TerrainScript.build_generator(SEED)
    var other_seed: VoxelGeneratorGraph = TerrainScript.build_generator(SEED + 47)
    if same_seed == null or other_seed == null:
        _fail("seeded graph construction failed")
        return
    var sample_pos := Vector3(81, 5, 67)
    var original := _sdf_at(graph, sample_pos)
    if absf(original - _sdf_at(same_seed, sample_pos)) > 0.0001:
        _fail("same-seed SDF not deterministic")
        return
    if absf(original - _sdf_at(other_seed, sample_pos)) < 0.0001:
        _fail("different seeds produced identical SDF")
        return

    var packed: PackedScene = load("res://scenes/main.tscn")
    if packed == null:
        _fail("scene failed to load")
        return
    var world := packed.instantiate()
    root.add_child(world)
    await process_frame
    var terrain := world.get_node("Terrain")
    if not terrain.get("graph_ready") or not (terrain.get("generator") is VoxelGeneratorGraph):
        _fail("main scene did not initialize A1 graph")
        return
    if terrain.get("lod_count") != 4 or terrain.get("mesh_block_size") != 16 or terrain.get("view_distance") < 160:
        _fail("LOD or requested horizon configuration drifted")
        return
    var requested_distance = terrain.get("view_distance")
    world.queue_free()
    print("A1_GRAPH_PASS seed=", SEED, " tunnel_sdf=", inside_cave, " solid_sdf=", solid)
    print("A1_HORIZON_CONFIG_PASS requested_view_distance=", requested_distance, " (NOT pixel-verified)")
    quit(0)
