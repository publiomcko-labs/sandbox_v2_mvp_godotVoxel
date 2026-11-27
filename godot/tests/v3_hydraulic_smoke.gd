extends SceneTree
func _initialize() -> void:
    call_deferred("_test")
func _fail(reason: String) -> void:
    push_error("V3_HYDRAULIC_RUNTIME_FAIL: "+reason)
    quit(1)
func _tile_key(p: Vector3) -> Vector3i:
    return Vector3i(floori(p.x/16.0)*16,-32,floori(p.z/16.0)*16)

func _cross_tile_cut(runtime,tool: VoxelTool,previous: Array[Vector3]) -> Variant:
    # Find a solid point in a dry adjacent tile whose radius-6 excavation
    # actually overlaps an existing water body. The dry tile has no mass
    # to remap, so its first wet sample must come from portal discharge.
    var wet_tiles: Dictionary={}
    for row: Array in runtime.session.hydraulic_surfaces():
        wet_tiles[row[3]]=true
    for z in range(-64,64):
        for x in range(-88,24):
            var source_tile:=_tile_key(Vector3(x+0.5,0,z+0.5))
            if not wet_tiles.has(source_tile):
                continue
            for direction: Vector3 in [Vector3.LEFT,Vector3.RIGHT,Vector3.FORWARD,Vector3.BACK]:
                for distance in range(1,5):
                    var tx:=float(x)+0.5+direction.x*distance
                    var tz:=float(z)+0.5+direction.z*distance
                    var target_tile:=_tile_key(Vector3(tx,0,tz))
                    if target_tile==source_tile or wet_tiles.has(target_tile):
                        continue
                    for y in range(-10,4):
                        var p:=Vector3(float(x)+0.5,float(y)+0.5,float(z)+0.5)
                        var wet: Dictionary=runtime.session.hydraulic_at(p)
                        if wet.is_empty() or float(wet["level"])-p.y<0.5:
                            continue
                        var target:=Vector3(tx,p.y-0.5,tz)
                        if not tool.is_area_editable(AABB(target-Vector3(8,8,8),Vector3(16,16,16))):
                            continue
                        if not runtime.session.hydraulic_at(target).is_empty() or tool.get_voxel_f(Vector3i(target.floor()))>=-0.1:
                            continue
                        var distinct:=true
                        for old: Vector3 in previous:
                            if old.distance_to(target)<8.0:
                                distinct=false
                                break
                        if distinct:
                            print("V3_HYDRAULIC_CROSS_TILE_TARGET source=",source_tile," dry_target=",target_tile," point=",target)
                            return target
    return null

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
    # Each refresh can build at most two new meshes. Drain the initial
    # publication queue before testing stability at unchanged geometry.
    var expected: int=runtime.session.hydraulic_surfaces().size()
    for i in range(expected+1):
        water.call("refresh")
    var presentation: Dictionary=water.call("get_report")
    if int(presentation["meshes"])!=expected or expected<1:
        _fail("surface missing")
        return
    var varying_floor:=false
    for row: Array in runtime.session.hydraulic_surfaces():
        var raw: Array=runtime.session.hydraulic_mesh(int(row[0]))
        if raw.size()!=2:
            continue
        var uv: PackedVector2Array=raw[1]
        if uv.is_empty():
            continue
        for sample: Vector2 in uv:
            if absf(sample.x-uv[0].x)>0.1:
                varying_floor=true
                break
    if write and not varying_floor:
        _fail("source basin mesh has no interpolated floor")
        return
    if write:
        print("V3_HYDRAULIC_BASIN_RUNTIME_PASS varying_floor=true")
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
        # Wet expansion can make nine remote tiles ready before the source
        # shore is revalidated. Wait for the actual near-field window.
        if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,0):
            _fail("restore center")
            return
        while int(runtime.session.hydraulic_report()["near_active_tiles"])<9:
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
        var no_previous: Array[Vector3]=[]
        var candidate: Variant=null
        for attempt in range(12):
            candidate=_cross_tile_cut(runtime,tool,no_previous)
            if candidate!=null:
                break
            for step in range(12):
                if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,0):
                    _fail("cross-tile readiness")
                    return
                await process_frame
        if candidate==null:
            _fail("no resident wet-to-dry tile boundary for lateral breach")
            return
        var cut: Vector3=candidate
        # Materialize the current presentation and verify the edit does
        # not make the old reservoir disappear before worker publication.
        for i in range(runtime.session.hydraulic_surfaces().size()+1):
            water.call("refresh")
        var old_count:=int(water.call("get_report")["visible_meshes"])
        if runtime.submit_brush(cut,false,6.0)!="accepted":
            _fail("wet floor excavation rejected")
            return
        water.call("refresh")
        if old_count<1 or int(water.call("get_report")["visible_meshes"])!=old_count:
            _fail("water disappeared immediately on edit")
            return
        print("V3_HYDRAULIC_EDIT_RETENTION_PASS meshes=",old_count)
        var first_wet:=-1
        for i in range(201):
            if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,50000000):
                _fail("breach frame")
                return
            water.call("refresh")
            if int(water.call("get_report")["visible_meshes"])<1:
                _fail("water disappeared during replacement")
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
        print("V3_HYDRAULIC_WET_BREACH_PASS lateral_shore=true point=",cut," observed_steps=",first_wet+1," mass=",mass)
        # Let every edited tile finish publication before the next brush.
        while int(runtime.session.hydraulic_report()["near_active_tiles"])<9 or int(runtime.session.hydraulic_report()["pending_edit_tiles"])>0:
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
