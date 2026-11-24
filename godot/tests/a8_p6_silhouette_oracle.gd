extends SceneTree
# A8-P6 triage of frozen *actual source-video* green->blue pixels.
# CPU-only SDF expected; no actual GPU raster/depth interpretation.
const TerrainSDF=preload("res://scripts/terrain_sdf.gd")
const Routes=preload("res://tests/a7_routes.gd")
const INPUT="res://tests/fixtures/a8_p6_silhouette_targets.json"
const SOURCE_SHA="d553f73d1e94b279da972773a80972f94718791f14387a68b0ce4c1a05e449cb"
const SEED=20261119
var generator: VoxelGeneratorGraph
var rig: Node3D
var camera: Camera3D

func _initialize() -> void:
    call_deferred("_start")

func _fail(s:String) -> void:
    push_error("A8_P6_SILHOUETTE_FAIL "+s)
    quit(2)

func _ray_cm(t:float,px:Vector2) -> int:
    var pos:Vector3=Routes.position_for("turns_18mps_300s",t)
    var future:Vector3=Routes.position_for("turns_18mps_300s",minf(t+0.04,30.0))
    var motion:=future-pos
    if motion.length_squared()<0.0001:
        motion=pos-Routes.position_for("turns_18mps_300s",maxf(0.0,t-0.04))
    if motion.length_squared()<0.0001: return -1
    rig.global_position=pos
    rig.rotation.y=atan2(-motion.x,-motion.z)
    rig.force_update_transform()
    camera.force_update_transform()
    var origin:=camera.project_ray_origin(px)
    var direction:=camera.project_ray_normal(px).normalized()
    var ray_m:float=generator.raycast_sdf_approx(origin,origin+direction*320.0,0.5)
    if not is_finite(ray_m) or ray_m<0.0: return -1
    var point:=origin+direction*ray_m
    return int(round(Vector2(point.x-pos.x,point.z-pos.z).length()*100.0))

func _start() -> void:
    var output:=OS.get_environment("A8_P6_OUTPUT_DIR")
    if output.is_empty() or DirAccess.make_dir_recursive_absolute(output)!=OK:
        _fail("A8_P6_OUTPUT_DIR required")
        return
    var f:=FileAccess.open(INPUT,FileAccess.READ)
    if f==null:
        _fail("silhouette fixture missing")
        return
    var parsed:Variant=JSON.parse_string(f.get_as_text())
    f.close()
    if not parsed is Dictionary:
        _fail("invalid fixture json")
        return
    var fixture:Dictionary=parsed
    var items:Array=fixture.get("events",[])
    if (str(fixture.get("schema",""))!="a8_p6_silhouette_targets_v1" or
            str(fixture.get("source_depth_video_sha256",""))!=SOURCE_SHA or
            int(fixture.get("seed",0))!=SEED or
            str(fixture.get("route",""))!="turns_18mps_300s" or
            int(fixture.get("event_count",0))!=11 or items.size()!=11 or
            fixture.get("no_strict_pass_from_color")!=true):
        _fail("wrong video SHA/route/frozen fixture")
        return
    generator=TerrainSDF.build_generator(SEED)
    if generator==null:
        _fail("generator compile failed")
        return
    root.size=Vector2i(1920,1080)
    rig=Node3D.new()
    root.add_child(rig)
    camera=Camera3D.new()
    camera.fov=75.0
    camera.far=320.0
    camera.rotation.x=deg_to_rad(-22.0)
    rig.add_child(camera)
    camera.make_current()
    await process_frame
    await process_frame
    if root.get_visible_rect().size!=Vector2(1920,1080):
        _fail("unexpected headless screen")
        return
    var records:Array=[]
    var event_counts:Dictionary={"SDF_INSIDE_120_STABLE":0,
        "SDF_OUTSIDE_140_STABLE":0,"SDF_TEMPORAL_OR_BOUNDARY_UNKNOWN":0}
    for entry in items:
        if not entry is Dictionary:
            _fail("invalid event entry")
            return
        var item:Dictionary=entry
        var px:Array=item.get("pixel_1080",[])
        var before:Array=item.get("before_rgb",[])
        var after:Array=item.get("after_rgb",[])
        var t:float=float(item.get("route_t_s",-1.0))
        if (px.size()!=2 or before.size()!=3 or after.size()!=3 or
                t<0.0 or t>=30.0 or int(px[0])<0 or int(px[0])>=1920 or
                int(px[1])<0 or int(px[1])>=1080 or
                int(before[1])<180 or int(before[0])>100 or
                int(before[2])>100 or int(after[2])<180 or
                int(after[0])>100 or int(after[1])>100):
            _fail("source RGB transition no longer green->blue")
            return
        var uv:=Vector2(float(px[0]),float(px[1]))
        var prev_cm:=_ray_cm(maxf(0.0,t-1.0/60.0),uv)
        var this_cm:=_ray_cm(t,uv)
        var next_cm:=_ray_cm(minf(29.999,t+1.0/60.0),uv)
        var stable=(prev_cm>=0 and this_cm>=0 and next_cm>=0 and
            maxi(maxi(prev_cm,this_cm),next_cm)-
            mini(mini(prev_cm,this_cm),next_cm)<=800)
        var classification:=(
            "SDF_TEMPORAL_OR_BOUNDARY_UNKNOWN" if not stable else
            "SDF_INSIDE_120_STABLE" if this_cm<12000 else
            "SDF_OUTSIDE_140_STABLE" if this_cm>14000 else
            "SDF_TEMPORAL_OR_BOUNDARY_UNKNOWN")
        event_counts[classification]+=1
        records.append({
            "source_video_frame":item.get("original_video_frame"),
            "video_pts_s":item.get("video_pts_s"),"route_t_s":t,
            "pixel_1080":px,"before_rgb":before,"after_rgb":after,
            "sdf_prev_horizontal_cm":prev_cm,
            "sdf_at_event_horizontal_cm":this_cm,
            "sdf_next_horizontal_cm":next_cm,
            "classification":classification,
            "source":"GENERATOR_EXPECTED_NOT_GPU_MESH"
        })
    var report:={
        "schema":"a8_p6_11_silhouette_sdf_oracle_v1",
        "video_sha256":SOURCE_SHA,"seed":SEED,
        "source_event_fixture":INPUT,
        "event_count":records.size(),"counts":event_counts,
        "events":records,
        "rendered_depth_is_only_from_source_video":true,
        "SDF_does_not_measure_mesh_publication":true,
        "temporal_gap_is_estimated_at_60hz":true,
        "camera_pose_reconstructed_not_recorded":true,
        "strict_perf_60":"NOT_QUALIFIED",
        "strict_stream_18":"NOT_QUALIFIED",
        "strict_view_130":"NOT_QUALIFIED",
        "strict_edit_100":"NOT_QUALIFIED",
        "automatic_acceptance":false
    }
    var output_path:=output.path_join("a8_p6_11_silhouette_sdf.json")
    var dest:=FileAccess.open(output_path,FileAccess.WRITE)
    if dest==null:
        _fail("cannot write silhouette SDF")
        return
    dest.store_string(JSON.stringify(report,"  "))
    dest.close()
    print("A8_P6_SILHOUETTE_SDF_FINISHED counts=",JSON.stringify(event_counts),
          " strict=NOT_QUALIFIED")
    quit(0)
