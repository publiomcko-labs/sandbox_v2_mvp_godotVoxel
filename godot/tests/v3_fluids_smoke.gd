extends SceneTree
const RADIUS := 3.0

func _initialize() -> void:
    call_deferred("_test")
func _fail(reason: String) -> void:
    push_error("V3_FLUID_RUNTIME_FAIL: "+reason)
    quit(1)

func _test() -> void:
    var write: bool="--phase=write" in OS.get_cmdline_user_args()
    var scene: PackedScene=load("res://scenes/v3_fluids_main.tscn")
    var runtime=scene.instantiate()
    root.add_child(runtime)
    if not runtime.running:
        _fail("runtime start")
        return
    runtime.set_process(false)
    runtime.player.set_process(false)
    runtime.player.set_physics_process(false)
    var water: Node3D=runtime.world.get_node("Water")
    water.set_process(false)
    water.set_physics_process(false)
    runtime.player.global_position=Vector3(10,12,15)
    var deadline:=Time.get_ticks_msec()+60000
    while runtime.session.get_seeded_reservoirs().size()<3:
        water.call("prepare_sources")
        if Time.get_ticks_msec()>deadline:
            _fail("source readiness "+str(runtime.session.get_seeded_reservoirs()))
            return
        await process_frame
    var state: Dictionary=runtime.session.get_state()
    var volume:=int(state["fluid_litres"])
    if volume<=0 or volume!=int(state["fluid_initial_litres"]):
        _fail("initial mass")
        return
    var dry:=Vector3(10,-30,15)
    if not runtime.session.fluid_at(dry).is_empty() or float(water.call("immersion_at",dry,1.7))!=0:
        _fail("global underwater mask")
        return
    var wet: Array=runtime.session.fluid_cells(Vector3(-64,-32,-64),Vector3(64,32,64))
    var slots: Dictionary={}
    for row: Array in wet:
        slots[row[1]]=true
    if slots.size()!=2 or wet.is_empty():
        _fail("water and lava not present")
        return
    var row: Array=wet[0]
    var point:=Vector3(row[0])+Vector3(0.5,0.1,0.5)
    if runtime.session.fluid_at(point).is_empty():
        _fail("wet occupancy")
        return
    if write:
        if runtime.submit_brush(point,true,RADIUS)!="rejected":
            _fail("wet construction not rejected")
            return
        while not runtime.world.can_edit_sphere(dry,RADIUS):
            if Time.get_ticks_msec()>deadline:
                _fail("dry edit readiness")
                return
            await process_frame
        if runtime.submit_brush(dry,false,RADIUS)!="accepted":
            _fail("dry excavation")
            return
        if not runtime.session.fluid_at(dry).is_empty():
            _fail("instant water in excavation")
            return
        # Select a genuinely wet bottom cell of the nearby water reservoir.
        # Two cells directly below must be dry and blocked by the real SDF.
        var tool: VoxelTool=runtime.terrain.get_voxel_tool()
        tool.channel=VoxelBuffer.CHANNEL_SDF
        var chosen:=false
        var bottom:=Vector3i.ZERO
        var cut:=Vector3.ZERO
        var water_slot: int=-1
        var config: Dictionary=water.get("config")
        var liquids: Array=config["liquids"]
        for i in range(liquids.size()):
            if liquids[i]["id"]=="hydro:water":
                water_slot=i
                if int(liquids[i]["substeps"])!=5:
                    _fail("water cadence")
                    return
            elif liquids[i]["id"]=="hydro:lava" and int(liquids[i]["substeps"])!=1:
                _fail("lava cadence")
                return
        for item: Array in wet:
            var p: Vector3i=item[0]
            if int(item[1])!=water_slot or Vector2(p.x-10,p.z-30).length()>15.0:
                continue
            if not runtime.session.fluid_at(Vector3(p)+Vector3(0.5,-0.9,0.5)).is_empty():
                continue
            if not runtime.session.fluid_at(Vector3(p)+Vector3(0.5,-1.9,0.5)).is_empty():
                continue
            if tool.get_voxel_f(p+Vector3i.DOWN)>0.1 or tool.get_voxel_f(p+Vector3i.DOWN*2)>0.1:
                continue
            var c:=Vector3(p)+Vector3(0.5,-2.0,0.5)
            if not runtime.world.can_edit_sphere(c,RADIUS):
                continue
            bottom=p
            cut=c
            chosen=true
            break
        if not chosen:
            _fail("real reservoir barrier sample missing")
            return
        var near:=Vector3(bottom)+Vector3(0.5,-0.999,0.5)
        var deep:=near+Vector3.DOWN
        if runtime.submit_brush(cut,false,RADIUS)!="accepted":
            _fail("reservoir barrier removal")
            return
        if not runtime.session.fluid_at(near).is_empty() or not runtime.session.fluid_at(deep).is_empty():
            _fail("instant flow on breach")
            return
        runtime.session.update_interest(runtime.player.global_position)
        var moved:=0
        var first_near:=0
        var first_deep:=0
        for i in range(1,81):
            if runtime.session.advance_ticks(100000000,1)!=1:
                _fail("fluid tick")
                return
            moved+=int(runtime.session.get_state()["fluid_transferred"])
            if first_near==0 and not runtime.session.fluid_at(near).is_empty():
                first_near=i
            if first_deep==0 and not runtime.session.fluid_at(deep).is_empty():
                first_deep=i
            if int(runtime.session.get_state()["fluid_substeps"])!=5:
                _fail("water substeps not executed")
                return
            if first_near>0 and first_deep>0:
                break
        if first_near==0 or first_deep<first_near:
            _fail("progressive breach arrival near="+str(first_near)+" deep="+str(first_deep))
            return
        print("V3_FLUID_BREACH_PASS cell=",bottom," near_tick=",first_near," deep_tick=",first_deep)
        if moved<=0 or int(runtime.session.get_state()["fluid_litres"])!=volume:
            _fail("flow or mass conservation")
            return
        water.call("_collect_dirty")
        var tile: Vector3i=water.call("_tile",Vector3i(row[0]))
        water.call("_publish",tile)
        var presentation: Dictionary=water.call("get_report")
        if int(presentation["tile_meshes"])<1 or int(presentation["triangles_published"])<1:
            _fail("continuous fluid mesh missing")
            return
        # Real terrain breach has a transient downward-transfer curtain;
        # inspect all nearby tiles rather than assuming a specific tile owns it.
        var flow_tile: Vector3i=water.call("_tile",bottom)
        for dy in range(-1,2):
            water.call("_publish",flow_tile+Vector3i(0,dy,0))
        presentation=water.call("get_report")
        print("V3_FLUID_SURFACE_RUNTIME_PASS triangles=",presentation["triangles_published"]," ribbons=",presentation["ribbon_triangles"])
        print("V3_FLUID_RUNTIME_FLOW_PASS moved_litres=",moved," mass=",volume," tiles=",water.call("get_report"))
    else:
        if int(state["terrain_revision"])!=2 or int(state["checkpoint_generation"])!=1:
            _fail("reopen checkpoint")
            return
        print("V3_FLUID_RUNTIME_RESTORE_PASS mass=",volume)
    print("V3_FLUID_RUNTIME_FIXTURE_PASS phase=","write" if write else "reopen"," mass=",volume)
    runtime.request_close()
