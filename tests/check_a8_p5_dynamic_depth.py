"""A8-P5 offline negative controls; synthetic video bytes NEVER prove GPU depth."""
from __future__ import annotations
import json
import sys
import tempfile
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/"scripts"))
from a8_p5_dynamic_depth_review import (
    category,classify_sample,frame_indices,assess,PIXELS,N
)

assert category((2,250,2))=="DEPTH_INSIDE_130"
assert category((254,1,4))=="DEPTH_OUTSIDE_130"
assert category((245,241,2))=="DEPTH_BORDERLINE_130"
assert category((1,1,254))=="DEPTH_NO_OPAQUE_HIT"
assert category((124,124,124))=="DEPTH_INVALID_COLOR"

for kind,dist,obs,risk in (
    ("SDF_INSIDE_125",100.0,"DEPTH_INSIDE_130","SAMPLED_EXPECTED_NEAR_GROUND_PRESENT"),
    ("SDF_INSIDE_125",100.0,"DEPTH_NO_OPAQUE_HIT","POTENTIAL_MISSING_DEPTH_WITHIN_125"),
    ("SDF_BOUNDARY_125_135",130.0,"DEPTH_OUTSIDE_130","NO_INSIDE_125_ASSERTION"),
    ("SDF_OUTSIDE_135",200.0,"DEPTH_OUTSIDE_130","NO_INSIDE_125_ASSERTION"),
    ("SDF_NO_HIT",None,"DEPTH_NO_OPAQUE_HIT","NO_INSIDE_125_ASSERTION"),
):
    r=classify_sample({"pixel_1080":[240,280],
                       "sdf_category":kind,"sdf_horizontal_m":dist},obs)
    assert r["risk"]==risk

def reject_sample(row,observed):
    try:classify_sample(row,observed)
    except ValueError:return
    raise AssertionError("accepted altered 130m SDF evidence")
reject_sample({"pixel_1080":[240,280],"sdf_category":"SDF_INSIDE_125",
               "sdf_horizontal_m":150},"DEPTH_INSIDE_130")
reject_sample({"pixel_1080":[240,280],"sdf_category":"SDF_NO_HIT",
               "sdf_horizontal_m":15},"DEPTH_NO_OPAQUE_HIT")
reject_sample({"pixel_1080":[240,280],"sdf_category":"SDF_INSIDE_125",
               "sdf_horizontal_m":100},"invalid")

marks=[{"event_index":i,"video_frame_index":i*58+10,
        "video_pts_s":float(i),"offset_residual_ms":0.0} for i in range(31)]
selectors=frame_indices(marks)
assert len(selectors)==30 and selectors[0]==(0,12,0.0)
bad=[dict(m) for m in marks];bad[2]["video_frame_index"]=bad[1]["video_frame_index"]+1
try:frame_indices(bad);raise AssertionError("accepted missing frames")
except ValueError:pass
bad=[dict(m) for m in marks];bad[2]["video_pts_s"]=bad[1]["video_pts_s"]+2.0
try:frame_indices(bad);raise AssertionError("accepted broken HUD timestamp")
except ValueError:pass

