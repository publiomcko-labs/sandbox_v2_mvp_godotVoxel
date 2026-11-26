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
var _meshes: Dictionary={}
var _mesh_tiles: Dictionary={}
var _deferred_swaps:=0
var _next_update:=0
var _mesh_builds:=0
var _level_updates:=0
var _max_update_usec:=0

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
    var start:=Time.get_ticks_usec()
    var live: Dictionary={}
    var wanted: Dictionary={}
    var flow_rows: Dictionary={}
    var builds:=0
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
    # Replacement is atomic per tile, not per compartment. Never remove
    # the old visible water while the bounded new mesh queue is incomplete.
    var ready: Dictionary={}
    for id: int in _meshes.keys():
        if live.has(id):
            var tile: Vector3i=_mesh_tiles[id]
            ready[tile]=int(ready.get(tile,0))+1
    for id: int in _meshes.keys():
        var tile: Vector3i=_mesh_tiles[id]
        var complete:=int(ready.get(tile,0))==int(wanted.get(tile,0))
        var node: MeshInstance3D=_meshes[id]
        if live.has(id):
            if complete:
                node.visible=true
        elif complete or not node.visible:
            node.visible=false
            node.queue_free()
            _meshes.erase(id)
            _mesh_tiles.erase(id)
        else:
            _deferred_swaps+=1
    _refresh_flow(flow_rows)
    _max_update_usec=maxi(_max_update_usec,Time.get_ticks_usec()-start)

func _refresh_flow(rows: Dictionary) -> void:
    var per_slot: Dictionary={}
    for id: int in rows:
        if not _meshes.has(id) or not (_meshes[id] as MeshInstance3D).visible:
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
    var visible_meshes:=0
    for node: MeshInstance3D in _meshes.values():
        if node.visible:
            visible_meshes+=1
    return {"visible_meshes":visible_meshes,"deferred_swaps":_deferred_swaps,"meshes":_meshes.size(),"mesh_builds":_mesh_builds,"level_updates":_level_updates,"max_update_usec":_max_update_usec,"flow_quads":_flow_quads}
