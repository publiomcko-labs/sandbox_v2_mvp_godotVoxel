extends Node3D
# Mesh topology is immutable for a published compartment. Only Y/visibility
# change as litres cross a portal. No wet-cell meshes or marching surfaces.
var session: V3WorldSession
var world: WorldBootstrap
var _rocks: Node3D
var _materials: Array[ShaderMaterial]=[]
var _flow_materials: Array[ShaderMaterial]=[]
var _flow_nodes: Dictionary={}
var _flow_previous: Dictionary={}
var _flow_quads:=0
var _initial_presented:=false
var _initial_cohort: Dictionary={}
var _meshes: Dictionary={}
var _mesh_tiles: Dictionary={}
var _deferred_swaps:=0
var _swap_group: Dictionary={}
var _last_edit_group_revision:=0
var _group_swaps:=0
var _group_holds:=0
var _next_update:=0
var _mesh_builds:=0
var _level_updates:=0
var _max_update_usec:=0
var _hybrid_only:=OS.get_environment("V3_HYBRID_RENDERER")=="B" or OS.get_environment("V3_HYBRID_SOLVER")=="1"
var _hybrid_display:=_hybrid_only
var _hybrid_nodes: Dictionary={}
var _hybrid_stage: Dictionary={}
var _hybrid_ready:=false
var _hybrid_builds:=0
var _hybrid_build_us: Array[int]=[]
var _hybrid_publish_us: Array[int]=[]
var _hybrid_snapshot_us: Array[int]=[]
var _hybrid_fallback_columns:=0
var _hybrid_digest:=""
var _hybrid_group: Dictionary={}
var _hybrid_group_revision:=0
var _hybrid_holds:=0
var _hybrid_swaps:=0

func _ready() -> void:
    _rocks=world.get_node("RockManager") as Node3D
    var config: Dictionary=JSON.parse_string(session.get_hydraulic_json())
    for item: Dictionary in config["liquids"]:
        var c: Array=item["albedo"]
        var e: Array=item["emission"]
        var mat:=ShaderMaterial.new()
        mat.shader=preload("res://shaders/v3_hydraulic_water.gdshader")
        mat.set_shader_parameter("liquid_color",Color(float(c[0]),float(c[1]),float(c[2]),1.0))
        mat.set_shader_parameter("liquid_emission",Vector3(float(e[0]),float(e[1]),float(e[2])))
        mat.set_shader_parameter("viscosity",float(item["viscosity"]))
        _materials.append(mat)
        var flow_mat:=ShaderMaterial.new()
        flow_mat.shader=preload("res://shaders/v3_hydraulic_flow.gdshader")
        flow_mat.set_shader_parameter("liquid_color",Color(float(c[0]),float(c[1]),float(c[2]),1.0))
        flow_mat.set_shader_parameter("liquid_emission",Vector3(float(e[0]),float(e[1]),float(e[2])))
        flow_mat.set_shader_parameter("viscosity",float(item["viscosity"]))
        _flow_materials.append(flow_mat)

