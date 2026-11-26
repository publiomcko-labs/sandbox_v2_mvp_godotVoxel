extends SceneTree
const RADIUS := 3.0

func _initialize() -> void:
    call_deferred("_test")
func _fail(reason: String) -> void:
    push_error("V3_FLUID_RUNTIME_FAIL: "+reason)
    quit(1)

func _test() -> void:
    var write: bool="--phase=write" in OS.get_cmdline_user_args()
    var scene: PackedScene=load("res://scenes/v3_fluids_main.tscn")
    var runtime=scene.instantiate()
    root.add_child(runtime)
    if not runtime.running:
        _fail("runtime start")
        return
    runtime.set_process(false)
    runtime.player.set_process(false)
    runtime.player.set_physics_process(false)
    var water: Node3D=runtime.world.get_node("Water")
    water.set_process(false)
    water.set_physics_process(false)
    runtime.player.global_position=Vector3(10,12,15)
    var deadline:=Time.get_ticks_msec()+60000
    while runtime.session.get_seeded_reservoirs().size()<3:
        water.call("prepare_sources")
        if Time.get_ticks_msec()>deadline:
            _fail("source readiness "+str(runtime.session.get_seeded_reservoirs()))
            return
        await process_frame
    var state: Dictionary=runtime.session.get_state()
    var volume:=int(state["fluid_litres"])
    if volume<=0 or volume!=int(state["fluid_initial_litres"]):
        _fail("initial mass")
        return
    var dry:=Vector3(10,-30,15)
    if not runtime.session.fluid_at(dry).is_empty() or float(water.call("immersion_at",dry,1.7))!=0:
        _fail("global underwater mask")
        return
    var wet: Array=runtime.session.fluid_cells(Vector3(-64,-32,-64),Vector3(64,32,64))
    var slots: Dictionary={}
    for row: Array in wet:
        slots[row[1]]=true
    if slots.size()!=2 or wet.is_empty():
        _fail("water and lava not present")
        return
    var row: Array=wet[0]
    var point:=Vector3(row[0])+Vector3(0.5,0.1,0.5)
    if runtime.session.fluid_at(point).is_empty():
        _fail("wet occupancy")
        return
    if write:
        if runtime.submit_brush(point,true,RADIUS)!="rejected":
            _fail("wet construction not rejected")
            return
        while not runtime.world.can_edit_sphere(dry,RADIUS):
            if Time.get_ticks_msec()>deadline:
                _fail("dry edit readiness")
                return
            await process_frame
        if runtime.submit_brush(dry,false,RADIUS)!="accepted":
            _fail("dry excavation")
            return
        if not runtime.session.fluid_at(dry).is_empty():
            _fail("instant water in excavation")
            return
        runtime.session.update_interest(runtime.player.global_position)
        var moved:=0
        for i in range(8):
            runtime.session.advance_ticks(100000000,1)
            moved+=int(runtime.session.get_state()["fluid_transferred"])
        if moved<=0 or int(runtime.session.get_state()["fluid_litres"])!=volume:
            _fail("flow or mass conservation")
            return
        water.call("_collect_dirty")
        var tile: Vector3i=water.call("_tile",Vector3i(row[0]))
        water.call("_publish",tile)
        print("V3_FLUID_RUNTIME_FLOW_PASS moved_litres=",moved," mass=",volume," tiles=",water.call("get_report"))
    else:
        if int(state["terrain_revision"])!=1 or int(state["checkpoint_generation"])!=1:
            _fail("reopen checkpoint")
            return
        print("V3_FLUID_RUNTIME_RESTORE_PASS mass=",volume)
    print("V3_FLUID_RUNTIME_FIXTURE_PASS phase=","write" if write else "reopen"," mass=",volume)
    runtime.request_close()
