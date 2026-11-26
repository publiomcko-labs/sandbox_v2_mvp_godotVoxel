extends Node3D
# Presentation/physics adapter only: the native solver owns actual liquid.
const TILE := 8
const MAX_TILE_PUBLICATIONS := 1
const TILE_PUBLICATION_INTERVAL_USEC := 33333
var session: V3WorldSession
var world: WorldBootstrap
var world_seed: int
var config: Dictionary
var pending: Dictionary = {}
var _tiles: Dictionary = {}
var _dirty_tiles: Dictionary = {}
var _materials: Array[ShaderMaterial] = []
var _flow_materials: Array[ShaderMaterial] = []
var _ribbon_triangles := 0
var _triangles_published := 0
var _broad: ZN_FastNoiseLite
var _detail: ZN_FastNoiseLite
var _player: Node3D
var _rocks: Node3D
var _next_seed_usec := 0
var _next_publish_usec := 0
var _publish_total_usec := 0
var _published := 0
var _max_publish_usec := 0

func _noise(seed_value: int, period: float, octaves: int) -> ZN_FastNoiseLite:
    var n := ZN_FastNoiseLite.new()
    n.seed=seed_value
    n.period=period
    n.fractal_type=ZN_FastNoiseLite.FRACTAL_FBM
    n.fractal_octaves=octaves
    return n

func _height(x: float,z: float) -> float:
    return 6.0+12.0*_broad.get_noise_2d(x,z)+3.0*_detail.get_noise_2d(x,z)

func _ready() -> void:
    config=JSON.parse_string(session.get_fluid_json())
    _player=world.get_node("Player") as Node3D
    _rocks=world.get_node("RockManager") as Node3D
    _broad=_noise(world_seed,140.0,3)
    _detail=_noise(world_seed+101,38.0,2)
    for item: Dictionary in config["liquids"]:
        var rgb: Array=item["albedo"]
        var glow: Array=item["emission"]
        var m:=ShaderMaterial.new()
        m.shader=preload("res://shaders/v3_fluid_surface.gdshader")
        m.set_shader_parameter("liquid_color",Color(float(rgb[0]),float(rgb[1]),float(rgb[2]),1.0))
        m.set_shader_parameter("liquid_emission",Vector3(float(glow[0]),float(glow[1]),float(glow[2])))
        m.set_shader_parameter("viscosity",float(item["viscosity"]))
        _materials.append(m)
        var flow := m.duplicate() as ShaderMaterial
        flow.set_shader_parameter("flow_surface",true)
        _flow_materials.append(flow)
    var seeded: Array=session.get_seeded_reservoirs()
    for rule: Dictionary in config["reservoirs"]:
        if not seeded.has(rule["id"]):
            pending[rule["id"]]=rule
    print("V3_FLUID_PRESENTATION_READY finite_reservoirs=",config["reservoirs"].size()," restored=",seeded.size())

# Candidate columns are explicitly connected over the uncarved heightfield.
# No cell below that original surface can be initialized by this rule.
func _reservoir_candidates(rule: Dictionary) -> Array:
    var anchor:=Vector2i(int(rule["anchor_x"]),int(rule["anchor_z"]))
    var center:=anchor
    var minimum:=INF
    for z in range(-6,7,2):
        for x in range(-6,7,2):
            var p:=anchor+Vector2i(x,z)
            var h:=_height(p.x+0.5,p.y+0.5)
            if h<minimum:
                minimum=h
                center=p
    var radius:=float(rule["radius_m"])
    var level:=floori(minimum+float(rule["fill_depth_m"]))
    var bottom: Dictionary={}
    for z in range(-ceili(radius),ceili(radius)+1):
        for x in range(-ceili(radius),ceili(radius)+1):
            if Vector2(x,z).length()>radius:
                continue
            var p:=center+Vector2i(x,z)
            var h:=maxf(maxf(_height(p.x,p.y),_height(p.x+1,p.y)),
                maxf(_height(p.x,p.y+1),_height(p.x+1,p.y+1)))
            var first:=ceili(h+0.15)
            if first<level:
                bottom[p]=first
    var result: Array=[]
    if not bottom.has(center):
        return result
    var queue: Array[Vector2i]=[center]
    var seen: Dictionary={center:true}
    var head:=0
    while head<queue.size():
        var p:=queue[head]
        head+=1
        for y in range(int(bottom[p]),level):
            result.append(Vector3i(p.x,y,p.y))
        for d: Vector2i in [Vector2i(1,0),Vector2i(-1,0),Vector2i(0,1),Vector2i(0,-1)]:
            var n:=p+d
            if bottom.has(n) and not seen.has(n):
                seen[n]=true
                queue.append(n)
    return result

