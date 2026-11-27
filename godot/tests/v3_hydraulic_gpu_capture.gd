extends SceneTree
var _comparison_water: Node3D
var _comparison_runtime: Node
func _initialize() -> void:
    call_deferred("_test")
func _fail(reason: String) -> void:
    push_error("V3_HYDRAULIC_RUNTIME_FAIL: "+reason)
    quit(1)
func _capture(name: String) -> bool:
    await process_frame
    await RenderingServer.frame_post_draw
    var image:=root.get_texture().get_image()
    if image==null or image.is_empty() or image.get_width()<640 or image.get_height()<360:
        _fail("invalid rendered viewport "+name)
        return false
    var destination:=OS.get_environment("V3_GPU_CAPTURE_ROOT").path_join(name+".png")
    if image.save_png(destination)!=OK:
        _fail("cannot save viewport "+name)
        return false
    print("V3_GPU_CAPTURE_PASS name=",name," size=",image.get_size())
    if is_instance_valid(_comparison_water):
        var baseline: Dictionary=_comparison_runtime.session.hydraulic_report()
        var a_nodes: Dictionary=_comparison_water.get("_meshes")
        var a_visible: Array[MeshInstance3D]=[]
        var a_triangles:=0
        for node: MeshInstance3D in a_nodes.values():
            if node.visible:
                a_visible.append(node)
                a_triangles+=int(node.mesh.surface_get_array_len(0)/3.0)
        var a_draws:=RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
        var deadline:=Time.get_ticks_msec()+20000
        var status: Dictionary=_comparison_water.call("hybrid_refresh")
        var digest: String=status["digest"]
        # On the immediate edit frame the old revision must be retained,
        # not forced to publish by advancing physics for the screenshot.
        if int(baseline["pending_edit_tiles"])==0:
            while not bool(status["ready"]):
                await process_frame
                status=_comparison_water.call("hybrid_refresh")
                if Time.get_ticks_msec()>deadline:
                    _fail("R1 snapshot publication timeout "+str(status))
                    return false
        if status["digest"]!=digest or _comparison_runtime.session.hydraulic_report()!=baseline:
            _fail("R1 changed physical state during frozen replay")
            return false
        for node in a_visible:
            node.visible=false
        _comparison_water.call("hybrid_display",true)
        await process_frame
        await RenderingServer.frame_post_draw
        var b_image:=root.get_texture().get_image()
        var b_draws:=RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
        var b_report: Dictionary=_comparison_water.call("hybrid_report")
        _comparison_water.call("hybrid_display",false)
        for node in a_visible:
            node.visible=true
        if b_image==null or b_image.is_empty() or int(b_report["meshes"])<=0:
            _fail("R1 empty B viewport")
            return false
        if b_image.save_png(OS.get_environment("V3_GPU_CAPTURE_ROOT").path_join(name+"-B.png"))!=OK:
            _fail("R1 cannot save B viewport")
            return false
        # RGB mask is a heuristic, not a proof of wet world occupancy.
        var a_only:=0
        var b_only:=0
        var shared:=0
        for z in range(0,image.get_height(),2):
            for x in range(0,image.get_width(),2):
                var ca:=image.get_pixel(x,z)
                var cb:=b_image.get_pixel(x,z)
                var aw:=ca.b>ca.r*1.25 and ca.g>ca.r*1.1
                var bw:=cb.b>cb.r*1.25 and cb.g>cb.r*1.1
                if aw and bw:
                    shared+=1
                elif aw:
                    a_only+=1
                elif bw:
                    b_only+=1
        print("V3_R1_AB name=",name," digest=",digest," A_meshes=",a_visible.size()," A_triangles=",a_triangles," A_draws=",a_draws," B_draws=",b_draws," mask_shared=",shared," mask_A_only=",a_only," mask_B_only=",b_only," B=",b_report)
    return true

