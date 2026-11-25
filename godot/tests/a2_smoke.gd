extends SceneTree
const Routes = preload("res://tests/a2_routes.gd")
const EPS := 0.0002

func _initialize() -> void:
    call_deferred("_verify")

func _check_close(a: Vector3, b: Vector3, label: String) -> bool:
    if a.distance_to(b) > EPS:
        push_error("A2_ROUTE_FAIL " + label + ": expected " + str(b) + ", got " + str(a))
        return false
    return true

func _verify() -> void:
    var origin: Vector3 = Routes.ORIGIN
    var passed := true
    passed = _check_close(Routes.position_for("stationary_180s", 180.0), origin, "stationary") and passed
    passed = _check_close(Routes.position_for("straight_18mps_600s", 10.0), origin + Vector3(180, 0, 0), "straight 10s") and passed
    passed = _check_close(Routes.position_for("straight_18mps_600s", 600.0), origin + Vector3(10800, 0, 0), "straight 600s") and passed
    passed = _check_close(Routes.position_for("out_and_back_18mps_300s", 150.0), origin + Vector3(2700, 0, 0), "outbound apex") and passed
    passed = _check_close(Routes.position_for("out_and_back_18mps_300s", 300.0), origin, "warm return") and passed
    passed = _check_close(Routes.position_for("turns_18mps_300s", 20.0), origin + Vector3(360, 0, 0), "turn1") and passed
    passed = _check_close(Routes.position_for("turns_18mps_300s", 40.0), origin + Vector3(360, 0, 360), "turn2") and passed
    passed = _check_close(Routes.position_for("turns_18mps_300s", 60.0), origin + Vector3(0, 0, 360), "turn3") and passed
    passed = _check_close(Routes.position_for("turns_18mps_300s", 80.0), origin, "turn4") and passed
    for route in ["straight_18mps_600s", "turns_18mps_300s", "out_and_back_18mps_300s"]:
        for t in [5.0, 19.98, 20.0, 20.02, 39.98, 40.02, 149.98, 150.02]:
            if t >= Routes.duration_for(route) - 0.03:
                continue
            var displacement := Routes.position_for(route, t + 0.01).distance_to(Routes.position_for(route, t))
            if displacement > 0.182:
                push_error("A2_ROUTE_FAIL: discontinuity or speed violation route=%s t=%f d=%f" % [route, t, displacement])
                passed = false
    if not passed:
        quit(1)
        return
    print("A2_ROUTES_PASS: deterministic paths, 18mps, corner continuity, out-and-back")
    quit(0)
