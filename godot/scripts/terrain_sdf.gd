extends VoxelLodTerrain
# A1: deterministic volumetric SDF. This configures the Voxel Tools graph before
# the terrain node enters the streaming lifecycle; no custom region manager.
@export var world_seed: int = 20261119
var graph_ready: bool = false

func _enter_tree() -> void:
    var sdf_graph := build_generator(world_seed)
    if sdf_graph == null:
        push_error("A1_GRAPH_FAIL: failed to build deterministic SDF")
        return
    generator = sdf_graph

    # A3: only modified voxel blocks are written. Seed and format version are
    # encoded in the default filename; tests supply an isolated A3_SAVE_PATH.
    var db_path := OS.get_environment("A3_SAVE_PATH")
    if db_path.is_empty():
        db_path = "user://worlds/a3_v1_seed_%d.sqlite" % world_seed
    var folder := db_path.get_base_dir()
    if DirAccess.make_dir_recursive_absolute(folder) != OK:
        push_error("A3_SQLITE_FAIL: cannot create save folder: " + folder)
        return
    var sqlite := VoxelStreamSQLite.new()
    sqlite.database_path = db_path
    sqlite.save_generator_output = false
    stream = sqlite
    print("A3_SQLITE_READY path=", db_path)
    graph_ready = true
    print("A1_TERRAIN_READY seed=", world_seed, " lod_count=", lod_count, " view_distance=", view_distance)

static func _unary(g: VoxelGraphFunction, type_id: int, source: int, pos: Vector2) -> int:
    var n := g.create_node(type_id, pos)
    g.add_connection(source, 0, n, 0)
    return n

static func _binary(g: VoxelGraphFunction, type_id: int, a: int, b: int, pos: Vector2) -> int:
    var n := g.create_node(type_id, pos)
    g.add_connection(a, 0, n, 0)
    g.add_connection(b, 0, n, 1)
    return n

static func _offset(g: VoxelGraphFunction, type_id: int, source: int, constant: float, pos: Vector2) -> int:
    var n := g.create_node(type_id, pos)
    g.add_connection(source, 0, n, 0)
    g.set_node_default_input(n, 1, constant)
    return n

static func _constant_minus(g: VoxelGraphFunction, constant: float, source: int, pos: Vector2) -> int:
    var n := g.create_node(VoxelGraphFunction.NODE_SUBTRACT, pos)
    g.set_node_default_input(n, 0, constant)
    g.add_connection(source, 0, n, 1)
    return n

static func _square(g: VoxelGraphFunction, source: int, pos: Vector2) -> int:
    return _binary(g, VoxelGraphFunction.NODE_MULTIPLY, source, source, pos)

static func _noise_2d(g: VoxelGraphFunction, x: int, z: int, seed_value: int, period: float, octaves: int, pos: Vector2) -> int:
    var cfg := ZN_FastNoiseLite.new()
    cfg.seed = seed_value
    cfg.period = period
    cfg.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
    cfg.fractal_octaves = octaves
    var node := g.create_node(VoxelGraphFunction.NODE_FAST_NOISE_2D, pos)
    g.set_node_param_by_name(node, "noise", cfg)
    g.add_connection(x, 0, node, 0)
    g.add_connection(z, 0, node, 1)
    return node

static func build_generator(seed_value: int) -> VoxelGeneratorGraph:
    var result := VoxelGeneratorGraph.new()
    result.use_xz_caching = true
    result.use_optimized_execution_map = true
    result.use_subdivision = true
    result.subdivision_size = 16
    var g := result.get_main_function()

    var x := g.create_node(VoxelGraphFunction.NODE_INPUT_X, Vector2(-1400, 0))
    var y := g.create_node(VoxelGraphFunction.NODE_INPUT_Y, Vector2(-1400, 120))
    var z := g.create_node(VoxelGraphFunction.NODE_INPUT_Z, Vector2(-1400, 240))

    # Terrain: y - (6 + 12*low_frequency_noise(x,z) + 3*detail_noise(x,z)).
    # World and noise are seed-locked; no RNG consumption per generated chunk.
    var broad := _noise_2d(g, x, z, seed_value, 140.0, 3, Vector2(-1120, -220))
    var detail := _noise_2d(g, x, z, seed_value + 101, 38.0, 2, Vector2(-1120, -40))
    var broad_height := _offset(g, VoxelGraphFunction.NODE_MULTIPLY, broad, 12.0, Vector2(-880, -220))
    var detail_height := _offset(g, VoxelGraphFunction.NODE_MULTIPLY, detail, 3.0, Vector2(-880, -40))
    var height_noise := _binary(g, VoxelGraphFunction.NODE_ADD, broad_height, detail_height, Vector2(-660, -120))
    var height := _offset(g, VoxelGraphFunction.NODE_ADD, height_noise, 6.0, Vector2(-460, -120))
    var terrain_sdf := _binary(g, VoxelGraphFunction.NODE_SUBTRACT, y, height, Vector2(-240, -120))

    # A traversable winding tunnel along X at approximately y=-11, radius 4.6.
    # Only a graph primitive is used: maximum(ground_sdf, 4.6-distance_to_axis).
    # A vertical entrance near (x=38,z=0) connects the tunnel to the surface.
    var warp := _noise_2d(g, x, z, seed_value + 503, 96.0, 2, Vector2(-1120, 450))
    var warp_z := _offset(g, VoxelGraphFunction.NODE_MULTIPLY, warp, 2.0, Vector2(-880, 440))
    var shifted_z := _binary(g, VoxelGraphFunction.NODE_ADD, z, warp_z, Vector2(-660, 440))
    var depth := _offset(g, VoxelGraphFunction.NODE_ADD, y, 11.0, Vector2(-880, 260))
    var depth_sq := _square(g, depth, Vector2(-660, 250))
    var warped_z_sq := _square(g, shifted_z, Vector2(-460, 440))
    var tunnel_sq := _binary(g, VoxelGraphFunction.NODE_ADD, depth_sq, warped_z_sq, Vector2(-260, 300))
    var tunnel_dist := _unary(g, VoxelGraphFunction.NODE_SQRT, tunnel_sq, Vector2(-50, 300))
    var tunnel_air := _constant_minus(g, 4.6, tunnel_dist, Vector2(140, 300))

    var shaft_x := _offset(g, VoxelGraphFunction.NODE_SUBTRACT, x, 38.0, Vector2(-880, 670))
    var shaft_x_sq := _square(g, shaft_x, Vector2(-660, 670))
    var shaft_z_sq := _square(g, z, Vector2(-660, 830))
    var shaft_sq := _binary(g, VoxelGraphFunction.NODE_ADD, shaft_x_sq, shaft_z_sq, Vector2(-460, 690))
    var shaft_dist := _unary(g, VoxelGraphFunction.NODE_SQRT, shaft_sq, Vector2(-260, 690))
    var shaft_air := _constant_minus(g, 4.8, shaft_dist, Vector2(-50, 690))

    var terrain_and_tunnel := _binary(g, VoxelGraphFunction.NODE_MAX, terrain_sdf, tunnel_air, Vector2(350, 150))
    var full_sdf := _binary(g, VoxelGraphFunction.NODE_MAX, terrain_and_tunnel, shaft_air, Vector2(550, 200))
    var output := g.create_node(VoxelGraphFunction.NODE_OUTPUT_SDF, Vector2(760, 200))
    g.add_connection(full_sdf, 0, output, 0)
    var status: Dictionary = result.compile()
    if not status.get("success", false):
        push_error("A1_GRAPH_FAIL: " + str(status))
        return null
    return result
