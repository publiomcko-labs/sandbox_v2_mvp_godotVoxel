extends SceneTree
const REMOVE := Vector3(8,-4,15)
const ADD := Vector3(15,26,15)
const KEEP := Vector3i(12,-4,15)
const RADIUS := 4.0

func _initialize() -> void:
    call_deferred("_test")

func _fail(reason: String) -> void:
    push_error("V3_GEOLOGY_FAIL: " + reason)
    quit(1)

func _sample(generator: VoxelGeneratorGraph, origin: Vector3i, lod: int) -> VoxelBuffer:
    var buffer := VoxelBuffer.new()
    buffer.set_channel_depth(VoxelBuffer.CHANNEL_INDICES,VoxelBuffer.DEPTH_8_BIT)
    buffer.create(16,16,16)
    generator.generate_block(buffer,Vector3(origin),lod)
    return buffer

func _test() -> void:
    var write := "--phase=write" in OS.get_cmdline_user_args()
    var scene: PackedScene = load("res://scenes/v3_geology_main.tscn")
    var runtime = scene.instantiate()
    root.add_child(runtime)
    if not runtime.running:
        _fail("runtime start")
        return
    var world: WorldBootstrap = runtime.world
    var terrain: VoxelLodTerrain = runtime.terrain
    if terrain.format.indices_depth != VoxelBuffer.DEPTH_8_BIT or terrain.mesher.texturing_mode != VoxelMesherTransvoxel.TEXTURES_SINGLE_S4:
        _fail("native material encoding")
        return
    if runtime.geology_config["palette"].size() != 6 or not runtime.select_material(5):
        _fail("palette selection")
        return
    var generator := terrain.generator as VoxelGeneratorGraph
    if generator == null:
        _fail("native graph")
        return
    if write:
        var found: Dictionary = {}
        for origin_x in [-160,-64,0,64,160]:
            for origin_y in [-80,-48,-32,-16,0]:
                var origin := Vector3i(origin_x,origin_y,16)
                var a := _sample(generator,origin,0)
                var b := _sample(generator,origin,1)
                for z in range(0,16,2):
                    for x in range(0,16,2):
                        for y in range(0,16,2):
                            if a.get_voxel_f(x,y,z,VoxelBuffer.CHANNEL_SDF) < -0.2:
                                var slot := a.get_voxel(x,y,z,VoxelBuffer.CHANNEL_INDICES)
                                if slot < 0 or slot > 5:
                                    _fail("material slot out of range")
                                    return
                                found[slot] = true
                                if b.get_voxel_f(x/2,y/2,z/2,VoxelBuffer.CHANNEL_SDF) < -0.2 and b.get_voxel(x/2,y/2,z/2,VoxelBuffer.CHANNEL_INDICES) != slot:
                                    _fail("aligned LOD material mismatch")
                                    return
        if found.size() != 6:
            _fail("insufficient material distribution: " + str(found))
            return
        print("V3_GEOLOGY_GENERATION_PASS observed_slots=", found.keys(), " aligned_lod=0/1")
    runtime.player.set_process(false)
    runtime.player.set_physics_process(false)
    runtime.player.global_position = Vector3(10,12,15)
    var deadline := Time.get_ticks_msec()+60000
    while not (world.can_edit_sphere(REMOVE,RADIUS) and world.can_edit_sphere(ADD,RADIUS)):
        if Time.get_ticks_msec()>deadline:
            _fail("editable timeout")
            return
        await process_frame
    var tool := terrain.get_voxel_tool()
    if write:
        tool.channel = VoxelBuffer.CHANNEL_INDICES
        var before := tool.get_voxel(KEEP)
        var carved_material := tool.get_voxel(Vector3i(REMOVE))
        tool.channel = VoxelBuffer.CHANNEL_SDF
        if tool.get_voxel_f(Vector3i(REMOVE)) >= -0.2 or tool.get_voxel_f(Vector3i(ADD)) <= 0.2:
            _fail("baseline SDF")
            return
        if runtime.session.submit_material(world,1,ADD,true,RADIUS,"earth:invalid") != "rejected":
            _fail("invalid material accepted")
            return
        if runtime.submit_brush(REMOVE,false,RADIUS) != "accepted" or runtime.submit_brush(ADD,true,RADIUS) != "accepted":
            _fail("material-aware brush")
            return
        tool.channel = VoxelBuffer.CHANNEL_INDICES
        if tool.get_voxel(KEEP) != before or tool.get_voxel(Vector3i(REMOVE)) != carved_material:
            _fail("carving repainted existing material")
            return
    else:
        if runtime.session.get_state().get("terrain_revision") != 2:
            _fail("reopen revision")
            return
    tool.channel = VoxelBuffer.CHANNEL_SDF
    if tool.get_voxel_f(Vector3i(REMOVE)) <= 0.2 or tool.get_voxel_f(Vector3i(ADD)) >= -0.2:
        _fail("edited SDF")
        return
    tool.channel = VoxelBuffer.CHANNEL_INDICES
    if tool.get_voxel(Vector3i(ADD)) != 5:
        _fail("selected basalt not present in stored voxel")
        return
    tool.channel = VoxelBuffer.CHANNEL_SDF
    print("V3_GEOLOGY_FIXTURE_PASS phase=", "write" if write else "reopen", " material=earth:basalt")
    runtime.request_close()
