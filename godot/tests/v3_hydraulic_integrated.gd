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

# Diagnostic only: serialize the exact arrays last submitted to visible
# Godot meshes, and project them with the capture camera. No simulation
# tick, refresh, terrain write or shader change; outside timed samples.
func _surface_evidence(runtime,water: Node3D,camera: Camera3D,center: Vector3) -> bool:
    var capture_root:=OS.get_environment("V3_GPU_CAPTURE_ROOT")
    if capture_root.is_empty():
        return true
    var patches: Array=[]
    var nodes: Dictionary=water.get("_hybrid_nodes")
    for tile: Vector3i in nodes:
        for node: MeshInstance3D in nodes[tile]:
            if not node.visible:
                continue
            if not node.has_meta("liquid_positions") or not node.has_meta("liquid_uv"):
                _fail("surface evidence missing accepted arrays")
                return false
            var vertices: PackedVector3Array=node.get_meta("liquid_positions")
            var uv: PackedVector2Array=node.get_meta("liquid_uv")
            var rows: Array=[]
            for i in range(vertices.size()):
                var v: Vector3=node.to_global(vertices[i])
                var screen: Vector2=camera.unproject_position(v)
                rows.append([v.x,v.y,v.z,uv[i].x,uv[i].y,screen.x,screen.y,-camera.to_local(v).z])
            patches.append({"tile":[tile.x,tile.y,tile.z],"slot":node.get_meta("liquid_slot"),"vertices":rows})
    var columns: Array=[]
    for z in range(floori(center.z)-32,floori(center.z)+33):
        for x in range(floori(center.x)-32,floori(center.x)+33):
            var p:=Vector3(x+0.5,0,z+0.5)
            var litres: int=runtime.session.hydraulic_column_mass(p)
            var layers: Array=[]
            if litres>0:
                for y in range(-12,8):
                    p.y=y+0.5
                    var wet: Dictionary=runtime.session.hydraulic_at(p)
                    if not wet.is_empty():
                        layers.append([p.y,wet.get("level"),wet.get("slot")])
            columns.append([x,z,litres,layers])
    var file:=FileAccess.open(capture_root.path_join("05-surface-evidence.log"),FileAccess.WRITE)
    if file==null:
        _fail("surface evidence open")
        return false
    file.store_string(JSON.stringify({"schema":"v3-surface-evidence-1","center":[center.x,center.y,center.z],"camera":[camera.global_position.x,camera.global_position.y,camera.global_position.z],"viewport":[root.size.x,root.size.y],"patches":patches,"columns":columns,"state":runtime.session.hydraulic_report()}))
    file.close()
    print("V3_HYBRID_SURFACE_EVIDENCE_PASS patches=",patches.size()," columns=",columns.size())
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
    if not runtime.session.update_interest(runtime.player.global_position):
        _fail("interest "+runtime.session.get_last_error())
        return false
    if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,elapsed):
        _fail("hydraulic frame "+runtime.session.get_last_error())
        return false
    water.call("refresh")
    return true