# Diagnostic of the exact fixed-camera pixels lost in H9/H10. Inspect
# actual visible meshes and their shader clipping, not only graph rows.
func _diagnose_seams(water: Node3D,camera: Camera3D,label: String) -> void:
    var nodes: Dictionary=water.get("_meshes")
    var tiles: Dictionary=water.get("_mesh_tiles")
    for pixel: Vector2 in [Vector2(180.5,188.5),Vector2(180.5,189.5),Vector2(180.5,190.5),Vector2(513.5,47.5),Vector2(575.5,280.5),Vector2(590.5,283.5),Vector2(289.5,456.5),Vector2(293.5,478.5),Vector2(301.5,459.5),Vector2(300.5,480.5)]:
        var origin:=camera.project_ray_origin(pixel)
        var ray:=camera.project_ray_normal(pixel)
        var evidence: Array=[]
        for id: int in nodes:
            var node: MeshInstance3D=nodes[id]
            if not node.visible or absf(ray.y)<0.0001:
                continue
            var distance:=(node.global_position.y-origin.y)/ray.y
            if distance<=0.0:
                continue
            var q:=origin+ray*distance
            var tile: Vector3i=tiles[id]
            if q.x<float(tile.x)-1.01 or q.x>float(tile.x+16)+1.01 or q.z<float(tile.z)-1.01 or q.z>float(tile.z+16)+1.01:
                continue
            var arrays: Array=node.mesh.surface_get_arrays(0)
            var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
            var uv: PackedVector2Array=arrays[Mesh.ARRAY_TEX_UV]
            var hits: Array=[]
            var p:=Vector2(q.x,q.z)
            for i in range(0,vertices.size(),3):
                var a:=Vector2(vertices[i].x,vertices[i].z)
                var b:=Vector2(vertices[i+1].x,vertices[i+1].z)-a
                var c:=Vector2(vertices[i+2].x,vertices[i+2].z)-a
                var d:=p-a
                var det:=b.cross(c)
                if absf(det)<0.000001:
                    continue
                var v:=d.cross(c)/det
                var w:=b.cross(d)/det
                var u:=1.0-v-w
                if minf(u,minf(v,w))< -0.00001:
                    continue
                var clip: Vector2=uv[i]*u+uv[i+1]*v+uv[i+2]*w
                hits.append({"floor":clip.x,"ceiling":clip.y,"discard":q.y>=clip.y-0.001 or q.y<clip.x})
            if not hits.is_empty():
                evidence.append({"id":id,"tile":str(tile),"head":q.y,"xz":str(p),"hits":hits})
            elif absf(q.x-roundf(q.x))<0.15 or absf(q.z-roundf(q.z))<0.15:
                evidence.append({"id":id,"tile":str(tile),"head":q.y,"xz":str(p),"hits":[]})
        print("V3_GPU_SEAM_DIAG ",label," pixel=",pixel," ",JSON.stringify(evidence))

func _sdf_at(tool: VoxelTool,p: Vector3) -> float:
    var base:=Vector3i(p.floor())
    var frac:=p-Vector3(base)
    var sdf:=0.0
    for dz in range(2):
        for dy in range(2):
            for dx in range(2):
                var weight: float=(frac.x if dx else 1.0-frac.x)*(frac.y if dy else 1.0-frac.y)*(frac.z if dz else 1.0-frac.z)
                sdf+=weight*tool.get_voxel_f(base+Vector3i(dx,dy,dz))
    return sdf

func _diagnose_bank(runtime,tool: VoxelTool,camera: Camera3D) -> void:
    for y: float in [380.5,460.5,520.5]:
        var row: Array=[]
        for x: float in [760.5,765.5,767.5,770.5,775.5,785.5]:
            var pixel:=Vector2(x,y)
            var origin:=camera.project_ray_origin(pixel)
            var ray:=camera.project_ray_normal(pixel)
            var p:=origin+ray*((4.0-origin.y)/ray.y)
            if not tool.is_area_editable(AABB(Vector3(p.floor()),Vector3(2,2,2))):
                row.append({"pixel":x,"point":str(p),"unknown":true})
                continue
            var wet: Dictionary=runtime.session.hydraulic_at(p-Vector3(0,0.05,0))
            row.append({"pixel":x,"point":str(p),"sdf":_sdf_at(tool,p),"wet":wet})
        print("V3_GPU_BANK_DIAG y=",y," ",JSON.stringify(row))

