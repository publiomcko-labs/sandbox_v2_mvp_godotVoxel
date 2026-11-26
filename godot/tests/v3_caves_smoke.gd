extends SceneTree
const TERRAIN_SCRIPT := preload("res://scripts/terrain_sdf.gd")
const SIZE := 80
const STEP := 2
const ORIGIN := Vector3i(-80,-128,-80)
const ADD := Vector3(15,26,15)
const RADIUS := 4.0
const DIRECTIONS := [Vector3i(1,0,0),Vector3i(-1,0,0),Vector3i(0,1,0),Vector3i(0,-1,0),Vector3i(0,0,1),Vector3i(0,0,-1)]

func _initialize() -> void:
    call_deferred("_test")

func _fail(reason: String) -> void:
    push_error("V3_CAVES_FAIL: " + reason)
    quit(1)

func _index(x: int,y: int,z: int) -> int:
    return (z*SIZE+y)*SIZE+x

func _point(i: int) -> Vector3i:
    @warning_ignore("integer_division")
    return Vector3i(i%SIZE,(i/SIZE)%SIZE,i/(SIZE*SIZE))

func _world(p: Vector3i) -> Vector3i:
    return ORIGIN+p*STEP

func _buffer() -> VoxelBuffer:
    var b := VoxelBuffer.new()
    b.set_channel_depth(VoxelBuffer.CHANNEL_INDICES,VoxelBuffer.DEPTH_8_BIT)
    b.create(16,16,16)
    return b

func _noise(seed_value: int,period: float,octaves: int) -> ZN_FastNoiseLite:
    var n := ZN_FastNoiseLite.new()
    n.seed=seed_value
    n.period=period
    n.fractal_type=ZN_FastNoiseLite.FRACTAL_FBM
    n.fractal_octaves=octaves
    return n