func refresh() -> void:
    if _hybrid_only:
        hybrid_refresh()
        var flow_rows: Dictionary={}
        for row: Array in session.hydraulic_surfaces():
            if row.size()>4:
                flow_rows[int(row[0])]=[int(row[1]),row[4]]
        _refresh_flow(flow_rows)
        return
    var start:=Time.get_ticks_usec()
    var live: Dictionary={}
    var wanted: Dictionary={}
    var flow_rows: Dictionary={}
    var builds:=0
    var state: Dictionary=session.hydraulic_report()
    var group_revision:=int(state.get("edit_group_revision",0))
    if group_revision!=_last_edit_group_revision:
        _last_edit_group_revision=group_revision
        for tile: Vector3i in state.get("edit_group_tiles",[]):
            _swap_group[tile]=true
    for row: Array in session.hydraulic_surfaces():
        var id:=int(row[0])
        live[id]=true
        if row.size()>4:
            flow_rows[id]=[int(row[1]),row[4]]
        var tile: Vector3i=row[3]
        wanted[tile]=int(wanted.get(tile,0))+1
        var node: MeshInstance3D
        if _meshes.has(id):
            node=_meshes[id]
        else:
            if builds>=2:
                continue
            var raw: Array=session.hydraulic_mesh(id)
            if raw.size()!=2:
                continue
            var vertices: PackedVector3Array=raw[0]
            if vertices.is_empty():
                continue
            var normals:=PackedVector3Array()
            normals.resize(vertices.size())
            normals.fill(Vector3.UP)
            var arrays: Array=[]
            arrays.resize(Mesh.ARRAY_MAX)
            arrays[Mesh.ARRAY_VERTEX]=vertices
            arrays[Mesh.ARRAY_NORMAL]=normals
            arrays[Mesh.ARRAY_TEX_UV]=raw[1]
            var mesh:=ArrayMesh.new()
            mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
            node=MeshInstance3D.new()
            node.mesh=mesh
            node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
            node.visible=false
            add_child(node)
            _meshes[id]=node
            _mesh_tiles[id]=tile
            builds+=1
            _mesh_builds+=1
        node.material_override=_materials[int(row[1])]
        node.position.y=float(row[2])
        _level_updates+=1
    # First presentation is a cohort across tiles, not the first available
    # single rectangular mesh. Existing per-tile atomic replacement remains
    # unchanged after startup. No physics or simulated time is hidden.
    if not _initial_presented and not live.is_empty():
        if _initial_cohort.is_empty():
            _initial_cohort=live.duplicate()
        var initial_ready:=true
        for id: int in _initial_cohort:
            if live.has(id) and not _meshes.has(id):
                initial_ready=false
                break
        if initial_ready:
            _initial_presented=true
            _initial_cohort.clear()
    # Replacement is atomic per tile, not per compartment. Never remove
    # the old visible water while the bounded new mesh queue is incomplete.
    var ready: Dictionary={}
    for id: int in _meshes.keys():
        if live.has(id):
            var tile: Vector3i=_mesh_tiles[id]
            ready[tile]=int(ready.get(tile,0))+1
    # All tiles touched by one (or overlapping) edit publish together.
    # A dry replacement is intentional only after the whole topology
    # group has published; while incomplete retain the previously visible
    # meshes and never expose partial new geometry.
    var group_ready:=int(state["pending_edit_tiles"])==0
    for tile: Vector3i in _swap_group:
        if int(ready.get(tile,0))!=int(wanted.get(tile,0)):
            group_ready=false
    if not _swap_group.is_empty():
        if group_ready:
            _group_swaps+=1
        else:
            _group_holds+=1
    for id: int in _meshes.keys():
        var tile: Vector3i=_mesh_tiles[id]
        var complete:=int(ready.get(tile,0))==int(wanted.get(tile,0))
        if _swap_group.has(tile):
            complete=complete and group_ready
        var node: MeshInstance3D=_meshes[id]
        if live.has(id):
            if complete and _initial_presented:
                node.visible=true
        elif complete or not node.visible:
            node.visible=false
            node.queue_free()
            _meshes.erase(id)
            _mesh_tiles.erase(id)
        else:
            _deferred_swaps+=1
    if group_ready:
        _swap_group.clear()
    _refresh_flow(flow_rows)
    _max_update_usec=maxi(_max_update_usec,Time.get_ticks_usec()-start)

func _free_hybrid_nodes(nodes: Array) -> void:
    for node: MeshInstance3D in nodes:
        node.visible=false
        node.queue_free()

func _commit_hybrid_tile(tile: Vector3i) -> void:
    if _hybrid_nodes.has(tile):
        _free_hybrid_nodes(_hybrid_nodes[tile])
        _hybrid_nodes.erase(tile)
    if _hybrid_stage.has(tile):
        _hybrid_nodes[tile]=_hybrid_stage[tile]
        _hybrid_stage.erase(tile)
        for node: MeshInstance3D in _hybrid_nodes[tile]:
            node.visible=_hybrid_display

func hybrid_display(enabled: bool) -> void:
    _hybrid_display=enabled
    for nodes: Array in _hybrid_nodes.values():
        for node: MeshInstance3D in nodes:
            node.visible=enabled