func _diagnose_cave_spots(runtime,tool: VoxelTool,camera: Camera3D) -> void:
    # These two small earth-coloured patches are already present before any edit.
    # Compare their actual terrain intersection with adjacent water pixels.
    for pixel: Vector2 in [Vector2(289.5,456.5),Vector2(293.5,478.5),Vector2(301.5,459.5),Vector2(300.5,480.5)]:
        var origin:=camera.project_ray_origin(pixel)
        var ray:=camera.project_ray_normal(pixel)
        var evidence: Array=[]
        for h: float in [4.5,4.25,4.0,3.75,3.5,3.0]:
            var p:=origin+ray*((h-origin.y)/ray.y)
            if not tool.is_area_editable(AABB(Vector3(p.floor()),Vector3(2,2,2))):
                evidence.append({"height":h,"unknown":true})
                continue
            var wet: Dictionary=runtime.session.hydraulic_at(p-Vector3(0,0.05,0))
            evidence.append({"height":h,"point":str(p),"sdf":_sdf_at(tool,p),"wet":wet})
        print("V3_GPU_CAVE_SPOT_DIAG pixel=",pixel," ",JSON.stringify(evidence))
    for x in range(-40,-33):
        for z in range(33,40):
            var p:=Vector3(x,4,z)
            if not tool.is_area_editable(AABB(p-Vector3(0,5,0),Vector3(1,12,1))):
                continue
            var signs: String=""
            for y in range(-1,11):
                signs+="+" if tool.get_voxel_f(Vector3i(x,y,z))>0.1 else "-"
            print("V3_GPU_CAVE_COLUMN x=",x," z=",z," y=-1..10 ",signs)


func _visible_tiles(water: Node3D) -> Dictionary:
    var nodes: Dictionary=water.get("_meshes")
    var tiles: Dictionary=water.get("_mesh_tiles")
    var result: Dictionary={}
    for id: int in nodes:
        if (nodes[id] as MeshInstance3D).visible:
            result[tiles[id]]=true
    return result

func _next_shore_cut(runtime,tool: VoxelTool,previous: Array[Vector3]) -> Variant:
    # Search the known resident lake, require actual wet floor next to solid.
    # Distinct centers prevent eight no-op excavations of the same hole.
    for z in range(-64,64,2):
        for x in range(-88,24,2):
            for y in range(-12,4):
                var p:=Vector3(float(x)+0.5,float(y)+0.15,float(z)+0.5)
                var wet: Dictionary=runtime.session.hydraulic_at(p)
                if wet.is_empty() or absf(float(wet["floor"])-float(y))>0.01 or float(wet["level"])-p.y<0.35:
                    continue
                for direction: Vector3 in [Vector3.LEFT,Vector3.RIGHT,Vector3.FORWARD,Vector3.BACK]:
                    var shore:=p+direction
                    var target:=shore-Vector3(0,1.65,0)
                    if not tool.is_area_editable(AABB(target-Vector3(5,5,5),Vector3(10,10,10))):
                        continue
                    if not runtime.session.hydraulic_at(shore).is_empty() or tool.get_voxel_f(Vector3i(shore.floor()))>=-0.1 or tool.get_voxel_f(Vector3i(target.floor()))>=-0.1:
                        continue
                    var distinct:=true
                    for old: Vector3 in previous:
                        if old.distance_to(target)<4.0:
                            distinct=false
                            break
                    if distinct:
                        return target
    return null

