"""A8-P2 visual collection: CPU fixtures prove no mistaken 60FPS/130m acceptance."""
from __future__ import annotations
import sys, tempfile, json
from pathlib import Path

root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/"scripts"))
import a8_visual_audit as a8

def write(path,obj):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(obj),encoding="utf-8")

with tempfile.TemporaryDirectory() as tmp:
    d=Path(tmp)
    manifest={
        "schema":"a7_visual_evidence_manifest_v1",
        "mode":"Route","scenario":"turns_18mps_300s","seed":20261119,
        "a8_visual_evidence_requested":True,"warmup_frames_requested":1000,
        "game_run_succeeded":True,"capture_mode_valid":True,
        "video_capture_valid_container":True,"video_exit_code":0,
        "recorder_mode":"ddagrab_nvenc","video_fps_requested":60,
        "video_capture_region_xywh":[0,0,1920,1080],
        "presentmon_requested":False,"in_engine_screenshot_interval_s":0,
        "strict_gates":"NOT_QUALIFIED","video_bytes":1_000_001
    }
    campaign={
        "baseline_checkpoint":"0c3fee959576d0a1faec9ceecffb4b132a65558b",
        "capture":True,"full":False,"warmup_frames_requested":1000,
        "a8_visual_evidence_requested":True,
        "mesh_block_voxels":16,"lod_count":4,"target_speed_mps":18,"repeats":1
    }
    route={
        "schema":"a7_route_v1","route":"turns_18mps_300s","seed":20261119,
        "capture":True,"a8_visual_evidence":True,
        "warmup_drawn_frames_requested":1000,"warmup_drawn_frames_observed":1000,
        "warmup_observed_s":16.67,"duration_s":30.0,"screenshots":0,
        "perf_60_full_present_gate":"NOT_QUALIFIED",
        "stream_18_pixel_gate":"NOT_QUALIFIED",
        "view_130_pixel_depth_gate":"NOT_QUALIFIED"
    }
    timeline={
        "schema":"a7_video_timeline_v1","source_mode":"Route",
        "pixel_terrain_correctness_verified":False,"depth_coverage_verified":False,
        "marker":{"sequence_verified":True,"alignment_verified":True,
                  "offset_residual_p99_ms":8},
        "route_movement_window":{"frames":1740,"elapsed_pts_s":29.0,
            "observed_fps":59.97,"gap_max_ms":22.0,"gaps_over_33ms":0,
            "duplicated_pts_pairs":0},
        "strict_stream_18":"NOT_QUALIFIED","strict_view_130":"NOT_QUALIFIED"
    }
    mp=d/"visual_evidence_manifest.json"
    cp=d/"game"/"manifest.json"
    rp=d/"game"/"turns_18mps_300s_seed20261119_rep01"/"a7_route.json"
    tp=d/"a7_video_timeline.json"
    video=d/"desktop-1080p-60fps.mkv"
    video.write_bytes(b"x"*1_000_001)
    for p,x in ((mp,manifest),(cp,campaign),(rp,route),(tp,timeline)):
        write(p,x)
    result=a8.report(d)
    assert result["warmup_drawn_frames"]==1000
    assert result["video_sha256"]
    assert result["visual_review"]=="REQUIRED_ORIGINAL_VIDEO"
    assert result["strict_stream_18"]=="NOT_QUALIFIED"
    assert result["strict_view_130"]=="NOT_QUALIFIED"
    assert result["automatic_acceptance"] is False
    (d/"a8_visual_review.json").unlink()
    # Missing 1000 frames is not silently converted into 'video valid'.
    route["warmup_drawn_frames_observed"]=999
    write(rp,route)
    try: a8.report(d);raise AssertionError("accepted 999 warmup frames")
    except ValueError: pass
    route["warmup_drawn_frames_observed"]=1000
    write(rp,route)
    # Marker mismatch may be recorder loss; fail diagnostic integrity.
    timeline["marker"]["alignment_verified"]=False
    write(tp,timeline)
    try: a8.report(d);raise AssertionError("accepted invalid marker clock")
    except ValueError: pass
    timeline["marker"]["alignment_verified"]=True
    # FPS can be insufficient but is a warning rather than a fabricated PASS.
    timeline["route_movement_window"]["observed_fps"]=40.0
    write(tp,timeline)
    r=a8.report(d)
    assert r["recording_cadence_warning"] is True
    assert r["strict_stream_18"]=="NOT_QUALIFIED"
    (d/"a8_visual_review.json").unlink()
    # Never accept an asserted depth qualification without independent proof.
    timeline["depth_coverage_verified"]=True
    write(tp,timeline)
    try: a8.report(d);raise AssertionError("accepted self-declared depth verification")
    except ValueError: pass
    timeline["depth_coverage_verified"]=False
    write(tp,timeline)
    manifest["video_bytes"]=10
    write(mp,manifest)
    try: a8.report(d);raise AssertionError("accepted size-mismatched video")
    except ValueError: pass

# Source mode is deliberately separate from strict full-performance runs.
ps=(root/"scripts/a7-run-windows.ps1").read_text(encoding="utf-8")
godot=(root/"godot/tests/a7_route_runner.gd").read_text(encoding="utf-8")
runtime=(root/"godot/tests/a7_route_runtime.gd").read_text(encoding="utf-8")
record=(root/"scripts/a7-record-evidence-windows.ps1").read_text(encoding="utf-8")
wrapper=(root/"scripts/a8-p2-visual-windows.ps1").read_text(encoding="utf-8")
assert "A8_VISUAL_EVIDENCE_REQUIRES_SEPARATE_CAPTURE_1000_FRAMES_NORMAL_VSYNC" in ps
assert "A8_VISUAL_EVIDENCE_REQUIRES_1000_FRAMES_DDAGRAB_NVENC_ROUTE" in record
assert "a8-visual-evidence" in godot
assert "warmup_drawn_frames_observed" in runtime
assert "'A8_VISUAL_TIMELINE_INVALID" in wrapper
assert "a8_visual_evidence.zip" in wrapper
print("A8_VISUAL_1000_FRAME_EVIDENCE_CONTRACT_PASS")