func hybrid_refresh() -> Dictionary:
    var started:=Time.get_ticks_usec()
    var state: Dictionary=session.hydraulic_report()
    var revision:=int(state["edit_group_revision"])
    if revision!=_hybrid_group_revision:
        _hybrid_group_revision=revision
        for tile: Vector3i in state["edit_group_tiles"]:
            _hybrid_group[tile]=true
            if _hybrid_stage.has(tile):
                _free_hybrid_nodes(_hybrid_stage[tile])
                _hybrid_stage.erase(tile)
    var data: Dictionary=session.hydraulic_hybrid()
    _hybrid_digest=str(data["physics_digest"])
    if _hybrid_snapshot_us.size()<4096:
        _hybrid_snapshot_us.append(int(data["snapshot_us"]))
    var wanted: Array=data["wanted"]
    var ready: Array=data["ready"]
    for row: Dictionary in data["updates"]:
        var tile: Vector3i=row["tile"]
        var nodes: Array=[]
        for material: Array in row["materials"]:
            var vertices: PackedVector3Array=material[1]
            if vertices.is_empty():
                continue
            var normals:=PackedVector3Array()
            normals.resize(vertices.size())
            normals.fill(Vector3.UP)
            var arrays: Array=[]
            arrays.resize(Mesh.ARRAY_MAX)
            arrays[Mesh.ARRAY_VERTEX]=vertices
            arrays[Mesh.ARRAY_NORMAL]=normals
            arrays[Mesh.ARRAY_TEX_UV]=material[2]
            var mesh:=ArrayMesh.new()
            mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
            var node:=MeshInstance3D.new()
            node.mesh=mesh
            node.material_override=_materials[int(material[0])]
            node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
            node.visible=false
            add_child(node)
            nodes.append(node)
        if _hybrid_stage.has(tile):
            _free_hybrid_nodes(_hybrid_stage[tile])
        _hybrid_stage[tile]=nodes
        _hybrid_builds+=1
        _hybrid_fallback_columns+=int(row["fallback_columns"])
        if _hybrid_build_us.size()<4096:
            _hybrid_build_us.append(int(row["build_us"]))
    var group_ready:=int(state["pending_edit_tiles"])==0
    for tile: Vector3i in _hybrid_group:
        if wanted.has(tile) and not ready.has(tile):
            group_ready=false
    for tile: Vector3i in _hybrid_stage.keys():
        if not wanted.has(tile):
            _free_hybrid_nodes(_hybrid_stage[tile])
            _hybrid_stage.erase(tile)
            continue
        if not _hybrid_group.has(tile) or group_ready:
            _commit_hybrid_tile(tile)
    for tile: Vector3i in _hybrid_nodes.keys():
        if not wanted.has(tile) and (not _hybrid_group.has(tile) or group_ready):
            _commit_hybrid_tile(tile)
    if not _hybrid_group.is_empty():
        if group_ready:
            _hybrid_swaps+=1
            _hybrid_group.clear()
        else:
            _hybrid_holds+=1
    _hybrid_ready=ready.size()==wanted.size() and _hybrid_stage.is_empty() and group_ready
    if _hybrid_publish_us.size()<4096:
        _hybrid_publish_us.append(Time.get_ticks_usec()-started)
    return {"ready":_hybrid_ready,"digest":_hybrid_digest,"wanted":wanted.size(),"current":ready.size()}

func _percentile(samples: Array[int],fraction: float) -> int:
    if samples.is_empty():
        return 0
    var sorted:=samples.duplicate()
    sorted.sort()
    return int(sorted[mini(sorted.size()-1,ceili(float(sorted.size())*fraction)-1)])

func hybrid_report() -> Dictionary:
    var triangles:=0
    var meshes:=0
    for nodes: Array in _hybrid_nodes.values():
        for node: MeshInstance3D in nodes:
            meshes+=1
            triangles+=int(node.mesh.surface_get_array_len(0)/3.0)
    return {"tiles":_hybrid_nodes.size(),"meshes":meshes,"triangles":triangles,"vertex_bytes_estimate":triangles*3*32,
        "builds":_hybrid_builds,"fallback_columns":_hybrid_fallback_columns,"group_holds":_hybrid_holds,"group_swaps":_hybrid_swaps,
        "worker_p95_us":_percentile(_hybrid_build_us,0.95),"worker_p99_us":_percentile(_hybrid_build_us,0.99),
        "snapshot_p95_us":_percentile(_hybrid_snapshot_us,0.95),"publish_refresh_p95_us":_percentile(_hybrid_publish_us,0.95),
        "publish_refresh_p99_us":_percentile(_hybrid_publish_us,0.99)}