func _stress_shore(runtime,water: Node3D,tool: VoxelTool,first: Vector3,mass: int) -> bool:
    var previous: Array[Vector3]=[first]
    var accepted:=0
    var holds:=0
    var portal_moved:=int(runtime.session.hydraulic_report()["moved"])
    while accepted<8:
        var candidate: Variant=_next_shore_cut(runtime,tool,previous)
        if candidate==null:
            _fail("stress: insufficient distinct shore positions "+str(accepted))
            return false
        var target: Vector3=candidate
        previous.append(target)
        if runtime.submit_brush(target,false,3.0)!="accepted":
            if previous.size()>48:
                _fail("stress: too many rejected positions")
                return false
            continue
        accepted+=1
        var old_tiles:=_visible_tiles(water)
        var deadline:=Time.get_ticks_msec()+20000
        water.call("refresh")
        var first_wet:=-1
        for step in range(400):
            if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,50000000):
                _fail("stress: hydraulic frame")
                return false
            water.call("refresh")
            var swap: Dictionary=water.get("_swap_group")
            var current:=_visible_tiles(water)
            if not swap.is_empty():
                holds+=1
                for tile: Vector3i in old_tiles:
                    if swap.has(tile) and not current.has(tile):
                        _fail("stress: visible tile disappeared before grouped swap "+str(tile))
                        return false
            if int(runtime.session.hydraulic_report()["litres"])!=mass:
                _fail("stress: lost mass")
                return false
            if first_wet<0:
                var wet_probe: Variant=_wet_breach_probe(runtime,target,3.0)
                if wet_probe!=null:
                    print("V3_GPU_STRESS_WET point=",wet_probe)
                    first_wet=step+1
            if step>=39 and int(runtime.session.hydraulic_report()["pending_edit_tiles"])==0 and swap.is_empty():
                break
            if Time.get_ticks_msec()>deadline or step==399:
                _fail("stress: edit publication timeout "+str(runtime.session.hydraulic_report()))
                return false
            await process_frame
        if first_wet<0:
            _fail("stress: excavated floor never filled "+str(target))
            return false
        for i in range(runtime.session.hydraulic_surfaces().size()+1):
            water.call("refresh")
        print("V3_GPU_STRESS_EDIT index=",accepted," point=",target," first_wet_step=",first_wet," state=",runtime.session.hydraulic_report()," presentation=",water.call("get_report"))
        if not await _capture("%02d-stress-edit" % (accepted+5)):
            return false
    for step in range(100):
        if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,50000000):
            _fail("stress: settling frame")
            return false
        water.call("refresh")
        await process_frame
    for i in range(runtime.session.hydraulic_surfaces().size()+1):
        water.call("refresh")
    if int(runtime.session.hydraulic_report()["litres"])!=mass:
        _fail("stress: settling mass")
        return false
    if not await _capture("14-stress-settled"):
        return false
    print("V3_GPU_STRESS_PASS transfer_delta=",int(runtime.session.hydraulic_report()["moved"])-portal_moved," accepted=",accepted," observed_group_holds=",holds," state=",runtime.session.hydraulic_report()," presentation=",water.call("get_report"))
    return true

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

func _wet_breach_probe(runtime,center: Vector3,radius: float) -> Variant:
    # A new cavity need not fill to the brush center: test points inside
    # the excavated volume, on the destination tile, below its center.
    var tile:=_tile_key(center)
    for y in range(0,int((radius-0.75)*2)+1):
        for dz in range(-1,2):
            for dx in range(-1,2):
                var p:=center+Vector3(float(dx)*0.5,-float(y)*0.5,float(dz)*0.5)
                if _tile_key(p)!=tile or p.distance_to(center)>=radius-0.5:
                    continue
                if not runtime.session.hydraulic_at(p).is_empty():
                    return p
    return null

