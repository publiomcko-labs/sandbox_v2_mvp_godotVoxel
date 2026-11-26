extends VoxelLodTerrain
# A1: deterministic volumetric SDF. This configures the Voxel Tools graph before
# the terrain node enters the streaming lifecycle; no custom region manager.
@export var world_seed: int = 20261119
var graph_ready: bool = false
var geology_config: Dictionary = {} # Empty preserves the A5/V3.1 path.
var cave_config: Dictionary = {}

func _enter_tree() -> void:
    if not geology_config.is_empty():
        var voxel_format := VoxelFormat.new()
        voxel_format.indices_depth = VoxelBuffer.DEPTH_8_BIT
        format = voxel_format
        var transvoxel := VoxelMesherTransvoxel.new()
        transvoxel.texturing_mode = VoxelMesherTransvoxel.TEXTURES_SINGLE_S4
        transvoxel.textures_ignore_air_voxels = true
        mesher = transvoxel
        var surface := ShaderMaterial.new()
        surface.shader = preload("res://shaders/v3_geology.gdshader")
        var materials: Array = geology_config["materials"]
        for i in range(materials.size()):
            var data: Dictionary = materials[i]["data"]
            var rgb: Array = data["albedo"]
            surface.set_shader_parameter("u_geo_mat%d" % i, Color(float(rgb[0]),float(rgb[1]),float(rgb[2]),float(data["roughness"])))
        material = surface
    var sdf_graph := build_generator(world_seed, geology_config, cave_config)
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

static func build_generator(seed_value: int, geology: Dictionary = {}, caves: Dictionary = {}) -> VoxelGeneratorGraph:
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

    var full_sdf: int
    if caves.is_empty():
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
        full_sdf = _binary(g, VoxelGraphFunction.NODE_MAX, terrain_and_tunnel, shaft_air, Vector2(550, 200))
    else:
        full_sdf = _add_caves(g, caves, x, y, z, terrain_sdf)
    var output := g.create_node(VoxelGraphFunction.NODE_OUTPUT_SDF, Vector2(760, 200))
    g.add_connection(full_sdf, 0, output, 0)
    if not geology.is_empty():
        result.texture_mode = VoxelGeneratorGraph.TEXTURE_MODE_SINGLE
        _add_geology(g, seed_value, geology, x, y, z, height, terrain_sdf, broad)
    var status: Dictionary = result.compile()
    if not status.get("success", false):
        push_error("A1_GRAPH_FAIL: " + str(status))
        return null
    return result

# The graph is evaluated natively on Voxel Tools workers. Geology is based on
# the uncarved surface SDF, so tunnel walls expose material at their true depth.
static func _const(g: VoxelGraphFunction, value: float) -> int:
    var n := g.create_node(VoxelGraphFunction.NODE_CONSTANT, Vector2(0,0))
    g.set_node_param_by_name(n, "value", value)
    return n

static func _select(g: VoxelGraphFunction, a: int, b: int, t: int, threshold: float) -> int:
    var n := g.create_node(VoxelGraphFunction.NODE_SELECT, Vector2(0,0))
    g.set_node_param_by_name(n, "threshold", threshold)
    g.add_connection(a, 0, n, 0)
    g.add_connection(b, 0, n, 1)
    g.add_connection(t, 0, n, 2)
    return n

static func _height_sample(g: VoxelGraphFunction, x: int, z: int, seed_value: int) -> int:
    var broad := _noise_2d(g,x,z,seed_value,140.0,3,Vector2.ZERO)
    var detail := _noise_2d(g,x,z,seed_value+101,38.0,2,Vector2.ZERO)
    var b := _offset(g,VoxelGraphFunction.NODE_MULTIPLY,broad,12.0,Vector2.ZERO)
    var d := _offset(g,VoxelGraphFunction.NODE_MULTIPLY,detail,3.0,Vector2.ZERO)
    return _offset(g,VoxelGraphFunction.NODE_ADD,_binary(g,VoxelGraphFunction.NODE_ADD,b,d,Vector2.ZERO),6.0,Vector2.ZERO)

