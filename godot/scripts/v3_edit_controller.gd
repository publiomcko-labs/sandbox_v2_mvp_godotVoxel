extends "res://scripts/a3_edit_controller.gd"
# Reuses A5 raycast/input, but V3 never invokes the legacy brush path directly.
var coordinator: Node

func _ready() -> void:
    _set_status("V3.1: G physical swim | F rock | LMB/RMB edit | Ctrl+S flush | close window to checkpoint")

func _do_edit(center: Vector3, add: bool) -> void:
    var result: String = coordinator.call("submit_brush", center, add, BRUSH_RADIUS_M)
    if result == "accepted":
        var selected: String = coordinator.call("selected_material_id")
        _set_status("V3 edit accepted | revision %d | %s | Ctrl+S flush" % [coordinator.get("last_revision"), selected])
    else:
        _set_status("V3 edit: " + result)

func _save_requested() -> void:
    coordinator.call("request_flush")
