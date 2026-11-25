extends Node3D
# A5: one camera-following ocean mesh and one near-field Area3D; no water
# chunks, terrain remeshing, CPU fluid solver, or second streaming authority.
# Surface and physics both use exactly y=0 in world coordinates.
const SURFACE_Y := 0.0
const OCEAN_SIZE_M := 640.0
const WATER_DENSITY_KG_M3 := 1000.0
const GRAVITY_MPS2 := 9.81
const MAX_ACTIVE_WET_BODIES := 24
const WATER_DRAG_PER_SECOND := 2.0
const RIVER_CENTER_Z := 30.0
const RIVER_HALF_WIDTH_M := 7.0
const RIVER_FLOW_MPS := 2.2
const WaterShader = preload("res://assets/shaders/a5_water.gdshader")

var _mesh: MeshInstance3D
var _area: Area3D
var _player: Node3D
var _wet_bodies := 0
var _force_samples := 0
var _max_wet_bodies := 0

func _ready() -> void:
    _player = get_parent().get_node_or_null("Player") as Node3D
    if _player == null:
        push_error("A5_WATER_FAIL: Player not found")
        return

    var plane := PlaneMesh.new()
    plane.size = Vector2(OCEAN_SIZE_M, OCEAN_SIZE_M)
    # Geometry is fixed: waves are shader-only normals/color, never vertex
    # displacement. This keeps the collision/shoreline level at exactly y=0.
    plane.subdivide_width = 1
    plane.subdivide_depth = 1
    var material := ShaderMaterial.new()
    material.shader = WaterShader
    _mesh = MeshInstance3D.new()
    _mesh.name = "OceanMesh"
    _mesh.mesh = plane
    var tags=preload("res://tests/a8_p83_object_tags.gd")
    # In the semantic diagnostic arm only, represent the exact y=0 plane
    # as opaque to identify geometric occlusion, not normal alpha blending.
    _mesh.material_override = tags.make(Color.BLUE) if tags.active() else material
    _mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
    add_child(_mesh)

    _area = Area3D.new()
    _area.name = "WaterArea"
    _area.monitoring = true
    _area.monitorable = false
    _area.collision_layer = 0
    _area.collision_mask = 2 # Promoted rocks + CharacterBody swimmer.
    var shape := CollisionShape3D.new()
    shape.name = "WaterVolume"
    var box := BoxShape3D.new()
    box.size = Vector3(128.0, 128.0, 128.0)
    shape.shape = box
    shape.position = Vector3(0.0, -64.0, 0.0)
    _area.add_child(shape)
    add_child(_area)
    _follow_player()
    print("A5_WATER_READY level=", SURFACE_Y, " plane_m=", OCEAN_SIZE_M,
          " river_z=", RIVER_CENTER_Z)

func _follow_player() -> void:
    if _player == null:
        return
    var p := _player.global_position
    # Move nodes, never recreate water tiles or GPU meshes. Shader phase uses
    # world coordinates, so following the player has no texture phase jump.
    if _mesh != null:
        _mesh.global_position = Vector3(p.x, SURFACE_Y, p.z)
    if _area != null:
        _area.global_position = Vector3(p.x, 0.0, p.z)

func _process(_delta: float) -> void:
    _follow_player()

static func submerged_sphere_fraction(center_y: float, radius: float, surface_y: float = 0.0) -> float:
    if radius <= 0.0:
        return 0.0
    var h := clampf(surface_y - (center_y - radius), 0.0, 2.0 * radius)
    return h * h * (3.0 * radius - h) / (4.0 * radius * radius * radius)

static func current_velocity_at(position: Vector3) -> Vector3:
    # Simple prescribed watercourse overlay on ocean, not a fluid simulation.
    if absf(position.z - RIVER_CENTER_Z) <= RIVER_HALF_WIDTH_M:
        return Vector3(RIVER_FLOW_MPS, 0.0, 0.0)
    return Vector3.ZERO

static func buoyancy_newtons(volume_m3: float, fraction: float) -> float:
    return WATER_DENSITY_KG_M3 * GRAVITY_MPS2 * maxf(volume_m3, 0.0) * clampf(fraction, 0.0, 1.0)

func _physics_process(_delta: float) -> void:
    if _area == null:
        return
    var candidates := _area.get_overlapping_bodies()
    var processed := 0
    for item in candidates:
        if processed >= MAX_ACTIVE_WET_BODIES:
            break
        if not (item is RigidBody3D):
            continue
        var body := item as RigidBody3D
        if body.freeze:
            continue
        var volume := float(body.get_meta("a5_displaced_volume_m3", 0.0))
        var radius := float(body.get_meta("a5_water_radius_m", 0.7))
        if volume <= 0.0 or radius <= 0.0:
            continue
        var fraction := submerged_sphere_fraction(body.global_position.y, radius, SURFACE_Y)
        if fraction <= 0.0:
            continue
        var buoyant := Vector3.UP * buoyancy_newtons(volume, fraction)
        var current := current_velocity_at(body.global_position)
        var drag_force := (current - body.linear_velocity) * (WATER_DRAG_PER_SECOND * body.mass * fraction)
        body.apply_central_force(buoyant + drag_force)
        if body.sleeping:
            body.sleeping = false
        processed += 1
        _force_samples += 1
    _wet_bodies = processed
    _max_wet_bodies = maxi(_max_wet_bodies, processed)

func surface_height_at(_point: Vector3) -> float:
    return SURFACE_Y

func get_report() -> Dictionary:
    return {
        "level_y": SURFACE_Y,
        "plane_size_m": OCEAN_SIZE_M,
        "render_meshes": 1 if _mesh != null else 0,
        "local_volume_areas": 1 if _area != null else 0,
        "wet_dynamic_bodies": _wet_bodies,
        "wet_peak": _max_wet_bodies,
        "force_applications": _force_samples,
        "river_center_z": RIVER_CENTER_Z,
        "river_velocity_mps": RIVER_FLOW_MPS,
        "headless_pixel_gate": "NOT_QUALIFIED",
        "visual_shoreline_gate": "NOT_QUALIFIED"
    }