func _topology(generator: VoxelGeneratorGraph, seed_value: int, config: Dictionary) -> Dictionary:
    # Bounded 160m x 160m x 160m grid, 2m sampling; not world-global topology.
    var broad := _noise(seed_value,140.0,3)
    var detail := _noise(seed_value+101,38.0,2)
    var heights := PackedFloat32Array()
    heights.resize(SIZE*SIZE)
    for z in range(SIZE):
        for x in range(SIZE):
            var p := _world(Vector3i(x,0,z))
            heights[z*SIZE+x]=6.0+12.0*broad.get_noise_2d(p.x,p.z)+3.0*detail.get_noise_2d(p.x,p.z)
    var field := PackedByteArray()
    field.resize(SIZE*SIZE*SIZE)
    # 0 solid/outside, 1 cave air, 2 mouth sample, 3 deep pocket air.
    var air_count := 0
    var mouth_count := 0
    var pocket_count := 0
    var solid_count := 0
    var buffer := _buffer()
    for bz in range(0,SIZE,16):
        for by in range(0,SIZE,16):
            for bx in range(0,SIZE,16):
                generator.generate_block(buffer,Vector3(_world(Vector3i(bx,by,bz))),1)
                for z in range(16):
                    for y in range(16):
                        for x in range(16):
                            var gx: int=bx+x
                            var gy: int=by+y
                            var gz: int=bz+z
                            var depth: float=heights[gz*SIZE+gx]-float(ORIGIN.y+gy*STEP)
                            if depth<0.1:
                                continue
                            var sdf := buffer.get_voxel_f(x,y,z,VoxelBuffer.CHANNEL_SDF)
                            if sdf<=0.25:
                                solid_count+=1
                                continue
                            air_count+=1
                            var kind := 1
                            if depth<=2.5:
                                kind=2
                                mouth_count+=1
                            elif depth>=float(config["max_depth_m"])*0.62+5.9:
                                kind=3
                                pocket_count+=1
                            field[_index(gx,gy,gz)]=kind
    var seen := PackedByteArray()
    seen.resize(field.size())
    var max_connected := 0
    var isolated := 0
    var connected_mouths := 0
    var junction_samples := 0
    var chamber_samples := 0
    var spawn := Vector3i.ZERO
    var route_end := Vector3i.ZERO
    var deepest_connected := 0.0
    var largest_pocket := 0
    var air_ratio := float(air_count)/float(maxi(1,air_count+solid_count))
    for start in range(field.size()):
        if field[start]==0 or seen[start]!=0:
            continue
        var queue := PackedInt32Array([start])
        seen[start]=1
        var head := 0
        var mouths := 0
        var branches := 0
        var chambers := 0
        var touches_boundary := false
        var is_pocket := true
        var candidate_spawn := Vector3i.ZERO
        var candidate_end := Vector3i.ZERO
        var depth_max := 0.0
        while head<queue.size():
            var index := queue[head]
            head+=1
            var p := _point(index)
            var kind := field[index]
            if kind!=3:
                is_pocket=false
            if kind==2:
                mouths+=1
                candidate_spawn=_world(p)
            var depth: float=heights[p.z*SIZE+p.x]-float(ORIGIN.y+p.y*STEP)
            if depth>depth_max:
                depth_max=depth
                candidate_end=_world(p)
            if p.x==0 or p.x==SIZE-1 or p.y==0 or p.y==SIZE-1 or p.z==0 or p.z==SIZE-1:
                touches_boundary=true
            var degree := 0
            var clearance := true
            for d: Vector3i in DIRECTIONS:
                var n := p+d
                if n.x<0 or n.y<0 or n.z<0 or n.x>=SIZE or n.y>=SIZE or n.z>=SIZE:
                    clearance=false
                    continue
                var ni := _index(n.x,n.y,n.z)
                if field[ni]==0:
                    clearance=false
                    continue
                degree+=1
                if seen[ni]==0:
                    seen[ni]=1
                    queue.append(ni)
                var far := p+d*2
                if far.x<0 or far.y<0 or far.z<0 or far.x>=SIZE or far.y>=SIZE or far.z>=SIZE:
                    clearance=false
                elif field[_index(far.x,far.y,far.z)]==0:
                    clearance=false
            if degree>=4:
                branches+=1
            # Axial clearance of 4m on the sampled grid (not collision proof).
            if clearance:
                chambers+=1
        if mouths>0 and queue.size()>max_connected:
            max_connected=queue.size()
            connected_mouths=mouths
            junction_samples=branches
            chamber_samples=chambers
            spawn=candidate_spawn
            route_end=candidate_end
            deepest_connected=depth_max
        if is_pocket and not touches_boundary and queue.size()>=8:
            isolated+=1
            largest_pocket=maxi(largest_pocket,queue.size())
    return {"air_samples":air_count,"air_ratio":air_ratio,"mouth_samples":mouth_count,
        "deep_pocket_samples":pocket_count,"connected_samples":max_connected,"connected_mouths":connected_mouths,
        "junction_samples":junction_samples,"chamber_clearance_samples":chamber_samples,
        "isolated_pockets":isolated,"largest_pocket_samples":largest_pocket,
        "connected_depth_m":deepest_connected,"entrance_xyz":[spawn.x,spawn.y,spawn.z],
        "connected_deep_xyz":[route_end.x,route_end.y,route_end.z]}

func _alignment(generator: VoxelGeneratorGraph) -> bool:
    var a := _buffer()
    var b := _buffer()
    var c := _buffer()
    for origin: Vector3 in [Vector3(-32,-32,-32),Vector3(0,-64,0),Vector3(32,-16,32),Vector3(-16,-96,16)]:
        generator.generate_block(a,origin,0)
        generator.generate_block(b,origin,1)
        generator.generate_block(c,origin+Vector3(16,0,0),0)
        generator.generate_block(c,origin,0)
        for z in range(0,16,2):
            for y in range(0,16,2):
                for x in range(0,16,2):
                    var sa := a.get_voxel_f(x,y,z,VoxelBuffer.CHANNEL_SDF)
                    var sb := b.get_voxel_f(x/2,y/2,z/2,VoxelBuffer.CHANNEL_SDF)
                    if a.get_voxel(x,y,z,VoxelBuffer.CHANNEL_SDF)!=c.get_voxel(x,y,z,VoxelBuffer.CHANNEL_SDF):
                        return false
                    if absf(sa)>0.2 and absf(sb)>0.2 and signf(sa)!=signf(sb):
                        return false
                    if sa< -0.2 and sb< -0.2 and a.get_voxel(x,y,z,VoxelBuffer.CHANNEL_INDICES)!=b.get_voxel(x/2,y/2,z/2,VoxelBuffer.CHANNEL_INDICES):
                        return false
    return true