# Actual VoxelTool edit in a deep solid point under a wet tile. The
# tiny carve modifies terrain but cannot form a certified 1m air cell.
# No debug injection or forced aggregation: runtime handles unload.
func _lifecycle(runtime,water: Node3D,reopen: bool) -> void:
    var initial: Dictionary=runtime.session.hydraulic_report()
    var mass:=int(initial["litres"])
    if int(initial["local_active"])!=0 or (reopen and int(initial["suspended_reclaims"])<1):
        _fail("lifecycle initial owner "+str(initial))
        return
    var tool: VoxelTool=runtime.terrain.get_voxel_tool()
    tool.channel=VoxelBuffer.CHANNEL_SDF
    var spawn: Vector3=runtime.player.global_position
    var tile:=_tile(spawn)
    var probe:=Vector3.ZERO
    var accepted:=false
    for dz in range(-1,2):
        for dx in range(-1,2):
            var k:=tile+Vector3i(dx*16,0,dz*16)
            var wet:=false
            for z in range(k.z,k.z+16):
                for x in range(k.x,k.x+16):
                    var p:=Vector3(x+0.5,0,z+0.5)
                    if runtime.session.hydraulic_column_mass(p)>0:
                        probe=p
                        wet=true
                        break
                if wet:
                    break
            if not wet:
                continue
            for y in range(-29,-15):
                var p:=Vector3(k.x+8,y,k.z+8)
                if tool.get_voxel_f(Vector3i(p))>=-0.5:
                    continue
                if runtime.submit_brush(p,false,0.5)=="accepted":
                    accepted=true
                    break
            if accepted:
                break
        if accepted:
            break
    if not accepted:
        _fail("lifecycle no admissible deep edit")
        return
    var deadline:=Time.get_ticks_msec()+30000
    while int(runtime.session.hydraulic_report()["pending_edit_tiles"])>0:
        if not _frame(runtime,water,0):
            return
        if Time.get_ticks_msec()>deadline:
            _fail("lifecycle edit publication")
            return
        await process_frame
    var hot: Dictionary=runtime.session.hydraulic_report()
    var column: int=runtime.session.hydraulic_column_mass(probe)
    if int(hot["local_active"])!=1 or int(hot["local_bytes"])<=0 or int(hot["litres"])!=mass or column<=0:
        _fail("lifecycle activation "+str(hot))
        return
    runtime.player.global_position=spawn+Vector3(256,0,0)
    if not _frame(runtime,water,0):
        return
    var cold: Dictionary=runtime.session.hydraulic_report()
    if int(cold["local_active"])!=0 or int(cold["local_bytes"])!=0 or int(cold["litres"])!=mass or int(cold["ticks"])!=int(hot["ticks"]) or int(cold["suspended_reclaims"])!=int(hot["suspended_reclaims"])+1:
        _fail("lifecycle exact suspension "+str(cold))
        return
    runtime.player.global_position=spawn
    deadline=Time.get_ticks_msec()+30000
    while runtime.session.hydraulic_column_mass(probe)<0 or int(runtime.session.hydraulic_report()["near_active_tiles"])<9:
        if not _frame(runtime,water,0):
            return
        if Time.get_ticks_msec()>deadline:
            _fail("lifecycle revisit")
            return
        await process_frame
    if runtime.session.hydraulic_column_mass(probe)!=column or int(runtime.session.hydraulic_report()["litres"])!=mass:
        _fail("lifecycle revisit changed mass")
        return
    print("V3_HYBRID_LIFECYCLE_PASS phase=",("reopen" if reopen else "write")," mass=",mass," freed_bytes=",hot["local_bytes"]," reclaimed=",cold["suspended_reclaims"]," column=",column)
    if not reopen:
        runtime.player.global_position=spawn+Vector3(512,0,512)
        deadline=Time.get_ticks_msec()+30000
        while true:
            if not _frame(runtime,water,0):
                return
            var state: Dictionary=runtime.session.hydraulic_report()
            if int(state["litres"])!=mass or int(state["ticks"])!=int(hot["ticks"]) or int(state["tiles"])>96:
                _fail("cold persistence ledger "+str(state))
                return
            if int(state["cold_tiles"])>=10 and int(state["cold_litres"])>0 and runtime.session.hydraulic_column_mass(probe)<0:
                print("V3_HYBRID_COLD_RUNTIME_PASS phase=write state=",state," probe=",probe," column=",column)
                break
            if Time.get_ticks_msec()>deadline:
                _fail("cold persistence eviction "+str(state))
                return
            await process_frame
    else:
        if int(initial["cold_restores"])<=0 or int(initial["cold_evictions"])<10:
            _fail("cold reopen did not recover persisted owners "+str(initial))
            return
        print("V3_HYBRID_COLD_RUNTIME_PASS phase=reopen state=",initial," probe=",probe," column=",column)
    runtime.request_close()

func _wait_source(runtime,water: Node3D,id: String) -> bool:
    var deadline:=Time.get_ticks_msec()+90000
    while true:
        if not _frame(runtime,water,0):
            return false
        var state: Dictionary=runtime.session.hydraulic_report()
        if id in state.get("source_ids",[]) and int(state["near_active_tiles"])>=9:
            return true
        if Time.get_ticks_msec()>deadline:
            _fail("late source "+id+" "+str(state))
            return false
        await process_frame
    return false