func _refresh_flow(rows: Dictionary) -> void:
    var per_slot: Dictionary={}
    for id: int in rows:
        if not _hybrid_only and (not _meshes.has(id) or not (_meshes[id] as MeshInstance3D).visible):
            continue
        var slot:=int(rows[id][0])
        var vertices: PackedVector3Array=per_slot.get(slot,PackedVector3Array())
        var additional: PackedVector3Array=rows[id][1]
        vertices.append_array(additional)
        per_slot[slot]=vertices
    _flow_quads=0
    for slot in range(_flow_materials.size()):
        var vertices: PackedVector3Array=per_slot.get(slot,PackedVector3Array())
        _flow_quads+=int(vertices.size()/6.0)
        if vertices.is_empty() and not _flow_nodes.has(slot):
            continue
        if not _flow_nodes.has(slot):
            var created:=MeshInstance3D.new()
            created.mesh=ImmediateMesh.new()
            created.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
            add_child(created)
            _flow_nodes[slot]=created
        var node: MeshInstance3D=_flow_nodes[slot]
        node.visible=not vertices.is_empty()
        if _flow_previous.has(slot) and _flow_previous[slot]==vertices:
            continue
        _flow_previous[slot]=vertices
        var mesh:=node.mesh as ImmediateMesh
        mesh.clear_surfaces()
        if vertices.is_empty():
            continue
        mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES,_flow_materials[slot])
        for i in range(0,vertices.size(),3):
            var normal: Vector3=(vertices[i+1]-vertices[i]).cross(vertices[i+2]-vertices[i]).normalized()
            for j in range(3):
                mesh.surface_set_normal(normal)
                mesh.surface_add_vertex(vertices[i+j])
        mesh.surface_end()

func _process(_delta: float) -> void:
    var now:=Time.get_ticks_usec()
    if now>=_next_update:
        _next_update=now+50000
        refresh()

func immersion_at(center: Vector3,height: float) -> float:
    var wet:=0
    for i in range(5):
        if not session.hydraulic_at(center+Vector3(0,(float(i)/4.0-0.5)*height,0)).is_empty():
            wet+=1
    return float(wet)/5.0

func _physics_process(_delta: float) -> void:
    var processed:=0
    for child in _rocks.get_children():
        if processed>=24:
            break
        if not child is RigidBody3D or child.freeze:
            continue
        var body:=child as RigidBody3D
        var volume:=float(body.get_meta("a5_displaced_volume_m3",0.0))
        var radius:=float(body.get_meta("a5_water_radius_m",0.7))
        if volume<=0.0:
            continue
        var density:=0.0
        var wet:=0
        for offset: Vector3 in [Vector3.ZERO,Vector3.UP*radius,Vector3.DOWN*radius,Vector3.LEFT*radius,Vector3.RIGHT*radius,Vector3.BACK*radius,Vector3.FORWARD*radius]:
            var liquid:=session.hydraulic_at(body.global_position+offset)
            if not liquid.is_empty():
                density+=float(liquid["density"])
                wet+=1
        if wet>0:
            body.apply_central_force(Vector3.UP*(density/7.0)*9.81*volume-body.linear_velocity*2.0*body.mass*float(wet)/7.0)
            body.sleeping=false
        processed+=1

func get_report() -> Dictionary:
    if _hybrid_only:
        var report:=hybrid_report()
        report["visible_meshes"]=report["meshes"]
        report["flow_quads"]=_flow_quads
        return report
    var visible_meshes:=0
    for node: MeshInstance3D in _meshes.values():
        if node.visible:
            visible_meshes+=1
    return {"visible_meshes":visible_meshes,"deferred_swaps":_deferred_swaps,"meshes":_meshes.size(),"mesh_builds":_mesh_builds,"level_updates":_level_updates,"max_update_usec":_max_update_usec,"flow_quads":_flow_quads,"group_swaps":_group_swaps,"group_holds":_group_holds}
