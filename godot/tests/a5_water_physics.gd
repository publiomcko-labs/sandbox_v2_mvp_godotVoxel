extends SceneTree
const Water = preload("res://scripts/a5_water.gd")

func _initialize() -> void:
    call_deferred("_verify")

func _fail(s: String) -> void:
    push_error("A5_PHYSICS_FAIL: " + s)
    quit(1)

func _sphere(body: RigidBody3D) -> void:
    var cs := CollisionShape3D.new()
    var sh := SphereShape3D.new()
    sh.radius = 0.7
    cs.shape = sh
    body.add_child(cs)
    body.collision_layer = 2
    body.collision_mask = 1
    body.set_meta("a5_displaced_volume_m3", 1.436755)
    body.set_meta("a5_water_radius_m", 0.7)

func _verify() -> void:
    if absf(Water.submerged_sphere_fraction(0.0, 0.7) - 0.5) > 0.0001:
        _fail("sphere half-submerged fraction")
        return
    if Water.submerged_sphere_fraction(2.0, 0.7) != 0.0 or absf(Water.submerged_sphere_fraction(-2.0, 0.7) - 1.0) > 0.0001:
        _fail("sphere fully dry/wet fractions")
        return
    var buoyancy := Water.buoyancy_newtons(1.436755, 1.0)
    if not (buoyancy > 14000.0 and buoyancy < 14200.0 and buoyancy < 3600.0 * 9.81 and buoyancy > 250.0 * 9.81):
        _fail("force must sink heavy rock but float light body")
        return
    if absf(Water.current_velocity_at(Vector3(0, 0, 30)).x - 2.2) > 0.0001 or Water.current_velocity_at(Vector3(0, 0, 70)) != Vector3.ZERO:
        _fail("prescribed current mismatch")
        return

    var world := Node3D.new()
    world.name = "A5Fixture"
    root.add_child(world)
    var viewer := Node3D.new()
    viewer.name = "Player"
    world.add_child(viewer)
    var water := Node3D.new()
    water.name = "Water"
    water.set_script(Water)
    world.add_child(water)
    await process_frame
    var ocean := water.get_node_or_null("OceanMesh") as MeshInstance3D
    var area := water.get_node_or_null("WaterArea") as Area3D
    if ocean == null or area == null or not (ocean.mesh is PlaneMesh) or area.collision_mask != 2:
        _fail("single ocean mesh / Area3D not initialized")
        return
    var floor := StaticBody3D.new()
    floor.collision_layer = 1
    var shape := CollisionShape3D.new()
    var box := BoxShape3D.new()
    box.size = Vector3(80, 1, 80)
    shape.shape = box
    floor.add_child(shape)
    floor.position = Vector3(0, -8.5, 0)
    world.add_child(floor)
    var heavy := RigidBody3D.new()
    heavy.mass = 3600.0
    _sphere(heavy)
    heavy.position = Vector3(6, -2, 0)
    world.add_child(heavy)
    var light := RigidBody3D.new()
    light.mass = 250.0
    _sphere(light)
    light.position = Vector3(0, -2, 30)
    world.add_child(light)
    for i in range(300):
        await physics_frame
    var report: Dictionary = water.call("get_report")
    var hy := heavy.global_position.y
    var ly := light.global_position.y
    var lx := light.global_position.x
    if int(report.get("force_applications", 0)) <= 50:
        _fail("Area3D did not apply sustained forces: " + str(report))
        return
    if not (hy < -4.0 and hy > -9.0):
        _fail("heavy rock did not sink and contact floor y=" + str(hy))
        return
    if not (ly > -1.0 and ly < 2.0):
        _fail("light body did not float y=" + str(ly))
        return
    if lx <= 0.5:
        _fail("river current did not move float x=" + str(lx))
        return
    var folder := OS.get_environment("A5_RESULTS_DIR")
    if not folder.is_empty():
        var file := FileAccess.open(folder.path_join("a5_physics.json"), FileAccess.WRITE)
        if file != null:
            file.store_string(JSON.stringify({
                "heavy_rock_y": hy, "light_body_y": ly, "current_drift_x": lx,
                "buoyancy_newtons": buoyancy, "force_applications": report["force_applications"],
                "terrain_collision_gate": "NOT_QUALIFIED", "gpu_present_gate": "NOT_QUALIFIED"
            }, "  "))
            file.close()
    print("A5_PHYSICS_PASS heavy_y=", hy, " light_y=", ly, " current_x=", lx,
          " force_samples=", report["force_applications"])
    world.queue_free()
    quit(0)