func _sources(runtime,water: Node3D,reopen: bool) -> void:
    var before: Dictionary=runtime.session.hydraulic_report()
    var initial:=int(before["initial"])
    # Both late-source anchors must actually be outside LOD0 in this
    # fixture. Do not infer nonresidency merely from distance or timing.
    var tool: VoxelTool=runtime.terrain.get_voxel_tool()
    if not reopen:
        for anchor in [Vector3(48,-32,-32),Vector3(-128,-32,128)]:
            if tool.is_area_editable(AABB(anchor,Vector3(17,65,17))):
                _fail("source fixture anchor unexpectedly resident "+str(anchor))
                return
        print("V3_HYBRID_SOURCE_FIXTURE_NONRESIDENT_PASS anchors=2")
    if int(before["sources"])!=3 or (not reopen and (int(before["nonresident_source_discoveries"])<2 or int(before.get("basin_completed",0))!=1)):
        _fail("source view discovery "+str(before))
        return
    print("V3_HYBRID_VISIBLE_SOURCE_PASS phase=",("reopen" if reopen else "write")," state=",before)
    runtime.player.global_position=Vector3(48,12,-28)
    if not await _wait_source(runtime,water,"hydro:lava_pool"):
        return
    var lava: Dictionary=runtime.session.hydraulic_report()
    if int(lava["initial"])!=initial or initial<=11378442:
        _fail("late finite initialization "+str(lava))
        return
    var found_lava:=false
    for z in range(-44,-12):
        for x in range(32,64):
            for y in range(-12,32):
                var sample: Dictionary=runtime.session.hydraulic_at(Vector3(x+0.5,y+0.5,z+0.5))
                if not sample.is_empty() and float(sample["density"])==2800.0:
                    found_lava=true
                    break
            if found_lava:
                break
        if found_lava:
            break
    if not found_lava:
        _fail("late lava physical sample")
        return
    var finite:=int(lava["initial"])
    runtime.player.global_position=Vector3(-128,12,128)
    if not await _wait_source(runtime,water,"hydro:sea"):
        return
    var start: Dictionary=runtime.session.hydraulic_report()
    for i in range(40):
        if not _frame(runtime,water,50000000):
            return
        var state: Dictionary=runtime.session.hydraulic_report()
        if int(state["initial"])!=finite or int(state["litres"])!=finite+int(state["injected"])-int(state["drained"]):
            _fail("ocean ledger "+str(state))
            return
        await process_frame
        if int(state["injected"])>int(start["injected"]):
            break
    var after: Dictionary=runtime.session.hydraulic_report()
    if int(after["sources"])!=3 or int(after["injected"])<=int(start["injected"]):
        _fail("late ocean did not inject "+str(after))
        return
    print("V3_HYBRID_SOURCES_PASS phase=",("reopen" if reopen else "write")," initial=",finite," state=",after)
    runtime.request_close()

