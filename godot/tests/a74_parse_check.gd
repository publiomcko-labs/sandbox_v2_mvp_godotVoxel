extends SceneTree
# CPU parser contract: load the pilot Script but NEVER instantiate/run the GUI campaign.
func _initialize() -> void:
    call_deferred("_verify")

func _verify() -> void:
    var candidate: Script = load("res://tests/a74_pilot.gd")
    if candidate == null or not candidate.can_instantiate():
        push_error("A74_PILOT_SCRIPT_INVALID")
        quit(2)
        return
    print("A74_GDSCRIPT_PARSE_PASS script_loaded=1 headless_only=1")
    quit(0)