func _move_during_flow(runtime,water: Node3D,tool: VoxelTool,first: Vector3,mass: int) -> bool:
    var previous: Array[Vector3]=[first]
    var target: Variant=_next_shore_cut(runtime,tool,previous)
    if target==null or runtime.submit_brush(target,false,3.0)!="accepted":
        _fail("movement: no fresh wet shore edit")
        return false
    var start: Vector3=runtime.player.global_position
    var before: Dictionary=runtime.session.hydraulic_report()
    var route: Array[Vector3]=[Vector3(0,12,68),Vector3(64,12,68),Vector3(64,12,0),Vector3(0,12,-48),Vector3(-80,12,-16),Vector3(-80,12,40),start]
    var travelled:=0.0
    var steps:=0
    var deadline:=Time.get_ticks_msec()+120000
    for index in range(route.size()):
        var waypoint: Vector3=route[index]
        while runtime.player.global_position.distance_to(waypoint)>0.001:
            var prior: Vector3=runtime.player.global_position
            runtime.player.global_position=prior.move_toward(waypoint,0.9)
            travelled+=prior.distance_to(runtime.player.global_position)
            steps+=1
            if not runtime.session.update_interest(runtime.player.global_position) or runtime.session.advance_ticks(50000000,4)<0:
                _fail("movement scheduler: "+runtime.session.get_last_error())
                return false
            if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,50000000):
                _fail("movement hydraulic: "+runtime.session.get_last_error()+" "+str(runtime.session.hydraulic_report()))
                return false
            water.call("refresh")
            var report: Dictionary=runtime.session.hydraulic_report()
            if int(report["litres"])!=mass or int(water.call("get_report")["visible_meshes"])==0:
                _fail("movement: mass or visible reservoir lost")
                return false
            if Time.get_ticks_msec()>deadline:
                _fail("movement timeout "+str(report))
                return false
            await process_frame
        print("V3_GPU_MOVEMENT_WAYPOINT index=",index," position=",waypoint," state=",runtime.session.hydraulic_report())
        if index==0 and not await _capture("15-moving-shore"):
            return false
    for step in range(100):
        if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,50000000):
            _fail("movement return: "+runtime.session.get_last_error())
            return false
        water.call("refresh")
        await process_frame
    var after: Dictionary=runtime.session.hydraulic_report()
    if int(after["litres"])!=mass or int(after["moved"])<=int(before["moved"]) or int(after["pending_edit_tiles"])!=0:
        _fail("movement did not finish with active transfer and exact mass "+str(after))
        return false
    if int(after["peak_volumes"])<=4096:
        _fail("movement did not cross original volume budget "+str(after))
        return false
    for i in range(runtime.session.hydraulic_surfaces().size()+1):
        water.call("refresh")
    if not await _capture("16-return-to-lake"):
        return false
    print("V3_GPU_MOVEMENT_PASS distance_m=",travelled," steps=",steps," transfer_delta=",int(after["moved"])-int(before["moved"])," state=",after)
    return true

