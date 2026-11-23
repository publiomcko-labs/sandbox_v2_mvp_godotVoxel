extends SceneTree
# A8-P3 deterministic offline oracle. The exact A8-P2 video pixels are frozen
# in a small fixture. Does NOT instantiate VoxelLodTerrain, an active streamer,
# rock/water render nodes, or GPU readback. Therefore mesh publication cannot
# be inferred from this report.
const TerrainSDF = preload("res://scripts/terrain_sdf.gd")
const Routes = preload("res://tests/a7_routes.gd")
const PIXELS = "res://tests/fixtures/a8_p3_video_pixel_targets.json"
const SCREEN := Vector2i(1920, 1080)
const SEED := 20261119
const MAX_RAY_M := 320.0
const STRIDE_M := 0.5
const RADIUS_M := 130.0
const MARGIN_M := 1.0
const EXPECTED_VIDEO_HASH := "1488b6208f47d62f8c9070cf8896e2af0d97c2cbdf440d1bf7df5377f99f621b"

func _initialize() -> void:
    call_deferred("_start")

func _fail(reason: String) -> void:
    push_error("A8_P3_ORACLE_FAIL "+reason)
    quit(2)

func _xyz(v: Vector3) -> Array:
    return [snappedf(v.x,0.001),snappedf(v.y,0.001),snappedf(v.z,0.001)]

func _classification(dist: float) -> String:
    if not is_finite(dist) or dist < 0.0:
        return "UNKNOWN_NO_SDF_HIT"
    if dist < RADIUS_M - MARGIN_M:
        return "SDF_INSIDE_130"
    if dist > RADIUS_M + MARGIN_M:
        return "SDF_OUTSIDE_130"
    return "SDF_BORDERLINE_130"

