extends SceneTree
func _initialize() -> void:
    call_deferred("_test")
func _fail(reason: String) -> void:
    push_error("V3_HYBRID_INTEGRATED_FAIL: "+reason)
    quit(1)

func _capture(name: String) -> bool:
    if OS.get_environment("V3_GPU_CAPTURE_ROOT").is_empty():
        return true
    await process_frame
    await RenderingServer.frame_post_draw
    var image:=root.get_texture().get_image()
    if image==null or image.is_empty() or image.save_png(OS.get_environment("V3_GPU_CAPTURE_ROOT").path_join(name+".png"))!=OK:
        _fail("capture "+name)
        return false
    print("V3_HYBRID_CAPTURE ",name)
    return true

func _tile(p: Vector3) -> Vector3i:
    return Vector3i(floori(p.x/16.0)*16,-32,floori(p.z/16.0)*16)

func _find_breach(runtime,tool: VoxelTool,camera: Camera3D) -> Dictionary:
    # Search the whole certified shoreline. A radius-six carve may cross
    # a tile boundary, but both destination columns must have zero mass.
    # Do not select a point under an already wet vertical interval.
    for z in range(-64,80):
        for x in range(-96,48):
            var donor:=Vector3(x+0.5,0,z+0.5)
            if runtime.session.hydraulic_column_mass(donor)<=500:
                continue
            for y in range(-8,4):
                donor.y=y+0.5
                var wet: Dictionary=runtime.session.hydraulic_at(donor)
                if wet.is_empty() or float(wet["level"])-donor.y<0.5:
                    continue
                for direction: Vector3 in [Vector3.LEFT,Vector3.RIGHT,Vector3.FORWARD,Vector3.BACK]:
                    for distance in range(1,4):
                        var near_probe:=donor+direction*distance-Vector3(0,0.5,0)
                        var far_probe:=near_probe+direction*2
                        var center:=(near_probe+far_probe)*0.5
                        if runtime.session.hydraulic_column_mass(near_probe)!=0 or runtime.session.hydraulic_column_mass(far_probe)!=0:
                            continue
                        if not tool.is_area_editable(AABB(center-Vector3(8,8,8),Vector3(16,16,16))):
                            continue
                        if tool.get_voxel_f(Vector3i(near_probe.floor()))>=-0.1 or tool.get_voxel_f(Vector3i(far_probe.floor()))>=-0.1:
                            continue
                        if not OS.get_environment("V3_GPU_CAPTURE_ROOT").is_empty():
                            camera.global_position=center+Vector3(0,18,20)
                            camera.look_at(center,Vector3.UP)
                            if not await _capture("02-before-breach"):
                                return {}
                        if runtime.submit_brush(center,false,6.0)=="accepted":
                            return {"center":center,"near":near_probe,"far":far_probe,"donor":donor,"pre_edit_column_litres":[0,0]}
    return {}

func _frame(runtime,water: Node3D,elapsed: int) -> bool:
    if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,elapsed):
        _fail("hydraulic frame "+runtime.session.get_last_error())
        return false
    water.call("refresh")
    return true

