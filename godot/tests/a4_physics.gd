extends SceneTree
# Isolated physics check for the same rock_body.tscn geometry/material.
# NOT a qualification for collision against asynchronously meshed voxel terrain.

func _initialize() -> void:
    call_deferred("_verify")

func _verify() -> void:
    # In this isolated scene the rock body has no manager by design.
    var ground := StaticBody3D.new()
    var ground_shape := CollisionShape3D.new()
    var floor_box := BoxShape3D.new()
    floor_box.size = Vector3(80.0, 1.0, 80.0)
    ground_shape.shape = floor_box
    ground.add_child(ground_shape)
    root.add_child(ground)
    ground.position = Vector3(0, -0.5, 0)

    var rock := load("res://scenes/rock_body.tscn").instantiate() as RigidBody3D
    if rock == null:
        push_error("A4_PHYSICS_FAIL: rock scene missing")
        quit(1)
        return
    rock.set("rock_id", "a4_fixture_rock")
    rock.position = Vector3(0, 9, 0)
    root.add_child(rock)

    var initial_y := rock.global_position.y
    for i in range(240):
        await physics_frame
    var final_y := rock.global_position.y
    if not (initial_y - final_y > 5.0 and final_y > 0.3 and final_y < 1.4):
        push_error("A4_PHYSICS_FAIL: expected gravity/contact on fixture, y_initial=%f y_final=%f" % [initial_y, final_y])
        quit(1)
        return
    if rock.get_node_or_null("CollisionShape3D") == null:
        push_error("A4_PHYSICS_FAIL: no shape")
        quit(1)
        return
    print("A4_FIXTURE_GRAVITY_CONTACT_PASS start_y=", initial_y, " end_y=", final_y)
    rock.queue_free()
    ground.queue_free()
    quit(0)
