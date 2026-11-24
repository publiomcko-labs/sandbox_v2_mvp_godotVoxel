extends SceneTree
# Deterministic input-equivalent edit campaign. 100 attempted edits at 10Hz.
# The application can measure brush return, SDF change and next render
# submission, but NOT pixel correctness in the first PRESENTED frame. Full
# EDIT-100 requires synchronized external capture and image verification.
const EDIT_COUNT := 100
const RADIUS_M := 1.5
const RATE_S := 0.1

func _initialize() -> void:
    call_deferred("_run")

func _arg(name: String, fallback: String) -> String:
    var key := "--"+name+"="
    for a in OS.get_cmdline_user_args():
        if a.begins_with(key):
            return a.substr(key.length())
    return fallback

func _flag(name: String) -> bool:
    return OS.get_cmdline_user_args().has("--"+name)

func _fail(msg: String) -> void:
    push_error("A7_EDIT_FAIL: "+msg)
    quit(2)

func _capture(folder: String, tag: String) -> bool:
    var img: Image = root.get_texture().get_image()
    if img==null or img.is_empty():
        return false
    return img.save_png(folder.path_join(tag+".png"))==OK

func _center_for(scenario: String, index: int, t: float, tool: VoxelTool) -> Vector3:
    var x := 0.0
    var z := 15.0
    match scenario:
        "edit_idle_100":
            x = -1.0+2.5*float(index%10)
            z = 3.0+2.5*float(index/10)
        "boundary_edit_100":
            x = 15.5 if index%2==0 else 16.5
            z = -11.0+2.4*float(index%12)
        "edit_moving_100":
            x = 18.0*t
            z = 15.0
    var above := Vector3(x,55.0,z)
    var hit: VoxelRaycastResult=tool.raycast(above,Vector3.DOWN,100.0)
    if hit==null:
        return Vector3(INF,INF,INF)
    return above+Vector3.DOWN*(hit.distance+0.6)