func _barrier(runtime,water: Node3D,streaming: bool=false) -> void:
    var initial: Dictionary=runtime.session.hydraulic_report()
    var mass:=int(initial["litres"])
    var tool: VoxelTool=runtime.terrain.get_voxel_tool()
    tool.channel=VoxelBuffer.CHANNEL_SDF
    var tile:=_tile(runtime.player.global_position)
    var center:=Vector3.ZERO
    var accepted:=false
    for dz in range(-1,2):
        for dx in range(-1,2):
            var k:=tile+Vector3i(dx*16,0,dz*16)
            for z in range(k.z+4,k.z+12,2):
                for x in range(k.x+4,k.x+12,2):
                    for y in range(-8,3):
                        var p:=Vector3(x+0.5,y+0.5,z+0.5)
                        var wet: Dictionary=runtime.session.hydraulic_at(p)
                        if wet.is_empty() or float(wet["level"])-p.y<0.5 or tool.get_voxel_f(Vector3i(p.floor()))<0.1:
                            continue
                        if runtime.submit_brush(p,true,2.0)=="accepted":
                            center=p
                            accepted=true
                            break
                    if accepted:
                        break
                if accepted:
                    break
            if accepted:
                break
        if accepted:
            break
    if not accepted:
        _fail("no admissible wet construction "+str(runtime.session.hydraulic_report()))
        return
    var spawn: Vector3=runtime.player.global_position
    var origin:=_tile(center)
    if streaming:
        var live: Dictionary=runtime.session.inspect_hydraulic_tile(runtime.world,origin,Vector3i(16,64,16))
        if live["status"]!="ready" or int(live["render_pad"])!=1:
            _fail("stream live reference "+str(live))
            return
        runtime.player.global_position=spawn+Vector3(512,0,0)
        var unload_deadline:=Time.get_ticks_msec()+30000
        while tool.is_area_editable(AABB(Vector3(origin),Vector3(17,65,17))):
            if Time.get_ticks_msec()>unload_deadline:
                _fail("stream tile still resident")
                return
            await process_frame
        var unsaved: Dictionary=runtime.session.inspect_hydraulic_tile(runtime.world,origin,Vector3i(16,64,16))
        if unsaved["status"]!="deferred":
            _fail("unsaved edited stream should defer "+str(unsaved))
            return
        runtime.request_flush()
        var save_deadline:=Time.get_ticks_msec()+65000
        while runtime.saving:
            if Time.get_ticks_msec()>save_deadline:
                _fail("stream save timeout")
                return
            await process_frame
        var saved: Dictionary=runtime.session.get_state()
        if int(saved["durable_terrain_revision"])!=int(saved["terrain_revision"]):
            _fail("stream durability "+str(saved))
            return
        var stored: Dictionary=runtime.session.inspect_hydraulic_tile(runtime.world,origin,Vector3i(16,64,16))
        if stored["status"]!="ready" or not bool(stored.get("streamed",false)) or int(stored["stream_found_blocks"])<1 or stored["sdf_digest"]!=live["sdf_digest"] or int(stored["capacity_litres"])!=int(live["capacity_litres"]):
            _fail("stream SDF mismatch live="+str(live)+" stored="+str(stored))
            return
        print("V3_HYBRID_STREAM_SDF_PASS unsaved=deferred live=",live," stored=",stored)
    var deadline:=Time.get_ticks_msec()+30000
    while int(runtime.session.hydraulic_report()["pending_edit_tiles"])>0:
        if not _frame(runtime,water,0):
            return
        if Time.get_ticks_msec()>deadline:
            _fail("barrier publication "+str(runtime.session.hydraulic_report()))
            return
        await process_frame
    if streaming:
        var offline: Dictionary=runtime.session.hydraulic_report()
        if int(offline["stream_survey_tiles"])<1 or int(offline["stream_found_blocks"])<1 or int(offline["stream_steps"])<2 or int(offline["litres"])!=mass:
            _fail("stream publication "+str(offline))
            return
        print("V3_HYBRID_STREAM_PUBLICATION_PASS ",offline)
        runtime.player.global_position=spawn
        deadline=Time.get_ticks_msec()+30000
        while not tool.is_area_editable(AABB(Vector3(origin),Vector3(17,65,17))) or int(runtime.session.hydraulic_report()["near_active_tiles"])<9:
            if not _frame(runtime,water,0):
                return
            if Time.get_ticks_msec()>deadline:
                _fail("stream revisit timeout")
                return
            await process_frame
    var blocked: Dictionary=runtime.session.hydraulic_report()
    if int(blocked["litres"])!=mass or int(blocked["construction_commits"])!=1 or int(blocked["blocked_tiles"])!=0 or not runtime.session.hydraulic_at(center).is_empty() or tool.get_voxel_f(Vector3i(center.floor()))>=0:
        _fail("barrier displacement "+str(blocked))
        return
    for i in range(25):
        if not _frame(runtime,water,50000000):
            return
        await process_frame
    var state: Dictionary=runtime.session.hydraulic_report()
    # At rev>0 a pristine, source-connected ocean tile can acquire
    # new water with an explicit injection ledger during these 25 ticks.
    # A barrier must still keep its solid centre dry and preserve the
    # complete mass identity; fixed mass is no longer a valid invariant.
    if int(state["litres"])!=int(state["initial"])+int(state["injected"])-int(state["drained"]) or int(state["blocked_tiles"])!=0 or not runtime.session.hydraulic_at(center).is_empty():
        _fail("barrier retained solid "+str(state))
        return
    print("V3_HYBRID_BARRIER_PASS mass=",mass," center=",center," state=",state)
    runtime.request_close()

