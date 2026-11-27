extends SceneTree
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
    return true

# Diagnostic of the exact fixed-camera pixels lost in H9/H10. Inspect
# actual visible meshes and their shader clipping, not only graph rows.
func _diagnose_seams(water: Node3D,camera: Camera3D,label: String) -> void:
    var nodes: Dictionary=water.get("_meshes")
    var tiles: Dictionary=water.get("_mesh_tiles")
    for pixel: Vector2 in [Vector2(180.5,188.5),Vector2(180.5,189.5),Vector2(180.5,190.5),Vector2(513.5,47.5),Vector2(575.5,280.5),Vector2(590.5,283.5)]:
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
            if q.x<float(tile.x)-0.1 or q.x>float(tile.x+16)+0.1 or q.z<float(tile.z)-0.1 or q.z>float(tile.z+16)+0.1:
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
    print("V3_GPU_VISUAL_FIXTURE_PASS")
    runtime.request_close()
