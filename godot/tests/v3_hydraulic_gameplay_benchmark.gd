extends SceneTree
# Interactive GL Compatibility workload. Measures real inter-frame times,
# not simulated tick duration or a headless FPS substitute.
func _initialize() -> void:
    call_deferred("_run")

func _fail(reason: String) -> void:
    push_error("V3_HYBRID_GAMEPLAY_BENCH_FAIL: "+reason)
    quit(1)

func _step(runtime,water: Node3D,elapsed: int) -> bool:
    if not runtime.session.update_interest(runtime.player.global_position):
        _fail("interest: "+runtime.session.get_last_error())
        return false
    if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,elapsed):
        _fail("hydraulic: "+runtime.session.get_last_error())
        return false
    water.call("refresh")
    return true

func _capture(label: String) -> bool:
    var folder:=OS.get_environment("V3_GPU_CAPTURE_ROOT")
    if folder.is_empty():
        return true
    await RenderingServer.frame_post_draw
    var shot:=root.get_texture().get_image()
    if shot==null or shot.is_empty() or shot.save_png(folder.path_join(label+".png"))!=OK:
        _fail("gameplay screenshot "+label)
        return false
    return true

func _percentile(values: Array[int],fraction: float) -> int:
    if values.is_empty():
        return 0
    return values[mini(values.size()-1,ceili(values.size()*fraction)-1)]

func _attempt_real_edit(runtime,water: Node3D) -> bool:
    var tool: VoxelTool=runtime.terrain.get_voxel_tool()
    tool.channel=VoxelBuffer.CHANNEL_SDF
    # Only a real brush on a solid interval beneath an actual wet tile;
    # never patch the terrain directly from the benchmark.
    var start:=Vector3(-4,0,28)
    for dz in range(-24,25,4):
        for dx in range(-24,25,4):
            var at:=start+Vector3(dx,0,dz)
            if runtime.session.hydraulic_column_mass(at)<=0:
                continue
            for y in range(-24,-8,4):
                var p:=Vector3(at.x,y,at.z)
                if not tool.is_area_editable(AABB(p-Vector3(8,8,8),Vector3(16,16,16))):
                    continue
                if tool.get_voxel_f(Vector3i(p.floor())) >= -0.5:
                    continue
                var revision:=int(runtime.session.get_state()["terrain_revision"])
                if runtime.submit_brush(p,false,0.5)=="accepted":
                    if int(runtime.session.get_state()["terrain_revision"])<=revision:
                        _fail("accepted brush did not increase terrain revision")
                        return false
                    return true
    _fail("no admissible real benchmark edit")
    return false

