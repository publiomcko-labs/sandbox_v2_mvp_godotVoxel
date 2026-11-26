extends SceneTree
func _initialize() -> void:
    call_deferred("_test")
func _fail(reason: String) -> void:
    push_error("V3_HYDRAULIC_RUNTIME_FAIL: "+reason)
    quit(1)
func _test() -> void:
    var write: bool="--phase=write" in OS.get_cmdline_user_args()
    var runtime=load("res://scenes/v3_hydraulic_main.tscn").instantiate()
    root.add_child(runtime)
    if not runtime.running:
        _fail("startup")
        return
    runtime.set_process(false)
    runtime.player.set_process(false)
    runtime.player.set_physics_process(false)
    var water: Node3D=runtime.world.get_node("Water")
    water.set_process(false)
    water.set_physics_process(false)
    runtime.player.global_position=Vector3(-4,12,28)
    var deadline:=Time.get_ticks_msec()+60000
    while true:
        if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,0):
            _fail(runtime.session.get_last_error())
            return
        var report: Dictionary=runtime.session.hydraulic_report()
        if int(report["tiles"])>=9 and int(report["sources"])>=1 and not runtime.session.hydraulic_surfaces().is_empty():
            break
        if Time.get_ticks_msec()>deadline:
            _fail("source/region readiness "+str(report))
            return
        await process_frame
    var before: Dictionary=runtime.session.hydraulic_report()
    var mass:=int(before["litres"])
    if mass<=0 or mass!=int(before["initial"])+int(before["injected"])-int(before["drained"]):
        _fail("mass ledger")
        return
    if not runtime.session.hydraulic_at(Vector3(-4,-30,28)).is_empty():
        _fail("global water mask")
        return
    for i in range(6):
        water.call("refresh")
    var presentation: Dictionary=water.call("get_report")
    if int(presentation["meshes"])<1:
        _fail("surface missing")
        return
    var builds:=int(presentation["mesh_builds"])
    water.call("refresh")
    if int(water.call("get_report")["mesh_builds"])!=builds:
        _fail("static surface rebuilt without geometry change")
        return
    if write:
        # A camera/interest change must not delete the renderable reservoir.
        var count_before: int=runtime.session.hydraulic_surfaces().size()
        if not runtime.session.hydraulic_frame(runtime.world,Vector3(240,12,28),0):
            _fail("far interest")
            return
        if runtime.session.hydraulic_surfaces().size()!=count_before:
            _fail("distant water disappeared")
            return
        while int(runtime.session.hydraulic_report()["active_tiles"])<9:
            if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,0):
                _fail("restore interest")
                return
            if Time.get_ticks_msec()>deadline:
                _fail("restore interest timeout")
                return
            await process_frame
        print("V3_HYDRAULIC_VISIBILITY_PASS retained=",count_before)
        # Find a genuinely submerged floor sample with solid beneath, then
        # excavate under that exact location, not a random dry cave.
        var tool: VoxelTool=runtime.terrain.get_voxel_tool()
        tool.channel=VoxelBuffer.CHANNEL_SDF
        var cut:=Vector3.ZERO
        var found:=false
        for z in range(16,32):
            if found:
                break
            for x in range(-16,0):
                if found:
                    break
                for y in range(-3,4):
                    var p:=Vector3(float(x)+0.5,float(y)+0.15,float(z)+0.5)
                    var wet: Dictionary=runtime.session.hydraulic_at(p)
                    if wet.is_empty() or absf(float(wet["floor"])-float(y))>0.01:
                        continue
                    var target:=Vector3(p.x,float(y)-1.5,p.z)
                    if tool.get_voxel_f(Vector3i(target.floor()))>=-0.1:
                        continue
                    cut=target
                    found=true
                    break
        if not found:
            _fail("no submerged solid floor for breach")
            return
        if runtime.submit_brush(cut,false,3.0)!="accepted":
            _fail("wet floor excavation rejected")
            return
        var first_wet:=-1
        for i in range(201):
            if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,50000000):
                _fail("breach frame")
                return
            if not runtime.session.hydraulic_at(cut).is_empty():
                first_wet=i
                break
            await process_frame
        if first_wet<0:
            _fail("excavated floor never received water "+str(cut)+" "+str(runtime.session.hydraulic_report()))
            return
        if int(runtime.session.hydraulic_report()["litres"])!=mass:
            _fail("wet breach mass")
            return
        print("V3_HYDRAULIC_WET_BREACH_PASS point=",cut," observed_steps=",first_wet+1," mass=",mass)
        # Let every edited tile finish publication before the next brush.
        while int(runtime.session.hydraulic_report()["active_tiles"])<9:
            if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,0):
                _fail("breach publication")
                return
            if Time.get_ticks_msec()>deadline:
                _fail("breach publication timeout")
                return
            await process_frame
        var before_ticks:=int(runtime.session.hydraulic_report()["ticks"])
        for i in range(20):
            if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,50000000):
                _fail("tick")
                return
        var after: Dictionary=runtime.session.hydraulic_report()
        if int(after["litres"])!=mass or int(after["ticks"])!=before_ticks+20 or int(after["moved"])<=0:
            _fail("transfer "+str(after))
            return
        # Dry excavation isolated from the surface source must not create mass.
        var dry:=Vector3(-4,-20,28)
        if runtime.submit_brush(dry,false,3.0)!="accepted":
            _fail("dry excavation")
            return
        if not runtime.session.hydraulic_at(dry).is_empty():
            _fail("instant fill")
            return
        var prior:=int(after["publications"])
        while int(runtime.session.hydraulic_report()["publications"])<=prior:
            if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,0):
                _fail("edited tile publication")
                return
            if Time.get_ticks_msec()>deadline:
                _fail("remap timeout")
                return
            await process_frame
        if int(runtime.session.hydraulic_report()["litres"])!=mass:
            _fail("remap mass")
            return
    elif int(runtime.session.get_state()["terrain_revision"])!=2:
        _fail("reopen revision")
        return
    print("V3_HYDRAULIC_RUNTIME_PASS phase=","write" if write else "reopen"," mass=",mass," ",runtime.session.hydraulic_report())
    runtime.request_close()