with tempfile.TemporaryDirectory() as temp:
    work=Path(temp)
    def write(path,object):
        path.parent.mkdir(parents=True,exist_ok=True)
        path.write_text(json.dumps(object),encoding="utf-8")
    def create_arm(arm):
        r=work/arm
        video=r/"desktop-1080p-60fps.mkv"
        video.parent.mkdir(parents=True,exist_ok=True)
        video.write_bytes((arm*160000).encode()[:1100000] + b"x"*1200000)
        is_depth=arm=="depth"
        m={
            "schema":"a7_visual_evidence_manifest_v1","mode":"Route",
            "scenario":"turns_18mps_300s","seed":20261119,
            "warmup_frames_requested":1000,"a8_visual_evidence_requested":True,
            "a8_p5_depth_video_requested":is_depth,"game_run_succeeded":True,
            "video_capture_valid_container":True,"recorder_mode":"ddagrab_nvenc",
            "video_capture_region_xywh":[0,0,1920,1080],"video_fps_requested":60,
            "in_engine_screenshot_interval_s":0,"strict_gates":"NOT_QUALIFIED",
            "video_bytes":video.stat().st_size,"video_path":str(video),
            "duration_override_s":30,"git_sha":"a"*40
        }
        g={
            "baseline_checkpoint":"0c3fee959576d0a1faec9ceecffb4b132a65558b",
            "mesh_block_voxels":16,"lod_count":4,"target_speed_mps":18.0,
            "seeds":[20261119],"capture":True,"warmup_frames_requested":1000,
            "a8_p5_depth_video_requested":is_depth,"full":False,
            "repeats":1,"git_sha":"a"*40
        }
        p={
            "schema":"a7_route_v1","route":"turns_18mps_300s",
            "seed":20261119,"duration_s":30.0,
            "a8_visual_evidence":True,"a8_p5_depth_video":is_depth,
            "capture":True,"warmup_drawn_frames_requested":1000,
            "warmup_drawn_frames_observed":1000,"screenshots":0,
            "perf_60_full_present_gate":"NOT_QUALIFIED",
            "stream_18_pixel_gate":"NOT_QUALIFIED",
            "view_130_pixel_depth_gate":"NOT_QUALIFIED",
            "a8_p5_depth_calibrations":[
                {"distance_m":25.0,"expected":"DEPTH_INSIDE_130",
                 "observed":"DEPTH_INSIDE_130","passed":True},
                {"distance_m":165.0,"expected":"DEPTH_OUTSIDE_130",
                 "observed":"DEPTH_OUTSIDE_130","passed":True}
            ] if is_depth else [],
            "a8_p5_sdf_samples":31 if is_depth else 0,
        }
        aligned=[dict(x) for x in marks]
        t={
            "schema":"a7_video_timeline_v1","source_mode":"Route",
            "pixel_terrain_correctness_verified":False,
            "depth_coverage_verified":False,
            "strict_stream_18":"NOT_QUALIFIED","strict_view_130":"NOT_QUALIFIED",
            "marker":{"sequence_verified":True,"alignment_verified":True,
                      "aligned_events":aligned,"offset_residual_p99_ms":10.0},
            "route_movement_window":{"frames":1741,"elapsed_pts_s":30.0,
                                     "observed_fps":58.0,"gaps_over_33ms":32}
        }
        path=r/"game"/"turns_18mps_300s_seed20261119_rep01"
        samples=[]
        if is_depth:
            for i in range(31):
                seconds=i+0.02 if i<30 else 30.0
                pos=[min(seconds*18,360),22.0,18+max(0,seconds-20)*18]
                samples.append({
                    "type":"a8_p5_sdf_expectation","index":i,
                    "route_t_s":seconds,"player_xyz":pos,
                    "sample_count":35,"ground_source":"GENERATOR_ONLY_NOT_RENDERED",
                    "video_synchronization":"HUD_MARKER_AND_NVENC_PTS_APPROXIMATE",
                    "samples":[{"pixel_1080":list(px),
                                "sdf_category":"SDF_INSIDE_125",
                                "sdf_horizontal_m":85.0} for px in PIXELS],
                    "expected_inside_125":35
                })
        write(r/"visual_evidence_manifest.json",m)
        write(r/"game"/"manifest.json",g)
        write(r/"a7_video_timeline.json",t)
        write(path/"a7_route.json",p)
        path.joinpath("a7_route.jsonl").write_text(
            "\n".join(json.dumps(s) for s in samples)+"\n",encoding="utf-8")
    create_arm("rgb")
    create_arm("depth")
    fixture=assess(work,ffmpeg="",decode=False)
    assert fixture["strict_view_130"]=="NOT_QUALIFIED"
    assert fixture["selected_frames"]==0
    assert fixture["synchronized_marker_count_each_arm"]==31
    assert len(fixture["seconds"])==30

    def reject_file(path,edit):
        original=path.read_bytes()
        obj=json.loads(original.decode())
        edit(obj)
        write(path,obj)
        try:assess(work,ffmpeg="",decode=False)
        except ValueError:pass
        else:raise AssertionError("accepted invalid paired-arm evidence")
        path.write_bytes(original)

    reject_file(work/"depth"/"a7_video_timeline.json",
                lambda x:x["marker"].__setitem__("alignment_verified",False))
    reject_file(work/"depth"/"a7_video_timeline.json",
                lambda x:x["marker"]["aligned_events"].pop())
    reject_file(work/"depth"/"game"/"turns_18mps_300s_seed20261119_rep01"/"a7_route.json",
                lambda x:x["a8_p5_depth_calibrations"][1].__setitem__("passed",False))
    reject_file(work/"rgb"/"visual_evidence_manifest.json",
                lambda x:x.__setitem__("git_sha","b"*40))
    reject_file(work/"rgb"/"game"/"manifest.json",
                lambda x:x.__setitem__("a8_p5_depth_video_requested",True))
    reject_file(work/"depth"/"game"/"turns_18mps_300s_seed20261119_rep01"/"a7_route.json",
                lambda x:x.__setitem__("stream_18_pixel_gate","PASS"))

runner=(root/"godot/tests/a7_route_runner.gd").read_text()
runtime=(root/"godot/tests/a7_route_runtime.gd").read_text()
module=(root/"godot/tests/a8_p5_depth_video.gd").read_text()
launch=(root/"scripts/a8-p5-dynamic-depth-windows.ps1").read_text()
recorder=(root/"scripts/a7-record-evidence-windows.ps1").read_text()
assert "--a8-p5-depth-video" in (root/"scripts/a7-run-windows.ps1").read_text()
assert "a8_p5_depth_video" in runtime
assert "A8_P5_DEPTH_REQUIRES_30S_NVENC_1000_FRAMES" in recorder
assert 'await _p5_depth_module.calibrate()' in runtime
assert "get_texture().get_image()" in module
assert "SDF_INSIDE_125" in module and "begin_video" in module
assert "a8_p5_dynamic_depth_evidence.zip" in launch
assert "game_run_succeeded" in (root/"scripts/a7-record-evidence-windows.ps1").read_text()
print("A8_P5_DYNAMIC_GPU_DEPTH_VIDEO_PROVENANCE_FAIL_CLOSED_PASS")