func _run() -> void:
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
    var spawn:=Vector3(-4,12,28)
    runtime.player.global_position=spawn
    var camera: Camera3D=runtime.player.get_node("Camera3D")
    camera.global_position=spawn+Vector3(0,42,38)
    camera.look_at(spawn-Vector3(0,8,0),Vector3.UP)
    var deadline:=Time.get_ticks_msec()+120000
    while true:
        if not _step(runtime,water,0):
            return
        var state: Dictionary=runtime.session.hydraulic_report()
        if state.get("solver","")=="hybrid" and int(state["near_active_tiles"])>=9 and int(state["visible_sources_pending"])==0 and bool(water.get("_hybrid_ready")) and int(water.call("get_report")["meshes"])>0:
            break
        if Time.get_ticks_msec()>deadline:
            _fail("warmup readiness "+str(state))
            return
        await process_frame
    # Distinguish startup and streaming from the gameplay sample.
    for i in range(360):
        if not _step(runtime,water,50000000):
            return
        await process_frame
    if not await _capture("10-benchmark-warm"):
        return
    var frames: Array[int]=[]
    var copy_peak:=0
    var tick_peak:=0
    var published_before: Dictionary=runtime.session.hydraulic_report()
    var initial_revision:=int(runtime.session.get_state()["terrain_revision"])
    var edited:=false
    var previous:=Time.get_ticks_usec()
    var sample_start:=previous
    for i in range(900):
        # Approximate an aerial traversal and camera sweep across a wet
        # bank, then return to edit physically resident terrain.
        var t:=float(i)/900.0
        runtime.player.global_position=spawn+Vector3(48.0*sin(t*TAU),0.0,24.0*sin(t*TAU*2.0))
        camera.global_position=runtime.player.global_position+Vector3(0,42,38)
        camera.look_at(runtime.player.global_position-Vector3(0,8,0),Vector3.UP)
        if i==450:
            runtime.player.global_position=spawn
            if not _attempt_real_edit(runtime,water):
                return
            edited=true
        if not _step(runtime,water,50000000):
            return
        var state: Dictionary=runtime.session.hydraulic_report()
        if int(state["litres"])!=int(state["initial"])+int(state["injected"])-int(state["drained"]):
            _fail("gameplay mass ledger "+str(state))
            return
        copy_peak=maxi(copy_peak,int(state["max_snapshot_us"]))
        tick_peak=maxi(tick_peak,int(state["max_tick_us"]))
        await process_frame
        var now:=Time.get_ticks_usec()
        frames.append(now-previous)
        previous=now
    var elapsed_s:=float(Time.get_ticks_usec()-sample_start)/1000000.0
    frames.sort()
    var p95:=_percentile(frames,0.95)
    var p99:=_percentile(frames,0.99)
    var slow20:=0
    var slow33:=0
    for d in frames:
        if d>20000:
            slow20+=1
        if d>33333:
            slow33+=1
    var final: Dictionary=runtime.session.hydraulic_report()
    var visual: Dictionary=water.call("get_report")
    if not edited or int(runtime.session.get_state()["terrain_revision"])<=initial_revision or int(final["ticks"])<=int(published_before["ticks"]) or int(visual["meshes"])<=0:
        _fail("gameplay interaction or presentation absent "+str(final))
        return
    if not await _capture("11-benchmark-after"):
        return
    var evidence: Dictionary={
        "schema":"v3-hybrid-gameplay-benchmark-1",
        "frames":frames.size(),"elapsed_s":elapsed_s,
        "fps":float(frames.size())/elapsed_s,
        "p95_frame_ms":float(p95)*0.001,
        "p99_frame_ms":float(p99)*0.001,
        "max_frame_ms":float(frames.back())*0.001,
        "1pct_low_fps":1000000.0/float(maxi(1,_percentile(frames,0.99))),
        "0_1pct_low_fps":1000000.0/float(maxi(1,_percentile(frames,0.999))),
        "frames_over_20ms":slow20,"frames_over_33ms":slow33,
        "max_snapshot_ms":float(copy_peak)*0.001,
        "max_solver_tick_ms":float(tick_peak)*0.001,
        "solver_p95_ms":float(final.get("tick_p95_us",0))*0.001,
        "publish_p95_ms":float(visual.get("publish_refresh_p95_us",0))*0.001,
        "publish_p99_ms":float(visual.get("publish_refresh_p99_us",0))*0.001,
        "voxel_copy_p95_ms":float(final.get("voxel_copy_p95_us",0))*0.001,
        "classification_p95_ms":float(final.get("classification_p95_us",0))*0.001,
        "hot_tiles":int(final["tiles"]),"visible_wet_tiles":int(final["visible_wet_tiles"]),
        "mesh_allocations":int(visual["mesh_allocations"]),"buffer_updates":int(visual["buffer_updates"]),
        "cold_io_read_p95_upper_us":int(final.get("cold_io_read_p95_upper_us",0)),
        "cold_io_write_p95_upper_us":int(final.get("cold_io_write_p95_upper_us",0)),
        "terrain_edits":int(runtime.session.get_state()["terrain_revision"])-initial_revision
    }
    print("V3_HYBRID_GAMEPLAY_BENCH_PASS "+JSON.stringify(evidence))
    # Same game process: move the actual VoxelViewer to the lava source
    # and inspect its GL Compatibility visual output, not a static sprite.
    runtime.player.global_position=Vector3(48,12,-28)
    camera.global_position=runtime.player.global_position+Vector3(0,36,20)
    camera.look_at(Vector3(48,0,-28),Vector3.UP)
    var lava_ready:=false
    var lava_deadline:=Time.get_ticks_msec()+30000
    while Time.get_ticks_msec()<lava_deadline:
        if not _step(runtime,water,0):
            return
        var lava_state: Dictionary=runtime.session.hydraulic_report()
        if "hydro:lava_pool" in lava_state.get("source_ids",[]) and int(lava_state["near_active_tiles"])>=9 and int(water.call("get_report")["meshes"])>0:
            lava_ready=true
            break
        await process_frame
    if not lava_ready:
        _fail("lava gameplay viewport not ready")
        return
    var sampled:=false
    for z in range(-44,-12):
        for x in range(32,64):
            for yy in range(-12,32):
                var liquid: Dictionary=runtime.session.hydraulic_at(Vector3(x+0.5,yy+0.5,z+0.5))
                if not liquid.is_empty() and float(liquid["density"])==2800.0:
                    sampled=true
                    break
            if sampled:
                break
        if sampled:
            break
    if not sampled:
        _fail("lava physical presence absent during GPU visit")
        return
    if not await _capture("12-lava-viewport"):
        return
    print("V3_HYBRID_LAVA_GPU_PASS density=2800 source=hydro:lava_pool")
    runtime.request_close()
