extends RefCounted
# A2 paths are deterministic functions of elapsed wall-clock time, not keyboard
# input, frame count, or streaming results. A2 has no teleport/pause on gaps.
const SPEED_MPS := 18.0
const ORIGIN := Vector3(0.0, 22.0, 18.0)
const TURN_SIDE_M := 360.0
const OUTBACK_HALF_S := 150.0

static func duration_for(route: String) -> float:
    match route:
        "stationary_180s":
            return 180.0
        "straight_18mps_600s":
            return 600.0
        "turns_18mps_300s":
            return 300.0
        "out_and_back_18mps_300s":
            return 300.0
    return -1.0

static func position_for(route: String, seconds: float) -> Vector3:
    var nominal := duration_for(route)
    if nominal <= 0.0:
        return ORIGIN
    var d := clampf(seconds, 0.0, nominal) * SPEED_MPS
    match route:
        "stationary_180s":
            return ORIGIN
        "straight_18mps_600s":
            return ORIGIN + Vector3(d, 0.0, 0.0)
        "out_and_back_18mps_300s":
            var advance := minf(d, SPEED_MPS * OUTBACK_HALF_S * 2.0 - d)
            return ORIGIN + Vector3(advance, 0.0, 0.0)
        "turns_18mps_300s":
            var side := TURN_SIDE_M
            var lap := fposmod(d, 4.0 * side)
            if lap < side:
                return ORIGIN + Vector3(lap, 0.0, 0.0)
            if lap < 2.0 * side:
                return ORIGIN + Vector3(side, 0.0, lap - side)
            if lap < 3.0 * side:
                return ORIGIN + Vector3(3.0 * side - lap, 0.0, side)
            return ORIGIN + Vector3(0.0, 0.0, 4.0 * side - lap)
    return ORIGIN