static func _add_geology(g: VoxelGraphFunction, seed_value: int, cfg: Dictionary, x: int, _y: int,
        z: int, height: int, terrain_sdf: int, broad: int) -> void:
    var slots: Array[int] = []
    for i in range(6):
        slots.append(_const(g,float(i)))
    var depth := _offset(g,VoxelGraphFunction.NODE_MULTIPLY,terrain_sdf,-1.0,Vector2.ZERO)
    # Variable strata use a second continuous noise field, distinct from height.
    var layer_noise := _noise_2d(g,x,z,seed_value+1709,76.0,2,Vector2.ZERO)
    var variation := _offset(g,VoxelGraphFunction.NODE_MULTIPLY,layer_noise,float(cfg["variation_m"]),Vector2.ZERO)
    var varied_depth := _binary(g,VoxelGraphFunction.NODE_ADD,depth,variation,Vector2.ZERO)
    var x_next := _offset(g,VoxelGraphFunction.NODE_ADD,x,2.0,Vector2.ZERO)
    var z_next := _offset(g,VoxelGraphFunction.NODE_ADD,z,2.0,Vector2.ZERO)
    var dx := _binary(g,VoxelGraphFunction.NODE_SUBTRACT,_height_sample(g,x_next,z,seed_value),height,Vector2.ZERO)
    var dz := _binary(g,VoxelGraphFunction.NODE_SUBTRACT,_height_sample(g,x,z_next,seed_value),height,Vector2.ZERO)
    var gradient_sq := _binary(g,VoxelGraphFunction.NODE_ADD,_square(g,dx,Vector2.ZERO),_square(g,dz,Vector2.ZERO),Vector2.ZERO)
    var gradient := _offset(g,VoxelGraphFunction.NODE_MULTIPLY,_unary(g,VoxelGraphFunction.NODE_SQRT,gradient_sq,Vector2.ZERO),0.5,Vector2.ZERO)
    # Low altitude sand, steep exposed limestone, otherwise shallow grass/soil.
    var exposed := _select(g,slots[0],slots[3],gradient,float(cfg["slope_limit"]))
    var top := _select(g,slots[2],exposed,height,float(cfg["sand_height_m"]))
    var shallow := _select(g,top,slots[1],depth,float(cfg["grass_depth_m"]))
    # Limestone above granite, occasional basalt intrusions at intermediate
    # depth, and basalt at depth. No dependence on visit order or shader height.
    var rock := _select(g,slots[3],slots[4],broad,0.15)
    var middle := _select(g,rock,slots[4],varied_depth,float(cfg["bedrock_depth_m"]))
    var deep := _select(g,middle,slots[5],varied_depth,float(cfg["deep_depth_m"]))
    var index := _select(g,shallow,deep,varied_depth,float(cfg["soil_depth_m"]))
    var output := g.create_node(VoxelGraphFunction.NODE_OUTPUT_SINGLE_TEXTURE,Vector2(1000,450))
    g.add_connection(index,0,output,0)

# All functions below build graph nodes once. The native worker evaluates
# the same global-coordinate field independently for every block and LOD.
static func _noise_3d(g: VoxelGraphFunction, x: int, y: int, z: int, seed_value: int, period: float, octaves: int) -> int:
    var cfg := ZN_FastNoiseLite.new()
    cfg.seed = seed_value
    cfg.period = period
    cfg.fractal_type = ZN_FastNoiseLite.FRACTAL_FBM
    cfg.fractal_octaves = octaves
    var n := g.create_node(VoxelGraphFunction.NODE_FAST_NOISE_3D,Vector2.ZERO)
    g.set_node_param_by_name(n,"noise",cfg)
    g.add_connection(x,0,n,0)
    g.add_connection(y,0,n,1)
    g.add_connection(z,0,n,2)
    return n

static func _abs_scaled(g: VoxelGraphFunction, n: int, scale: float) -> int:
    return _offset(g,VoxelGraphFunction.NODE_MULTIPLY,_unary(g,VoxelGraphFunction.NODE_ABS,n,Vector2.ZERO),scale,Vector2.ZERO)