func _test() -> void:
    var reopen: bool="--phase=reopen" in OS.get_cmdline_user_args()
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
    var camera: Camera3D=runtime.player.get_node("Camera3D")
    camera.global_position=Vector3(-4,48,48)
    camera.look_at(Vector3(-4,0,23),Vector3.UP)
    var deadline:=Time.get_ticks_msec()+90000
    while true:
        if not _frame(runtime,water,0):
            return
        var state: Dictionary=runtime.session.hydraulic_report()
        if str(state.get("solver",""))=="hybrid" and int(state["near_active_tiles"])>=9 and bool(water.get("_hybrid_ready")) and int(water.call("get_report")["meshes"])>0:
            break
        if Time.get_ticks_msec()>deadline:
            _fail("readiness "+str(state))
            return
        await process_frame
    var initial: Dictionary=runtime.session.hydraulic_report()
    var mass:=int(initial["litres"])
    if mass<=0 or mass!=int(initial["initial"])+int(initial["injected"])-int(initial["drained"]):
        _fail("ledger")
        return
    if not runtime.session.hydraulic_at(Vector3(-4,-30,28)).is_empty():
        _fail("isolated dry cavity")
        return
    if reopen:
        if int(initial["local_active"])<1 or int(runtime.session.get_state()["terrain_revision"])<1:
            _fail("local ownership was not reopened "+str(initial))
            return
        var reopened_ticks:=int(initial["ticks"])
        for i in range(20):
            if not _frame(runtime,water,50000000):
                return
            await process_frame
        var after: Dictionary=runtime.session.hydraulic_report()
        if int(after["litres"])!=mass or int(after["ticks"])<=reopened_ticks:
            _fail("reopen ledger/ticks")
            return
        print("V3_HYBRID_INTEGRATED_PASS phase=reopen mass=",mass," state=",after)
        runtime.request_close()
        return
    if not await _capture("01-initial"):
        return
    var tool: VoxelTool=runtime.terrain.get_voxel_tool()
    tool.channel=VoxelBuffer.CHANNEL_SDF
    var breach: Dictionary={}
    for attempt in range(4):
        breach=await _find_breach(runtime,tool,camera)
        if not breach.is_empty():
            break
        for step in range(32):
            if not _frame(runtime,water,0):
                return
            await process_frame
    if breach.is_empty():
        _fail("no admissible shore breach "+str(initial))
        return
    var near: Vector3=breach["near"]
    var far: Vector3=breach["far"]
    print("V3_HYBRID_BREACH ",breach)
    var before_ticks:=int(runtime.session.hydraulic_report()["ticks"])
    deadline=Time.get_ticks_msec()+30000
    while int(runtime.session.hydraulic_report()["pending_edit_tiles"])>0:
        if not _frame(runtime,water,0):
            return
        if Time.get_ticks_msec()>deadline:
            _fail("edit publication "+str(runtime.session.hydraulic_report()))
            return
        await process_frame
    var published: Dictionary=runtime.session.hydraulic_report()
    if int(published["ticks"])!=before_ticks or int(published["litres"])!=mass or int(published["local_active"])<=0:
        _fail("exclusive edit remap "+str(published))
        return
    var near_zero: int=runtime.session.hydraulic_column_mass(near)
    var far_zero: int=runtime.session.hydraulic_column_mass(far)
    print("V3_HYBRID_ZERO_TICK_COLUMN_MASS near=",near_zero," far=",far_zero)
    if near_zero!=0 or far_zero!=0:
        _fail("instant horizontal wetting "+str([near_zero,far_zero]))
        return
    while not bool(water.get("_hybrid_ready")):
        if not _frame(runtime,water,0):
            return
        if Time.get_ticks_msec()>deadline:
            _fail("edited visual publication")
            return
        await process_frame
    if not await _capture("03-open-no-tick"):
        return
    var first_near:=-1
    var first_far:=-1
    var frames: Array[int]=[]
    var previous:=Time.get_ticks_usec()
    for i in range(320):
        if not _frame(runtime,water,50000000):
            return
        var state: Dictionary=runtime.session.hydraulic_report()
        if int(state["litres"])!=mass or int(state["blocked_tiles"])>0:
            _fail("flow ledger or remap blocked "+str(state))
            return
        if first_near<0 and runtime.session.hydraulic_column_mass(near)>=20:
            first_near=i+1
        if first_far<0 and runtime.session.hydraulic_column_mass(far)>=20:
            first_far=i+1
        await process_frame
        var now:=Time.get_ticks_usec()
        frames.append(now-previous)
        previous=now
        if i==9 and not await _capture("04-transient"):
            return
        if first_near>0 and first_far>first_near and i>=39:
            break
    if first_near<=0 or first_far<=first_near:
        _fail("front did not progress near="+str(first_near)+" far="+str(first_far)+" "+str(runtime.session.hydraulic_report()))
        return
    print("V3_HYBRID_PROGRESSIVE_PASS threshold_l=20 near_tick=",first_near," far_tick=",first_far," mass=",mass)
    if not await _capture("05-filled"):
        return
    var retained:=int(water.call("get_report")["meshes"])
    # Move within visible range without altering terrain; certified
    # water patches must remain present while physics tiles suspend.
    for i in range(80):
        runtime.player.global_position+=Vector3(0.8,0,0)
        if not _frame(runtime,water,50000000):
            return
        if int(runtime.session.hydraulic_report()["litres"])!=mass or int(water.call("get_report")["meshes"])==0:
            _fail("movement mass/visibility")
            return
        await process_frame
    if not await _capture("06-movement"):
        return
    runtime.player.global_position=Vector3(-4,12,28)
    if not _frame(runtime,water,0):
        return
    camera.global_position=Vector3(-4,48,48)
    camera.look_at(Vector3(-4,0,23),Vector3.UP)
    if not await _capture("07-return"):
        return
    frames.sort()
    var p95: int=frames[mini(frames.size()-1,ceili(float(frames.size())*0.95)-1)]
    var state: Dictionary=runtime.session.hydraulic_report()
    if int(state["local_active"])<=0 or int(state["moved"])<=0 or not runtime.session.hydraulic_at(Vector3(-4,-30,28)).is_empty():
        _fail("mid-flow or dry cave "+str(state))
        return
    print("V3_HYBRID_INTEGRATED_PASS phase=write mass=",mass," retained_before_move=",retained," fixture_frame_p95_us=",p95," state=",state," render=",water.call("get_report"))
    runtime.request_close()