func _test() -> void:
    var write:=true
    if DisplayServer.get_name()=="headless" or OS.get_environment("V3_GPU_CAPTURE_ROOT").is_empty():
        _fail("GPU capture requires actual graphical viewport")
        return
    print("V3_GPU_RENDERER=",RenderingServer.get_video_adapter_name())
    var runtime=load("res://scenes/v3_hydraulic_main.tscn").instantiate()
    root.add_child(runtime)
    if not runtime.running:
        _fail("startup")
        return
    runtime.set_process(false)
    runtime.player.set_process(false)
    runtime.player.set_physics_process(false)
    var water: Node3D=runtime.world.get_node("Water")
    if OS.get_environment("V3_HYBRID_COMPARE")=="1":
        _comparison_water=water
        _comparison_runtime=runtime
    water.set_process(false)
    water.set_physics_process(false)
    runtime.player.global_position=Vector3(-4,12,28)
    runtime.player.set_process_unhandled_input(false)
    runtime.set_process_input(false)
    runtime.world.get_node("EditController").set_process(false)
    runtime.world.get_node("EditController").set_process_unhandled_input(false)
    Input.mouse_mode=Input.MOUSE_MODE_VISIBLE
    var camera: Camera3D=runtime.player.get_node("Camera3D")
    camera.global_position=Vector3(-4,48,48)
    camera.look_at(Vector3(-4,0,23),Vector3.UP)
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
    if int(presentation["meshes"])!=expected or int(presentation["visible_meshes"])!=expected or expected<1:
        _fail("surface missing")
        return
    if not await _capture("01-initial-lake"):
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
        _diagnose_bank(runtime,tool,camera)
        _diagnose_cave_spots(runtime,tool,camera)
        var cut:=Vector3.ZERO
        var found:=false
        for z in range(16,32):
            if found:
                break
            for x in range(-16,0):
                if found:
                    break
                for y in range(-12,4):
                    var p:=Vector3(float(x)+0.5,float(y)+0.15,float(z)+0.5)
                    var wet: Dictionary=runtime.session.hydraulic_at(p)
                    if wet.is_empty() or absf(float(wet["floor"])-float(y))>0.01:
                        continue
                    if float(wet["level"])-p.y<0.35:
                        continue
                    for direction: Vector3 in [Vector3.LEFT,Vector3.RIGHT,Vector3.FORWARD,Vector3.BACK]:
                        var shore:=p+direction
                        if not runtime.session.hydraulic_at(shore).is_empty():
                            continue
                        if tool.get_voxel_f(Vector3i(shore.floor()))>=-0.1:
                            continue
                        var target:=shore-Vector3(0,1.65,0)
                        if tool.get_voxel_f(Vector3i(target.floor()))>=-0.1:
                            continue
                        cut=target
                        found=true
                        break
                    if found:
                        break
        if not found:
            _fail("no submerged sample beside a solid shore for lateral breach")
            return
        # Materialize the current presentation and verify the edit does
        # not make the old reservoir disappear before worker publication.
        for i in range(runtime.session.hydraulic_surfaces().size()+1):
            water.call("refresh")
        var old_count:=int(water.call("get_report")["visible_meshes"])
        print("V3_GPU_EDIT_POINT=",cut)
        if not await _capture("02-before-edit"):
            return
        _diagnose_seams(water,camera,"before")
        if runtime.submit_brush(cut,false,3.0)!="accepted":
            _fail("wet floor excavation rejected")
            return
        water.call("refresh")
        if old_count<1 or int(water.call("get_report")["visible_meshes"])!=old_count:
            _fail("water disappeared immediately on edit")
            return
        print("V3_HYDRAULIC_EDIT_RETENTION_PASS meshes=",old_count)
        if not await _capture("03-immediate-edit"):
            return
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
            water.call("refresh")
            await process_frame
        for i in range(runtime.session.hydraulic_surfaces().size()+1):
            water.call("refresh")
        var group: Dictionary=water.call("get_report")
        if int(group.get("group_holds",0))<1 or int(group.get("group_swaps",0))<1:
            _fail("missing atomic edit group hold/swap evidence "+str(group))
            return
        print("V3_GPU_GROUP_PASS ",group)
        if not await _capture("04-settled-edit"):
            return
        _diagnose_seams(water,camera,"settled")
        var after: Dictionary=runtime.session.hydraulic_report()
        if int(after["litres"])!=mass or int(after["ticks"])!=before_ticks+20:
            _fail("settling "+str(after))
            return
        print("V3_GPU_LOCAL_REMAP_OR_TRANSFER_PASS moved=",after["moved"])
        # Distinguish a transient remap head from a persistent geometric gap.
        for i in range(100):
            if not runtime.session.hydraulic_frame(runtime.world,runtime.player.global_position,50000000):
                _fail("equilibration frame")
                return
            water.call("refresh")
            await process_frame
        for i in range(runtime.session.hydraulic_surfaces().size()+1):
            water.call("refresh")
        if int(runtime.session.hydraulic_report()["litres"])!=mass:
            _fail("equilibration mass")
            return
        if not await _capture("05-equilibrated-edit"):
            return
        _diagnose_seams(water,camera,"equilibrated")
        print("V3_GPU_EQUILIBRATED_REPORT ",runtime.session.hydraulic_report()," ",water.call("get_report"))
        if not await _stress_shore(runtime,water,tool,cut,mass):
            return
        if not await _move_during_flow(runtime,water,tool,cut,mass):
            return
        # Dry excavation isolated from the surface source must not create mass.
        var prior:=int(runtime.session.hydraulic_report()["publications"])
        deadline=Time.get_ticks_msec()+20000
        var dry:=Vector3(-4,-20,28)
        if runtime.submit_brush(dry,false,3.0)!="accepted":
            _fail("dry excavation")
            return
        if not runtime.session.hydraulic_at(dry).is_empty():
            _fail("instant fill")
            return
        while int(runtime.session.hydraulic_report()["publications"])<=prior or int(runtime.session.hydraulic_report()["pending_edit_tiles"])>0:
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
    print("V3_GPU_VISUAL_FIXTURE_PASS")
    runtime.request_close()