static func _length3(g: VoxelGraphFunction, a: int, b: int, c: int) -> int:
    var sum := _binary(g,VoxelGraphFunction.NODE_ADD,_square(g,a,Vector2.ZERO),_square(g,b,Vector2.ZERO),Vector2.ZERO)
    sum = _binary(g,VoxelGraphFunction.NODE_ADD,sum,_square(g,c,Vector2.ZERO),Vector2.ZERO)
    return _unary(g,VoxelGraphFunction.NODE_SQRT,sum,Vector2.ZERO)

static func _pocket_axis(g: VoxelGraphFunction, axis: int, period: float) -> int:
    # Periodic cells with solid walls; no per-cell RNG and no topology cache.
    var wrapped := _offset(g,VoxelGraphFunction.NODE_WRAP,axis,period,Vector2.ZERO)
    return _offset(g,VoxelGraphFunction.NODE_SUBTRACT,wrapped,period*0.5,Vector2.ZERO)

static func _add_caves(g: VoxelGraphFunction, cfg: Dictionary, x: int, y: int, z: int, ground: int) -> int:
    var seeds: Array = cfg["noise_seeds"]
    var period := float(cfg["period_m"])
    var radius := float(cfg["radius_m"])
    var max_depth := float(cfg["max_depth_m"])
    var a := _abs_scaled(g,_noise_3d(g,x,y,z,int(seeds[0]),period,2),period*0.45)
    var b := _abs_scaled(g,_noise_3d(g,x,y,z,int(seeds[1]),period*0.87,2),period*0.45)
    var c := _abs_scaled(g,_noise_3d(g,x,y,z,int(seeds[2]),period*1.13,2),period*0.45)
    # Intersections of three warped scalar sheets produce three families of
    # winding passages; shared intersections create connected junctions.
    var ab := _binary(g,VoxelGraphFunction.NODE_MAX,a,b,Vector2.ZERO)
    var ac := _binary(g,VoxelGraphFunction.NODE_MAX,a,c,Vector2.ZERO)
    var bc := _binary(g,VoxelGraphFunction.NODE_MAX,b,c,Vector2.ZERO)
    var tubes := _binary(g,VoxelGraphFunction.NODE_MIN,ab,_binary(g,VoxelGraphFunction.NODE_MIN,ac,bc,Vector2.ZERO),Vector2.ZERO)
    var network := _constant_minus(g,radius,tubes,Vector2.ZERO)
    var chamber := _constant_minus(g,float(cfg["chamber_radius_m"]),_length3(g,a,b,c),Vector2.ZERO)
    network = _binary(g,VoxelGraphFunction.NODE_MAX,network,chamber,Vector2.ZERO)
    var depth := _offset(g,VoxelGraphFunction.NODE_MULTIPLY,ground,-1.0,Vector2.ZERO)
    # Protect the original landscape: no network or chamber may reach the
    # shallow roof. Only narrow, independently spaced entrance shafts can.
    var roof := _offset(g,VoxelGraphFunction.NODE_SUBTRACT,depth,float(cfg["entrance_cover_m"]),Vector2.ZERO)
    var deep_gate := _constant_minus(g,max_depth*0.62,depth,Vector2.ZERO)
    network = _binary(g,VoxelGraphFunction.NODE_MIN,network,roof,Vector2.ZERO)
    network = _binary(g,VoxelGraphFunction.NODE_MIN,network,deep_gate,Vector2.ZERO)

    # Sparse, tilted entrances with globally continuous lateral jitter.
    # Cell boundaries remain solid; their wrapped coordinates are never
    # discontinuous in the region where the entrance SDF is positive.
    var spacing := float(cfg["entrance_period_m"])
    var jitter := float(cfg["entrance_jitter_m"])
    var jitter_x := _offset(g,VoxelGraphFunction.NODE_MULTIPLY,_noise_2d(g,x,z,int(seeds[3]),spacing*1.3,2,Vector2.ZERO),jitter,Vector2.ZERO)
    var jitter_z := _offset(g,VoxelGraphFunction.NODE_MULTIPLY,_noise_2d(g,x,z,int(seeds[5]),spacing*1.3,2,Vector2.ZERO),jitter,Vector2.ZERO)
    var descent := _offset(g,VoxelGraphFunction.NODE_MAX,depth,0.0,Vector2.ZERO)
    var lean_x := _offset(g,VoxelGraphFunction.NODE_MULTIPLY,descent,0.28,Vector2.ZERO)
    var lean_z := _offset(g,VoxelGraphFunction.NODE_MULTIPLY,descent,-0.17,Vector2.ZERO)
    var shifted_x := _binary(g,VoxelGraphFunction.NODE_ADD,_binary(g,VoxelGraphFunction.NODE_ADD,x,jitter_x,Vector2.ZERO),lean_x,Vector2.ZERO)
    var shifted_z := _binary(g,VoxelGraphFunction.NODE_ADD,_binary(g,VoxelGraphFunction.NODE_ADD,z,jitter_z,Vector2.ZERO),lean_z,Vector2.ZERO)
    var ex := _pocket_axis(g,shifted_x,spacing)
    var ez := _pocket_axis(g,shifted_z,spacing)
    var radial_sq := _binary(g,VoxelGraphFunction.NODE_ADD,_square(g,ex,Vector2.ZERO),_square(g,ez,Vector2.ZERO),Vector2.ZERO)
    var radial := _unary(g,VoxelGraphFunction.NODE_SQRT,radial_sq,Vector2.ZERO)
    # Tight mouths widen gradually in the first 12 m of descent.
    var widen := _offset(g,VoxelGraphFunction.NODE_MIN,descent,12.0,Vector2.ZERO)
    widen = _offset(g,VoxelGraphFunction.NODE_MULTIPLY,widen,0.15,Vector2.ZERO)
    var entrance_radius := _offset(g,VoxelGraphFunction.NODE_ADD,widen,float(cfg["entrance_radius_m"]),Vector2.ZERO)
    var shaft := _binary(g,VoxelGraphFunction.NODE_SUBTRACT,entrance_radius,radial,Vector2.ZERO)
    shaft = _binary(g,VoxelGraphFunction.NODE_MIN,shaft,_constant_minus(g,float(cfg["entrance_depth_m"]),depth,Vector2.ZERO),Vector2.ZERO)
    network = _binary(g,VoxelGraphFunction.NODE_MAX,network,shaft,Vector2.ZERO)
    # Isolated deep pockets. A guaranteed solid depth band separates them
    # from the network. Bounded radial perturbation preserves cell walls.
    var pocket_period := float(cfg["pocket_period_m"])
    var px := _pocket_axis(g,x,pocket_period)
    var py := _pocket_axis(g,y,pocket_period)
    var pz := _pocket_axis(g,z,pocket_period)
    var pocket := _constant_minus(g,float(cfg["pocket_radius_m"]),_length3(g,px,py,pz),Vector2.ZERO)
    var warp := _noise_3d(g,x,y,z,int(seeds[4]),pocket_period*0.65,2)
    warp = _offset(g,VoxelGraphFunction.NODE_MULTIPLY,warp,float(cfg["pocket_warp_m"]),Vector2.ZERO)
    pocket = _binary(g,VoxelGraphFunction.NODE_ADD,pocket,warp,Vector2.ZERO)
    pocket = _binary(g,VoxelGraphFunction.NODE_MIN,pocket,_offset(g,VoxelGraphFunction.NODE_SUBTRACT,depth,max_depth*0.62+6.0,Vector2.ZERO),Vector2.ZERO)
    pocket = _binary(g,VoxelGraphFunction.NODE_MIN,pocket,_constant_minus(g,max_depth,depth,Vector2.ZERO),Vector2.ZERO)
    var air := _binary(g,VoxelGraphFunction.NODE_MAX,network,pocket,Vector2.ZERO)
    return _binary(g,VoxelGraphFunction.NODE_MAX,ground,air,Vector2.ZERO)
