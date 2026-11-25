extends RefCounted
# A7 routes preserve A2 canonical motion exactly and extend it to A5 systems.
const A2 = preload("res://tests/a2_routes.gd")
const ORIGIN := Vector3(0.0, 22.0, 18.0)
const SPEED_MPS := 18.0
const ADDITIONAL := ["shoreline_180s", "cave_180s", "rocks_water_180s"]

static func duration_for(route: String) -> float:
    var existing := A2.duration_for(route)
    if existing > 0.0:
        return existing
    if ADDITIONAL.has(route):
        return 180.0
    return -1.0

static func position_for(route: String, seconds: float) -> Vector3:
    if A2.duration_for(route) > 0.0:
        return A2.position_for(route, seconds)
    var travelled := clampf(seconds, 0.0, 180.0) * SPEED_MPS
    match route:
        "shoreline_180s":
            return Vector3(travelled, 7.0, 30.0)
        "cave_180s":
            return Vector3(travelled, -11.0, 0.0)
        "rocks_water_180s":
            return Vector3(travelled, 5.0, 30.0)
    return ORIGIN

static func is_stationary(route: String) -> bool:
    return route == "stationary_180s"