func prepare_sources() -> void:
    for id: String in pending.keys():
        var rule: Dictionary=pending[id]
        var center:=Vector2(float(rule["anchor_x"]),float(rule["anchor_z"]))
        if Vector2(_player.global_position.x,_player.global_position.z).distance_to(center)>75.0:
            continue
        if not rule.has("candidates"):
            rule["candidates"]=_reservoir_candidates(rule)
            pending[id]=rule
        var outcome:=session.seed_reservoir(world,id,rule["candidates"])
        if outcome=="seeded":
            pending.erase(id)
            print("V3_RESERVOIR_SEEDED id=",id," candidate_cells=",rule["candidates"].size())
        elif outcome=="empty":
            pending.erase(id)
            print("V3_RESERVOIR_EMPTY id=",id)
        elif outcome!="deferred":
            push_error("V3_RESERVOIR_REJECTED: "+id+" "+session.get_last_error())
            pending.erase(id)

func _tile(p: Vector3i) -> Vector3i:
    return Vector3i(floori(float(p.x)/TILE),floori(float(p.y)/TILE),floori(float(p.z)/TILE))

func _collect_dirty() -> void:
    for tile: Vector3i in session.take_fluid_dirty_tiles(512):
        _dirty_tiles[tile]=true

func _publish(tile: Vector3i) -> void:
    var origin:=tile*TILE
    var mesh:=ArrayMesh.new()
    for row: Array in session.fluid_surface_tile(Vector3(origin)):
        var vertices: PackedVector3Array=row[1]
        var normals: PackedVector3Array=row[2]
        if vertices.is_empty():
            continue
        var arrays: Array=[]
        arrays.resize(Mesh.ARRAY_MAX)
        arrays[Mesh.ARRAY_VERTEX]=vertices
        arrays[Mesh.ARRAY_NORMAL]=normals
        mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
        var flow: bool=bool(row[3])
        mesh.surface_set_material(mesh.get_surface_count()-1,_flow_materials[int(row[0])] if flow else _materials[int(row[0])])
        @warning_ignore("integer_division")
        var triangles: int=vertices.size()/3
        _triangles_published+=triangles
        if flow:
            _ribbon_triangles+=triangles
    if mesh.get_surface_count()==0:
        if _tiles.has(tile):
            _tiles[tile].queue_free()
            _tiles.erase(tile)
        return
    var node: MeshInstance3D
    if _tiles.has(tile):
        node=_tiles[tile]
    else:
        node=MeshInstance3D.new()
        node.position=Vector3(origin)
        node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
        node.visibility_range_end=128.0
        add_child(node)
        _tiles[tile]=node
    node.mesh=mesh

func _process(_delta: float) -> void:
    if not is_instance_valid(_player):
        return
    if bool(get_parent().get_parent().get("saving")) or bool(get_parent().get_parent().get("closing")):
        return
    var now:=Time.get_ticks_usec()
    if now>=_next_seed_usec and not pending.is_empty():
        _next_seed_usec=now+500000
        prepare_sources()
    if now<_next_publish_usec:
        return
    _next_publish_usec=now+TILE_PUBLICATION_INTERVAL_USEC
    _collect_dirty()
    var start:=Time.get_ticks_usec()
    for i in range(MAX_TILE_PUBLICATIONS):
        if _dirty_tiles.is_empty():
            break
        var tile: Vector3i=_dirty_tiles.keys()[0]
        _dirty_tiles.erase(tile)
        _publish(tile)
        _published+=1
        if Time.get_ticks_usec()-start>=1000:
            break
    var elapsed:=Time.get_ticks_usec()-start
    _publish_total_usec+=elapsed
    _max_publish_usec=maxi(_max_publish_usec,elapsed)

func immersion_at(center: Vector3,height: float) -> float:
    var wet:=0
    for i in range(5):
        var p:=center+Vector3(0,(float(i)/4.0-0.5)*height,0)
        if not session.fluid_at(p).is_empty():
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
        var r:=float(body.get_meta("a5_water_radius_m",0.7))
        if volume<=0.0:
            continue
        var density:=0.0
        var wet:=0
        for offset: Vector3 in [Vector3.ZERO,Vector3.UP*r,Vector3.DOWN*r,Vector3.LEFT*r,Vector3.RIGHT*r,Vector3.FORWARD*r,Vector3.BACK*r]:
            var f:=session.fluid_at(body.global_position+offset)
            if not f.is_empty():
                density+=float(f["density"])
                wet+=1
        if wet>0:
            var fraction:=float(wet)/7.0
            body.apply_central_force(Vector3.UP*(density/7.0)*9.81*volume-body.linear_velocity*2.0*body.mass*fraction)
            body.sleeping=false
        processed+=1

func get_report() -> Dictionary:
    return {"tile_meshes":_tiles.size(),"dirty_tiles":_dirty_tiles.size(),"published":_published,"triangles_published":_triangles_published,"ribbon_triangles":_ribbon_triangles,"max_publish_usec":_max_publish_usec,"publish_total_usec":_publish_total_usec,"pending_reservoirs":pending.size()}