func _ocean_stress(runtime,water: Node3D,phase: String) -> void:
    var deadline:=Time.get_ticks_msec()+180000
    var reached:=false
    while Time.get_ticks_msec()<deadline:
        if not _frame(runtime,water,0):
            return
        var state: Dictionary=runtime.session.hydraulic_report()
        var render: Dictionary=water.call("get_report")
        if "wide_sea:head" in state.get("source_ids",[]) and int(state.get("visible_wet_tiles",0))>96 and int(state.get("cold_visual_tiles",0))>=5 and int(state.get("tiles",1000))<=96 and int(render.get("meshes",0))>96 and bool(water.get("_hybrid_ready")):
            reached=true
            break
        await process_frame
    var ready: Dictionary=runtime.session.hydraulic_report()
    if not reached or int(ready["litres"])!=int(ready["initial"])+int(ready["injected"])-int(ready["drained"]):
        _fail("ocean visible >96 coverage or ledger "+str(ready)+" render="+str(water.call("get_report")))
        return
    if not await _capture("08-ocean-wide"):
        return
    var origin: Vector3=runtime.player.global_position
    runtime.player.global_position=origin+Vector3(128,0,0)
    for i in range(60):
        if not _frame(runtime,water,0):
            return
        await process_frame
    runtime.player.global_position=origin
    for i in range(60):
        if not _frame(runtime,water,0):
            return
        await process_frame
    var revisited: Dictionary=runtime.session.hydraulic_report()
    if int(revisited["litres"])!=int(revisited["initial"])+int(revisited["injected"])-int(revisited["drained"]) or int(revisited["tiles"])>96:
        _fail("ocean revisit ledger or hot limit "+str(revisited))
        return
    if not await _capture("09-ocean-revisit"):
        return
    print("V3_HYBRID_OCEAN_STRESS_PASS phase=",phase," visible=",ready["visible_wet_tiles"]," hot=",ready["tiles"]," cold_visual=",ready["cold_visual_tiles"]," meshes=",water.call("get_report")["meshes"]," reopened=",revisited)
    runtime.request_close()