func _run() -> void:
    var scenario := _arg("scenario","")
    var seed := int(_arg("seed","20261119"))
    var count := int(_arg("count","100"))
    var warmup := float(_arg("warmup","45"))
    var pilot := _flag("a8-p8-edit")
    var depth_pilot := pilot and _flag("a8-p81-depth")
    var depth: Node
    var observation_end: float=0.0
    var ci := _flag("ci-smoke")
    var evidence := _flag("capture")
    # Keep the per-edit color marker and timestamps in external-video mode,
    # but avoid synchronously pulling GPU pixels into Godot and saving PNGs.
    var evidence_stills := evidence and not _flag("no-stills")
    if not ["edit_idle_100","edit_moving_100","boundary_edit_100"].has(scenario):
        _fail("invalid edit scenario")
        return
    if count<1 or count>EDIT_COUNT or warmup<0.0 or warmup>180.0:
        _fail("count/warmup outside contract")
        return
    if ci and (count>2 or warmup>12.0 or evidence==true):
        _fail("CI permits only <=2 headless edits and no captures")
        return
    if DisplayServer.get_name()=="headless" and not ci:
        _fail("headless cannot qualify visual edit latency")
        return
    if DisplayServer.get_name()!="headless" and (
        RenderingServer.get_current_rendering_method()!="gl_compatibility" or
        RenderingServer.get_current_rendering_driver_name().to_lower()!="opengl3"):
        _fail("A7 visual edit must use A5 GL Compatibility")
        return
    var folder := OS.get_environment("A7_OUTPUT_DIR")
    if folder.is_empty() or DirAccess.make_dir_recursive_absolute(folder)!=OK:
        _fail("A7_OUTPUT_DIR must be an isolated directory")
        return
    if DisplayServer.get_name()!="headless":
        if evidence:
            # Evidence-only mode: borderless primary 1080p for desktop video.
            DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS,true)
            DisplayServer.window_set_position(Vector2i.ZERO)
        DisplayServer.window_set_size(Vector2i(1920,1080))
        root.size=Vector2i(1920,1080)

    var world: Node3D=load("res://scenes/main.tscn").instantiate()
    var terrain: VoxelLodTerrain=world.get_node("Terrain") as VoxelLodTerrain
    if terrain==null:
        _fail("A5 terrain missing")
        return
    terrain.set("world_seed",seed)
    if terrain.mesh_block_size!=16 or terrain.use_gpu_generation:
        _fail("A5 CPU16 baseline changed")
        return
    root.add_child(world)
    await process_frame
    # The visible marker is an alignment cue for 60fps desktop recordings,
    # NOT evidence that terrain geometry was correctly displayed.
    var marker: ColorRect=ColorRect.new()
    var marker_text: Label=Label.new()
    if evidence:
        marker.position=Vector2(1710,22)
        marker.size=Vector2(192,40)
        marker.color=Color(0.15,0.15,0.15,1.0)
        marker.mouse_filter=Control.MOUSE_FILTER_IGNORE
        marker_text.text="A7 EDIT PRE"
        marker_text.position=Vector2(6,8)
        marker_text.add_theme_color_override("font_color",Color.BLACK)
        marker.add_child(marker_text)
        world.get_node("HUD").add_child(marker)
    var player: Node3D=world.get_node("Player")
    var camera: Camera3D=world.get_node("Player/Camera3D")
    var tool: VoxelTool=terrain.get_voxel_tool()
    player.set_process(false)
    player.set_physics_process(false)
    player.set_process_unhandled_input(false)
    player.global_position=Vector3(10,22,15)
    if tool==null or not bool(world.call("is_voxel_ready")):
        _fail("native brush/terrain unavailable")
        return
    if depth_pilot:
        depth=load("res://tests/a8_p81_metric_depth.gd").new()
        world.add_child(depth)
        if not depth.setup(camera,world.get_node("HUD")) or not await depth.calibrate(folder):
            _fail("A8-P8.1 depth calibration failed")
            return
        depth.enable_depth()
    var warming := Time.get_ticks_usec()
    while float(Time.get_ticks_usec()-warming)/1000000.0<warmup:
        await process_frame
    if pilot:
        if ci or not evidence or evidence_stills or count!=12:
            _fail("A8-P8 requires 12 external-video edits")
            return
        for frame_idx in range(1000):
            await RenderingServer.frame_post_draw
    var trace:=FileAccess.open(folder.path_join("a7_edits.jsonl"),FileAccess.WRITE)
    if trace==null:
        _fail("cannot open event file")
        return
    trace.store_line(JSON.stringify({
        "type":"metadata","schema":"a7_edit_v1","scenario":scenario,
        "seed":seed,"count":count,"rate_hz":10.0,
        "radius_m":RADIUS_M,"ci_smoke":ci,"evidence":evidence,
        "a8_p8_pilot":pilot,"warmup_drawn_frames":1000 if pilot else 0,
        "a8_p81_depth":depth_pilot,"depth_calibration":depth.calibrations if depth_pilot else [],
        "input":"scripted brush invocation; no raw OS HID timestamp",
        "visual_evidence_marker":evidence,
        "in_engine_stills_enabled":evidence_stills,
        "timestamp_clock":"Godot Time.get_unix_time_from_system() UTC epoch and monotonic Time.get_ticks_usec()",
        "marker_gate":"ALIGNMENT_CUE_ONLY",
        "pixel_gate":"NOT_QUALIFIED"
    }))
    var accepted:=0
    var rejected:=0
    var sdf_changed:=0
    var slow_apply:=0
    var max_apply:=0.0
    var max_submitted:=0.0
    var previews:=0
    var start:=Time.get_ticks_usec()
    for i in range(count):
        var target_t:=float(i)*RATE_S
        if pilot:
            target_t=float(i)*1.5
        while float(Time.get_ticks_usec()-start)/1000000.0<target_t:
            await process_frame
        var t:=float(Time.get_ticks_usec()-start)/1000000.0
        if scenario=="edit_moving_100":
            player.global_position=Vector3(t*18.0,22.0,15.0)
        var center:=_center_for(scenario,i,t,tool)
        if pilot:
            center=_center_for("boundary_edit_100" if i>=8 else "edit_idle_100",i,t,tool)
        var add:=i%2==1
        var row: Dictionary={
            "type":"edit","index":i,"target_t_s":target_t,"actual_t_s":t,
            "scenario":scenario,"add":add,"player_x":player.global_position.x,
            "center_x":center.x,"center_y":center.y,"center_z":center.z,
            "accepted":false,"native_apply_ms":null,
            "first_submitted_frame_proxy_ms":null,
            "first_correct_presented_pixel_ms":null,
            "pixel_gate":"NOT_QUALIFIED",
            "external_video_required":true
        }
        if not center.is_finite():
            row["reject_reason"]="no_ray_hit"
            rejected+=1
            trace.store_line(JSON.stringify(row))
            continue
        var sample:=Vector3i(roundi(center.x),roundi(center.y),roundi(center.z))
        var before:=tool.get_voxel_f(sample)
        if not bool(world.call("can_edit_sphere",center,RADIUS_M)):
            row["reject_reason"]="LOD0_not_editable"
            rejected+=1
            trace.store_line(JSON.stringify(row))
            continue
        var do_capture:=evidence_stills and (i==0 or i==1 or i==count-1)
        if evidence:
            # Diagnostic arm only: aim at every attempted edit so its actual
            # terrain pixels can be reviewed in the full-frame desktop video.
            camera.look_at(center,Vector3.UP)
            await process_frame
            if pilot:
                for settle in range(12):
                    await RenderingServer.frame_post_draw
                if depth_pilot:
                    depth.stamp(i*64+1)
                    await RenderingServer.frame_post_draw
                row["camera_transform"] = str(camera.global_transform)
                row["camera_origin"] = [camera.global_position.x,camera.global_position.y,camera.global_position.z]
                row["camera_fov"] = camera.fov
                row["probe_rays"] = []
                for offset in [Vector2(-24,-24),Vector2(0,-24),Vector2(24,-24),Vector2(-24,0),Vector2(0,0),Vector2(24,0),Vector2(-24,24),Vector2(0,24),Vector2(24,24)]:
                    var pixel: Vector2 = camera.unproject_position(center)+offset
                    var origin: Vector3 = camera.project_ray_origin(pixel)
                    var direction: Vector3 = camera.project_ray_normal(pixel)
                    var hit: VoxelRaycastResult = tool.raycast(origin,direction,100.0)
                    row["probe_rays"].append({"pixel":[pixel.x,pixel.y],"origin":[origin.x,origin.y,origin.z],"direction":[direction.x,direction.y,direction.z],"before_m":hit.distance if hit!=null else null})
            row["camera_targeted_for_video"]=true
            row["target_behind_camera"]=camera.is_position_behind(center)
            var target_px: Vector2=camera.unproject_position(center)
            row["target_screen_xy_px"]=[target_px.x,target_px.y]
            row["camera_frame_epoch_s"]=Time.get_unix_time_from_system()
            if do_capture:
                var before_name: String="edit_%03d_before.png"%i
                if _capture(folder,before_name.trim_suffix(".png")):
                    previews+=1
                    row["visual_before_sample"]={
                        "file":before_name,
                        "capture_epoch_s":Time.get_unix_time_from_system(),
                        "pixel_gate":"REVIEW_REQUIRED"
                    }
        # Input-equivalent accepted call begins here, NOT from OS device.
        if depth_pilot:
            depth.stamp(i*64+2)
            row["depth_frames"]=[]
            row["first_depth_stamp_epoch_s"]=Time.get_unix_time_from_system()
        var begun:=Time.get_ticks_usec()
        row["brush_call_epoch_s"]=Time.get_unix_time_from_system()
        row["brush_call_ticks_us"]=begun
        var success: bool = bool(world.call("edit_sphere",center,add,RADIUS_M))
        var end_cpu:=Time.get_ticks_usec()
        row["brush_return_epoch_s"]=Time.get_unix_time_from_system()
        row["brush_return_ticks_us"]=end_cpu
        if not success:
            row["reject_reason"]="native_rejected"
            rejected+=1
            trace.store_line(JSON.stringify(row))
            continue
        accepted+=1
        if evidence:
            # Alternate highly distinguishable marker colors every accepted
            # edit; never use the marker's visual appearance as proof of an
            # actually changed terrain pixel.
            marker.color=Color(0.0,1.0,0.0,1.0) if accepted%2==1 else Color(1.0,0.0,1.0,1.0)
            marker_text.text="A7 EDIT %03d"%i
            row["video_marker_index"]=i
            row["video_marker_rgb"]="00ff00" if accepted%2==1 else "ff00ff"
            row["video_marker_meaning"]="synchronization only, NOT correct terrain presentation"
        var elapsed_cpu:=float(end_cpu-begun)/1000.0
        max_apply=maxf(max_apply,elapsed_cpu)
        if elapsed_cpu>100.0:
            slow_apply+=1
        row["accepted"]=true
        row["native_apply_ms"]=elapsed_cpu
        row["sdf_before"]=before
        row["sdf_after"]=tool.get_voxel_f(sample)
        if pilot and not depth_pilot:
            for probe in row["probe_rays"]:
                var origin := Vector3(float(probe["origin"][0]),float(probe["origin"][1]),float(probe["origin"][2]))
                var direction := Vector3(float(probe["direction"][0]),float(probe["direction"][1]),float(probe["direction"][2]))
                var hit: VoxelRaycastResult=tool.raycast(origin,direction,100.0)
                probe["after_m"]=hit.distance if hit!=null else null
            row["probe_kind"]="LIVE_SDF_REFERENCE_NOT_RENDERED_DEPTH"
        if absf(float(row["sdf_after"])-before)>0.05:
            sdf_changed+=1
            row["sdf_changed"]=true
        else:
            row["sdf_changed"]=false
        if DisplayServer.get_name()!="headless":
            await RenderingServer.frame_post_draw
            if depth_pilot:
                row["depth_frames"].append({"id":i*64+2,"post_draw_epoch_s":Time.get_unix_time_from_system(),"pre_draw_epoch_s":row["first_depth_stamp_epoch_s"]})
            var frame_proxy:=float(Time.get_ticks_usec()-begun)/1000.0
            row["first_submitted_frame_proxy_ms"]=frame_proxy
            max_submitted=maxf(max_submitted,frame_proxy)
            if do_capture:
                row["visual_after_samples"]=[]
                if _capture(folder,"edit_%03d_after_01"%i):
                    previews+=1
                    row["visual_after_samples"].append({
                        "frame_number_after_edit":1,
                        "capture_epoch_s":Time.get_unix_time_from_system(),
                        "file":"edit_%03d_after_01.png"%i,
                        "pixel_gate":"REVIEW_REQUIRED"
                    })
                for frame_idx in range(2,9):
                    await RenderingServer.frame_post_draw
                    if frame_idx==4 or frame_idx==8:
                        var shot: String="edit_%03d_after_%02d.png"%[i,frame_idx]
                        if _capture(folder,shot):
                            previews+=1
                            row["visual_after_samples"].append({
                                "frame_number_after_edit":frame_idx,
                                "capture_epoch_s":Time.get_unix_time_from_system(),
                                "file":shot,
                                "pixel_gate":"REVIEW_REQUIRED"
                            })
        else:
            await process_frame
        if pilot:
            # Keep the target stationary beyond the 100 ms measurement window.
            var hold_start:=Time.get_ticks_usec()
            var stamp_id:=i*64+3
            while Time.get_ticks_usec()-hold_start<350000:
                if depth_pilot:
                    if stamp_id>=i*64+64:
                        _fail("depth frame ID overflow")
                        return
                    depth.stamp(stamp_id)
                    var pre:=Time.get_unix_time_from_system()
                    await RenderingServer.frame_post_draw
                    row["depth_frames"].append({"id":stamp_id,"pre_draw_epoch_s":pre,"post_draw_epoch_s":Time.get_unix_time_from_system()})
                    stamp_id+=1
                else:
                    await RenderingServer.frame_post_draw
            row["camera_hold_end_epoch_s"]=Time.get_unix_time_from_system()
            observation_end=float(row["camera_hold_end_epoch_s"])
            if depth_pilot:
                for probe in row["probe_rays"]:
                    var origin:=Vector3(float(probe["origin"][0]),float(probe["origin"][1]),float(probe["origin"][2]))
                    var direction:=Vector3(float(probe["direction"][0]),float(probe["direction"][1]),float(probe["direction"][2]))
                    var hit:VoxelRaycastResult=tool.raycast(origin,direction,100.0)
                    probe["after_m"]=hit.distance if hit!=null else null
                row["probe_kind"]="LIVE_SDF_REFERENCE_NOT_RENDERED_DEPTH"
        trace.store_line(JSON.stringify(row))
    trace.close()
    # Save asynchronously then flush. Independent reopen is tested by
    # existing A3/A4/A5 E2E scripts; the A7 acceptance wrapper calls them.
    var tracker: VoxelSaveCompletionTracker=terrain.save_modified_blocks()
    if tracker==null:
        _fail("SQLite tracker missing")
        return
    var save_started:=Time.get_ticks_msec()
    while not tracker.is_complete() and not tracker.is_aborted():
        if Time.get_ticks_msec()-save_started>60000:
            _fail("save tracker timed out")
            return
        await process_frame
    if tracker.is_aborted():
        _fail("SQLite save aborted")
        return
    terrain.stream.flush()
    var summary: Dictionary={
        "schema":"a7_edit_v1","scenario":scenario,"seed":seed,
        "ci_smoke":ci,"requested_count":count,
        "a8_p8_observation_end_epoch_s":observation_end,
        "accepted_count":accepted,"rejected_count":rejected,
        "sdf_changed_count":sdf_changed,
        "native_apply_over_100_count":slow_apply,
        "max_native_apply_ms":max_apply,
        "max_first_submitted_frame_proxy_ms":max_submitted,
        "screenshot_count":previews,
        "sqlite_saved":FileAccess.file_exists(OS.get_environment("A3_SAVE_PATH")),
        "all_accepted":accepted==count,
        "first_correct_presented_pixel_ms":null,
        "edit_100_gate":"NOT_QUALIFIED",
        "collider_response_gate":"NOT_QUALIFIED",
        "evidence_mode":evidence,
        "in_engine_stills_enabled":evidence_stills,
        "video_marker_only":evidence and not evidence_stills,
        "note":"EVIDENCE ONLY: scripted edits are not HID; marker and frame_post_draw are not correct presented pixels. External desktop video with ROI/pixel verification and ETW required for EDIT-100. Optional in-engine screenshot mode changes timing."
    }
    var file:=FileAccess.open(folder.path_join("a7_edits.json"),FileAccess.WRITE)
    if file==null:
        _fail("summary IO failed")
        return
    file.store_string(JSON.stringify(summary,"  "))
    file.close()
    print("A7_EDIT_REPORT_OK scenario=",scenario," count=",count,
          " accepted=",accepted," SDF_changed=",sdf_changed,
          " max_apply_ms=",max_apply," pixel=NOT_QUALIFIED")
    world.queue_free()
    quit(0)
