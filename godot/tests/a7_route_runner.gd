extends SceneTree
# One fresh process per route/seed/run. World is still A5 CPU16/GL.
const Routes = preload("res://tests/a7_routes.gd")
const Runtime = preload("res://tests/a7_route_runtime.gd")

func _initialize() -> void:
    call_deferred("_start")

func _arg(name: String, fallback: String) -> String:
    var prefix := "--"+name+"="
    for a in OS.get_cmdline_user_args():
        if a.begins_with(prefix):
            return a.substr(prefix.length())
    return fallback

func _flag(name: String) -> bool:
    return OS.get_cmdline_user_args().has("--"+name)

func _fail(s: String) -> void:
    push_error("A7_ROUTE_CONFIG_FAIL "+s)
    quit(2)

func _start() -> void:
    var route := _arg("route","")
    var normal := Routes.duration_for(route)
    var duration := float(_arg("duration",str(normal)))
    var warmup := float(_arg("warmup","45"))
    var warmup_frames := int(_arg("warmup-frames","0"))
    var seed := int(_arg("seed","20261119"))
    var ci := _flag("ci-smoke")
    var capture := _flag("capture")
    var a8_visual_evidence := _flag("a8-visual-evidence")
    var visual_follow := _flag("visual-surface-follow")
    var screenshot_interval := float(_arg("screenshot-interval-s","30.0"))
    var vsync_off := _flag("vsync-off")
    var voxel_threads_requested := int(_arg("voxel-threads","0"))
    var headless := DisplayServer.get_name()=="headless"
    if visual_follow and (not capture or ci or not ["shoreline_180s","rocks_water_180s"].has(route)):
        _fail("visual surface follow only available in shoreline/rocks evidence capture")
        return
    if voxel_threads_requested<0 or voxel_threads_requested>48 or (ci and (vsync_off or voxel_threads_requested>0)):
        _fail("resource diagnostic flags invalid or not allowed in headless smoke")
        return
    if not is_finite(screenshot_interval) or screenshot_interval < 0.0 or screenshot_interval > 300.0:
        _fail("invalid screenshot interval")
        return
    if normal<1.0 or duration<=0.0 or duration>normal or warmup<0.0 or warmup>180.0:
        _fail("unknown route or invalid duration/warmup")
        return
    if a8_visual_evidence and (headless or ci or not capture or warmup_frames != 1000 or duration > 90.0 or vsync_off or voxel_threads_requested != 0):
        _fail("A8 visual route requires GPU, capture, exactly 1000 drawn frames, <=90s, standard VSync")
        return
    if warmup_frames < 0 or warmup_frames > 10000 or (warmup_frames > 0 and (headless or ci or (capture and not a8_visual_evidence))):
        _fail("rendered-frame warmup only for real GPU A8 route or explicit A8 visual evidence")
        return
    if headless and (not ci or capture or duration>3.0 or warmup>1.0):
        _fail("headless only allowed as <=3s CPU smoke, not performance evidence")
        return
    if not headless and (RenderingServer.get_current_rendering_method()!="gl_compatibility"
            or RenderingServer.get_current_rendering_driver_name().to_lower()!="opengl3"):
        _fail("A7 must use untouched A5 GL Compatibility renderer")
        return
    if not headless:
        if capture:
            # Evidence-only desktop recorder needs exact pixel coverage.
            DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS,true)
            DisplayServer.window_set_position(Vector2i.ZERO)
        DisplayServer.window_set_size(Vector2i(1920,1080))
        root.size=Vector2i(1920,1080)
        if vsync_off:
            DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
    if voxel_threads_requested>0:
        # A/B diagnostic only: preserve the A5 project defaults.
        VoxelEngine.set_thread_count(voxel_threads_requested)
    var packed: PackedScene=load("res://scenes/main.tscn")
    if packed==null:
        _fail("A5 scene missing")
        return
    var world: Node3D=packed.instantiate()
    var terrain: VoxelLodTerrain=world.get_node("Terrain") as VoxelLodTerrain
    if terrain==null:
        _fail("Terrain node missing")
        return
    terrain.set("world_seed",seed)
    if terrain.mesh_block_size!=16 or terrain.use_gpu_generation or terrain.lod_count!=4 or terrain.view_distance!=192 or absf(terrain.lod_distance-48.0)>0.001:
        _fail("baseline not A5 CPU16 / 4 LODs / 192m view")
        return
    root.add_child(world)
    var runner:=Runtime.new()
    runner.route=route
    runner.duration_s=duration
    runner.warmup_s=warmup
    runner.warmup_drawn_frames=warmup_frames
    runner.a8_visual_evidence=a8_visual_evidence
    runner.seed_value=seed
    runner.ci_smoke=ci
    runner.capture=capture
    runner.screenshot_interval_s=screenshot_interval
    runner.visual_surface_follow=visual_follow
    runner.vsync_off_requested=vsync_off
    runner.voxel_threads_requested=voxel_threads_requested
    world.add_child(runner)