func _test() -> void:
    var args:=OS.get_cmdline_user_args()
    var reopen: bool="--phase=reopen" in args
    var lifecycle: bool="--phase=lifecycle" in args or "--phase=lifecycle-reopen" in args
    var sources: bool="--phase=sources" in args or "--phase=sources-reopen" in args
    var barrier: bool="--phase=barrier" in args or "--phase=streaming" in args
    var remote_basin: bool="--phase=remote-basin" in args or "--phase=remote-basin-reopen" in args
    var remote_reopen: bool="--phase=remote-basin-reopen" in args
    var ocean_stress: bool="--phase=ocean-stress" in args or "--phase=ocean-stress-reopen" in args
    var old_spawn:=OS.get_environment("V3_CAVE_SPAWN")
    if remote_basin:
        OS.set_environment("V3_CAVE_SPAWN","16,12,112")
    if ocean_stress:
        OS.set_environment("V3_CAVE_SPAWN","112,12,112")
    var runtime=load("res://scenes/v3_hydraulic_main.tscn").instantiate()
    root.add_child(runtime)
    if remote_basin or ocean_stress:
        if old_spawn.is_empty():
            OS.unset_environment("V3_CAVE_SPAWN")
        else:
            OS.set_environment("V3_CAVE_SPAWN",old_spawn)
    if not runtime.running:
        _fail("startup")
        return
    runtime.set_process(false)
    runtime.player.set_process(false)
    runtime.player.set_physics_process(false)
    var water: Node3D=runtime.world.get_node("Water")
    water.set_process(false)
    water.set_physics_process(false)
    runtime.player.global_position=Vector3(112,12,112) if ocean_stress else (Vector3(16,12,112) if remote_basin else Vector3(-4,12,28))
    var camera: Camera3D=runtime.player.get_node("Camera3D")
    camera.global_position=Vector3(112,60,128) if ocean_stress else Vector3(-4,48,48)
    camera.look_at(Vector3(112,20,112) if ocean_stress else Vector3(-4,0,23),Vector3.UP)
    var deadline:=Time.get_ticks_msec()+(180000 if remote_basin or ocean_stress else 90000)
    var remote_empty_seen:=false
    var source_positioned:=true # new hybrid worlds survey finite basins directly
    while true:
        if not _frame(runtime,water,0):
            return
        var state: Dictionary=runtime.session.hydraulic_report()
        if remote_basin and not remote_reopen and str(state.get("solver",""))=="hybrid" and not "hydro:pond" in state.get("source_ids",[]):
            remote_empty_seen=true
        # Sources are acquired through one certified path. Neither lava
        # nor sea requires VoxelTool LOD0 residency.
        if source_positioned and str(state.get("solver",""))=="hybrid" and int(state["near_active_tiles"])>=9 and int(state.get("visible_sources_pending",1))==0 and bool(water.get("_hybrid_ready")) and int(water.call("get_report")["meshes"])>0:
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
    if ocean_stress:
        await _ocean_stress(runtime,water,("reopen" if "--phase=ocean-stress-reopen" in args else "write"))
        return
    if remote_basin:
        if not remote_reopen and (not remote_empty_seen or int(initial.get("basin_completed",0))!=1 or int(initial.get("basin_surveyed_tiles",0))<=35 or int(initial.get("basin_initial_litres",0))+64000!=int(initial["initial"])):
            _fail("remote finite basin certification "+str(initial))
            return
        if not "hydro:pond" in initial.get("source_ids",[]) or int(initial["tiles"])>96:
            _fail("remote finite basin ownership "+str(initial))
            return
        var finite_mass:=int(initial["initial"])
        runtime.player.global_position=Vector3(-4,12,28)
        if not await _wait_source(runtime,water,"hydro:pond"):
            return
        var revisit: Dictionary=runtime.session.hydraulic_report()
        if int(revisit["initial"])!=finite_mass or int(revisit["litres"])!=finite_mass+int(revisit["injected"])-int(revisit["drained"]) or runtime.session.hydraulic_column_mass(Vector3(-4.5,0,28.5))<=0:
            _fail("remote finite basin revisit "+str(revisit))
            return
        print("V3_HYBRID_REMOTE_BASIN_PASS phase=",("reopen" if remote_reopen else "write")," initial=",finite_mass," state=",revisit)
        runtime.request_close()
        return
    if barrier:
        await _barrier(runtime,water,"--phase=streaming" in args)
        return
    if sources:
        await _sources(runtime,water,"--phase=sources-reopen" in args)
        return
    if lifecycle:
        await _lifecycle(runtime,water,"--phase=lifecycle-reopen" in args)
        return
    if reopen:
        if not bool(initial.get("provenance_complete",false)) or int(initial.get("edited_provenance_tiles",0))<=0:
            _fail("edit provenance not reopened")
            return
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
    if not bool(published.get("provenance_complete",false)) or int(published.get("edited_provenance_tiles",0))<=0:
        _fail("accepted terrain edit provenance missing")
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
    if not _surface_evidence(runtime,water,camera,breach["center"]):
        return
    var retained:=int(water.call("get_report")["meshes"])
    # Move within visible range without altering terrain; certified
    # water patches must remain present while physics tiles suspend.
    for i in range(80):
        runtime.player.global_position+=Vector3(0.8,0,0)
        if not _frame(runtime,water,50000000):
            return
        var movement_state: Dictionary=runtime.session.hydraulic_report()
        if int(movement_state["litres"])!=mass or int(water.call("get_report")["meshes"])==0:
            _fail("movement mass/visibility expected="+str(mass)+" state="+str(movement_state)+" render="+str(water.call("get_report")))
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