func _cost(generator: VoxelGeneratorGraph, material: bool) -> float:
    var b := _buffer() if material else VoxelBuffer.new()
    if not material:
        b.create(16,16,16)
    var locations: Array[Vector3] = []
    for i in range(24):
        locations.append(Vector3((i%6)*16-48,-16*(i%4),((i*7)%9)*16-64))
    for p in locations:
        generator.generate_block(b,p,0)
    var start := Time.get_ticks_usec()
    for i in range(3):
        for p in locations:
            generator.generate_block(b,p,0)
    return float(Time.get_ticks_usec()-start)/float(locations.size()*3)

func _test() -> void:
    var write := "--phase=write" in OS.get_cmdline_user_args()
    var scene: PackedScene=load("res://scenes/v3_caves_main.tscn")
    var runtime=scene.instantiate()
    root.add_child(runtime)
    if not runtime.running:
        _fail("runtime start")
        return
    var world: WorldBootstrap=runtime.world
    var terrain: VoxelLodTerrain=runtime.terrain
    var generator:=terrain.generator as VoxelGeneratorGraph
    var seed_value:=int(terrain.get("world_seed"))
    if generator==null or runtime.cave_config.is_empty():
        _fail("cave graph or profile missing")
        return
    if write:
        var topology:=_topology(generator,seed_value,runtime.cave_config)
        print("V3_CAVES_TOPOLOGY seed=",seed_value," profile=",runtime.cave_config["id"]," ",JSON.stringify(topology))
        if topology["mouth_samples"]<4 or topology["connected_samples"]<100 or topology["connected_depth_m"]<16.0 or topology["junction_samples"]<10 or topology["chamber_clearance_samples"]<1 or topology["isolated_pockets"]<1 or topology["air_ratio"]>0.65:
            _fail("sampled topology requirements")
            return
        if not _alignment(generator):
            _fail("determinism or aligned LOD samples")
            return
        var a5:=TERRAIN_SCRIPT.build_generator(seed_value)
        var v32:=TERRAIN_SCRIPT.build_generator(seed_value,runtime.geology_config)
        if a5==null or v32==null:
            _fail("baseline graph")
            return
        var a5_us:=_cost(a5,false)
        var v32_us:=_cost(v32,true)
        var v33_us:=_cost(generator,true)
        print("V3_CAVES_COST seed=",seed_value," ",JSON.stringify({"a5_us_block":a5_us,"v32_us_block":v32_us,"v33_us_block":v33_us,"ratio_a5":v33_us/maxf(a5_us,0.001),"ratio_v32":v33_us/maxf(v32_us,0.001),"blocks_per_arm":72,"lod":0}))
    runtime.player.set_process(false)
    runtime.player.set_physics_process(false)
    runtime.player.global_position=Vector3(10,12,15)
    var deadline:=Time.get_ticks_msec()+60000
    while not world.can_edit_sphere(ADD,RADIUS):
        if Time.get_ticks_msec()>deadline:
            _fail("editable timeout")
            return
        await process_frame
    var tool:=terrain.get_voxel_tool()
    if write:
        if not runtime.select_material(5) or runtime.submit_brush(ADD,true,RADIUS)!="accepted":
            _fail("material construction")
            return
    elif runtime.session.get_state().get("terrain_revision")!=1:
        _fail("checkpoint counters")
        return
    tool.channel=VoxelBuffer.CHANNEL_SDF
    if tool.get_voxel_f(Vector3i(ADD))>= -0.2:
        _fail("edited SDF")
        return
    tool.channel=VoxelBuffer.CHANNEL_INDICES
    if tool.get_voxel(Vector3i(ADD))!=5:
        _fail("persisted material")
        return
    tool.channel=VoxelBuffer.CHANNEL_SDF
    print("V3_CAVES_FIXTURE_PASS phase=","write" if write else "reopen"," seed=",seed_value)
    runtime.request_close()
