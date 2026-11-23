"""A8-P0: CPU-only regression against fabricated route telemetry and fail-closed checks."""
from __future__ import annotations
import json
import sys
import tempfile
from pathlib import Path

root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/"scripts"))
import a8_route_triage as a8


def write(path,obj):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(obj),encoding="utf-8")


with tempfile.TemporaryDirectory() as tmp:
    folder=Path(tmp)
    manifest={
        "schema":"a7_campaign_v1",
        "baseline_checkpoint":a8.A5_SHA,
        "ci_smoke":False,"full":False,"capture":False,"presentmon_requested":False,
        "warmup_frames_requested":1000,"mesh_block_voxels":16,
        "lod_count":4,"requested_view_distance_m":192,"repeats":1,
        "scenarios":["straight_18mps_600s"],"seeds":[20261119]
    }
    write(folder/"manifest.json",manifest)
    trial=folder/"straight_18mps_600s_seed20261119_rep01"
    report={
        "schema":"a7_route_v1","route":"straight_18mps_600s",
        "seed":20261119,"ci_smoke":False,"capture":False,
        "warmup_drawn_frames_requested":1000,"warmup_drawn_frames_observed":1000,
        "warmup_observed_s":16.7, "frame_count":1800,"screenshots":0,
        "gpu_render_samples":1800,"perf_60_full_present_gate":"NOT_QUALIFIED",
        "stream_18_pixel_gate":"NOT_QUALIFIED",
        "view_130_pixel_depth_gate":"NOT_QUALIFIED",
        "voxel_threads_requested":0,"vsync_off_requested":False,
        "duration_s":30.0,"frame_start_p50_ms":16.6,
        "frame_start_p95_ms":16.7,"frame_start_p99_ms":23.0,
        "frame_start_p999_ms":35.0,"frame_start_max_ms":40.0,
        "frame_intervals_over_16_7_ms":15,
        "frame_intervals_over_20_ms":4,
        "frame_intervals_over_33_ms":1,
        "viewport_render_cpu_p99_ms":6.0,
        "viewport_render_gpu_p99_ms":8.0
    }
    write(trial/"a7_route.json",report)
    trace=[
        {"type":"metadata","schema":"a7_route_v1"},
        {"type":"warmup_end","warmup_drawn_frames_requested":1000,
         "warmup_drawn_frames_observed":1000},
    ]
    for i in range(5):
        trace.append({
            "type":"sample","phase":"moving","t_s":float(i),
            "player_x":float(i*18),"player_z":0.0,"meshed_radial_probes":7 if i==3 else 8,
            "voxel_workers":{"queued_tasks":i*2,"active_threads":4},
        })
    trial.joinpath("a7_route.jsonl").write_text(
        "\n".join(json.dumps(x) for x in trace)+"\n",encoding="utf-8")
    res=a8.summarize(folder)
    assert res["warmup_rendered_frames"]==1000
    assert res["sampled_horizontal_speed_mps_median"]==18.0
    assert res["min_130m_mesh_probes_per_sample"]==7
    assert res["max_voxel_worker_queue"]==8
    assert res["start_intervals_over_16_7_ms"]==15
    assert res["diagnostic_flags"]["mesh_probes_incomplete"] is True
    assert res["perf_60_gate"]=="NOT_QUALIFIED"
    assert res["stream_18_gate"]=="NOT_QUALIFIED"
    assert res["view_130_gate"]=="NOT_QUALIFIED"
    assert res["automatic_acceptance"] is False
    # No headless evidence masquerading as GPU results.
    manifest["ci_smoke"]=True
    write(folder/"manifest.json",manifest)
    try:
        a8.summarize(folder)
        raise AssertionError("accepted headless as GPU")
    except ValueError: pass
    manifest["ci_smoke"]=False
    manifest["capture"]=True
    write(folder/"manifest.json",manifest)
    try:
        a8.summarize(folder)
        raise AssertionError("accepted capture-overhead as canonical pilot")
    except ValueError: pass
    manifest["capture"]=False
    write(folder/"manifest.json",manifest)
    report["warmup_drawn_frames_observed"]=999
    write(trial/"a7_route.json",report)
    try:
        a8.summarize(folder)
        raise AssertionError("accepted incomplete warmup")
    except ValueError: pass
    report["warmup_drawn_frames_observed"]=1000
    report["frame_intervals_over_33_ms"]=999
    write(trial/"a7_route.json",report)
    try:
        a8.summarize(folder)
        raise AssertionError("accepted impossible interval counters")
    except ValueError: pass

# Ensure frame-based warmup is an opt-in that cannot leak into A7 Full/CI.
gd=(root/"godot/tests/a7_route_runtime.gd").read_text(encoding="utf-8")
runner=(root/"godot/tests/a7_route_runner.gd").read_text(encoding="utf-8")
ps=(root/"scripts/a7-run-windows.ps1").read_text(encoding="utf-8")
pilot=(root/"scripts/a8-pilot-windows.ps1").read_text(encoding="utf-8")
assert "Engine.get_frames_drawn() - _warmup_initial_drawn" in gd
assert "warmup_drawn_frames_observed" in gd
assert 'warmup_drawn_frames=warmup_frames' in runner
assert "headless or ci or (capture and not a8_visual_evidence)" in runner
assert "a8_visual_evidence and (headless or ci or not capture or warmup_frames != 1000" in runner
assert "A8_FRAME_WARMUP_RESTRICTED_TO_REAL_GPU_UNRECORDED_SHORT_ROUTE" in ps
assert "if ($WarmupFrames -gt 0)" in ps
assert "[int] $WarmupFrames = 1000" in pilot
assert "-WarmupFrames $WarmupFrames" in pilot
assert '"automatic_acceptance": False' in (root/"scripts/a8_route_triage.py").read_text(encoding="utf-8")
print("A8_FRAME_WARMUP_AND_ROUTE_DIAGNOSTIC_FAIL_CLOSED_PASS")