func _start() -> void:
    var outdir := OS.get_environment("A8_P3_OUTPUT_DIR")
    if outdir.is_empty() or DirAccess.make_dir_recursive_absolute(outdir) != OK:
        _fail("A8_P3_OUTPUT_DIR required")
        return
    var f := FileAccess.open(PIXELS,FileAccess.READ)
    if f == null:
        _fail("frozen pixel fixture missing")
        return
    var parsed: Variant = JSON.parse_string(f.get_as_text())
    f.close()
    if not parsed is Dictionary:
        _fail("pixel fixture invalid json")
        return
    var fixture: Dictionary = parsed
    var events: Array = fixture.get("events",[])
    # Godot JSON.parse_string numbers are doubles. Compare numeric values
    # explicitly and check arrays element by element, not by variant identity.
    var source_screen: Array = fixture.get("screen_px",[])
    if (str(fixture.get("schema","")) != "a8_p3_video_pixel_targets_v1" or
            str(fixture.get("source_video_sha256","")) != EXPECTED_VIDEO_HASH or
            str(fixture.get("route","")) != "turns_18mps_300s" or
            int(fixture.get("seed",-1)) != SEED or
            source_screen.size() != 2 or
            int(source_screen[0]) != SCREEN.x or
            int(source_screen[1]) != SCREEN.y or
            int(fixture.get("event_count",-1)) != 5 or
            int(fixture.get("ray_samples_per_event",-1)) != 12 or
            events.size() != 5):
        _fail("pixel fixture provenance mismatch values="+JSON.stringify({
            "schema":fixture.get("schema"),"source_hash":fixture.get("source_video_sha256"),
            "route":fixture.get("route"),"seed":fixture.get("seed"),
            "screen":fixture.get("screen_px"),"event_count":fixture.get("event_count"),
            "samples":fixture.get("ray_samples_per_event"),"loaded_events":events.size()
        }))
        return
    var generator: VoxelGeneratorGraph = TerrainSDF.build_generator(SEED)
    if generator == null:
        _fail("independent procedural SDF generator failed to compile")
        return
    root.size = SCREEN
    var rig := Node3D.new()
    root.add_child(rig)
    var camera := Camera3D.new()
    camera.fov = 75.0
    camera.far = 320.0
    camera.rotation.x = deg_to_rad(-22.0)
    rig.add_child(camera)
    camera.make_current()
    await process_frame
    await process_frame
    var actual_size: Vector2 = root.get_visible_rect().size
    if (actual_size - Vector2(SCREEN)).length() > 0.1:
        _fail("camera ray viewport dimensions not 1920x1080: "+str(actual_size))
        return

    var records: Array = []
    var overall_counts := {"SDF_INSIDE_130":0,"SDF_OUTSIDE_130":0,
                            "SDF_BORDERLINE_130":0,"UNKNOWN_NO_SDF_HIT":0}
    var expected_after := [1289,1700,2112,2381,2805]
    var expected_t := [3.616,10.716,17.816,22.600,29.733]
    for index in range(events.size()):
        if not events[index] is Dictionary:
            _fail("malformed event")
            return
        var event: Dictionary = events[index]
        var seconds := float(event.get("route_t_s",-1.0))
        var pixels: Array = event.get("pixels_px",[])
        if (int(event.get("after_frame",-1)) != expected_after[index] or
                absf(seconds - expected_t[index]) > 0.0001 or
                pixels.size() != 12):
            _fail("wrong event clock or pixel count")
            return
        var position: Vector3 = Routes.position_for("turns_18mps_300s",seconds)
        var future: Vector3 = Routes.position_for("turns_18mps_300s",minf(seconds+0.04,30.0))
        var motion := future - position
        if motion.length_squared() < 0.0001:
            motion = position - Routes.position_for("turns_18mps_300s",maxf(0.0,seconds-0.04))
        if motion.length_squared() < 0.0001:
            _fail("undefined route facing")
            return
        rig.global_position = position
        rig.rotation.y = atan2(-motion.x,-motion.z)
        rig.force_update_transform()
        camera.force_update_transform()

        var item := {
            "video_before_frame":event.get("before_frame"),
            "video_after_frame":event.get("after_frame"),
            "route_t_s":seconds,
            "player_position_xyz":_xyz(position),
            "yaw_rad":rig.rotation.y,
            "lod3_span_m":128,
            "player_lod3_grid_xz":[floori(position.x/128.0),floori(position.z/128.0)],
            "ray_samples":[]
        }
        var seen_pixels := {}
        var event_counts := {"SDF_INSIDE_130":0,"SDF_OUTSIDE_130":0,
                             "SDF_BORDERLINE_130":0,"UNKNOWN_NO_SDF_HIT":0}
        for p in pixels:
            if not p is Array or p.size()!=2:
                _fail("malformed pixel")
                return
            var screen_x := int(p[0])
            var screen_y := int(p[1])
            var key := str(screen_x)+","+str(screen_y)
            if (seen_pixels.has(key) or screen_x < 0 or screen_x >= SCREEN.x or
                    screen_y < 0 or screen_y >= SCREEN.y):
                _fail("invalid or duplicate candidate screen pixel")
                return
            seen_pixels[key] = true
            var uv := Vector2(float(screen_x),float(screen_y))
            var ray_origin := camera.project_ray_origin(uv)
            var direction := camera.project_ray_normal(uv).normalized()
            if not ray_origin.is_finite() or not direction.is_finite() or direction.length_squared()<0.99:
                _fail("camera projection not valid")
                return
            var dist := generator.raycast_sdf_approx(
                ray_origin,ray_origin+direction*MAX_RAY_M,STRIDE_M)
            var horizontal := -1.0
            var hit := Vector3.ZERO
            var cls := "UNKNOWN_NO_SDF_HIT"
            if is_finite(dist) and dist >= 0.0:
                hit = ray_origin + direction*dist
                horizontal = Vector2(hit.x-position.x,hit.z-position.z).length()
                cls = _classification(horizontal)
            var row := {
                "pixel_1080":[screen_x,screen_y],
                "ray_origin_xyz":_xyz(ray_origin),
                "ray_direction_xyz":_xyz(direction),
                "raycast_distance_m":snappedf(dist,0.001) if dist >= 0.0 else null,
                "ground_hit_xyz":_xyz(hit) if dist >= 0.0 else null,
                "ground_horizontal_m":snappedf(horizontal,0.001) if dist >= 0.0 else null,
                "ground_expected_lod3_block_xz":[floori(hit.x/128.0),floori(hit.z/128.0)] if dist >= 0.0 else null,
                "classification":cls
            }
            item["ray_samples"].append(row)
            event_counts[cls]+=1
            overall_counts[cls]+=1
        item["classification_counts"] = event_counts
        item["sampled_assessment"] = (
            "HAS_EXPECTED_GROUND_INSIDE_130" if event_counts["SDF_INSIDE_130"]>0 else
            "ONLY_OUTSIDE_OR_UNKNOWN_SAMPLED" if event_counts["SDF_OUTSIDE_130"]>0 else
            "NO_VALID_GROUND_HITS")
        records.append(item)
        print("A8_P3_EVENT frame=",event.get("after_frame")," t_s=",seconds,
              " pos=",position," counts=",JSON.stringify(event_counts))
    var result := {
        "schema":"a8_p3_procedural_depth_oracle_v1",
        "source_video_sha256":EXPECTED_VIDEO_HASH,
        "source_pixel_fixture":PIXELS,
        "world_seed":SEED,
        "route":"turns_18mps_300s",
        "screen":[1920,1080],
        "camera_vertical_fov_deg":75.0,
        "camera_pitch_deg":-22.0,
        "sampled_pixel_count":60,
        "event_count":records.size(),
        "sdf_raycast_max_m":MAX_RAY_M,
        "sdf_raycast_stride_m":STRIDE_M,
        "horizontal_boundary_m":RADIUS_M,
        "classification_margin_m":MARGIN_M,
        "counts":overall_counts,
        "events":records,
        "oracle":"INDEPENDENT_GENERATOR_SDF_APPROX_NOT_RENDERED_MESH",
        "rendered_pixel_depth_measured":false,
        "mesh_publication_timing_measured":false,
        "ground_only_not_water_or_rocks":true,
        "event_time_is_ESTIMATED_FROM_NVENC_PTS":true,
        "camera_transform_is_DETERMINISTIC_RECONSTRUCTION":true,
        "strict_perf_60":"NOT_QUALIFIED",
        "strict_stream_18":"NOT_QUALIFIED",
        "strict_view_130":"NOT_QUALIFIED",
        "strict_edit_100":"NOT_QUALIFIED",
        "automatic_acceptance":false,
        "limitations":[
            "Independent SDF ray hit is expected procedural ground, not measured GPU depth or actual mesh/LOD publication",
            "Samples represent 60 pixel centers chosen from five before-sky/after-green events, not all pixels",
            "No edits in source video; generator-only SDF ignores dynamic rocks and water surfaces",
            "Raycast stride 0.5m, 1m classification guard, camera transform reconstructed from A7 route",
            "Video PTS alignment residual 14ms and missing/duplicated capture timestamps",
            "LOD3 block grid is a spatial hypothesis; no runtime mesh commit/visible revision is measured"
        ]
    }
    var dest := outdir.path_join("a8_p3_procedural_depth.json")
    var handle := FileAccess.open(dest,FileAccess.WRITE)
    if handle == null:
        _fail("unable to write a8_p3_procedural_depth.json")
        return
    handle.store_string(JSON.stringify(result,"  "))
    handle.close()
    print("A8_P3_ORACLE_COMPLETE samples=60 within=",overall_counts["SDF_INSIDE_130"],
          " outside=",overall_counts["SDF_OUTSIDE_130"],
          " borderline=",overall_counts["SDF_BORDERLINE_130"],
          " unknown=",overall_counts["UNKNOWN_NO_SDF_HIT"],
          " gates=NOT_QUALIFIED output=",dest)
    quit(0)
