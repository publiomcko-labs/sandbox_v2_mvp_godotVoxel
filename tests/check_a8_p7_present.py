"""A8-P7 synthetic PresentMon ETW and frame-spike audit regressions.

No headless benchmark is accepted as GPU evidence. This verifies the
parser, 16.7/20/33/50/100ms extreme tails and rejection of bad provenance.
"""
from __future__ import annotations
import csv
import json
import tempfile
from datetime import datetime
from pathlib import Path
import sys

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"scripts"))
from a8_p7_present_report import audit,stats,histogram,find_arm,route_trace

assert histogram([16.7,16.701,20.01,33.01,50.01,100.01]) == {
    "over_16_7_ms":5,"over_20_0_ms":4,"over_33_0_ms":3,
    "over_50_0_ms":2,"over_100_0_ms":1}
assert stats([3,5,9])["max_ms"]==9
assert stats([])["max_ms"] is None

source=(ROOT/"scripts/a7-run-windows.ps1").read_text(encoding="utf-8")
runtime=(ROOT/"godot/tests/a7_route_runtime.gd").read_text(encoding="utf-8")
runner=(ROOT/"godot/tests/a7_route_runner.gd").read_text(encoding="utf-8")
launch=(ROOT/"scripts/a8-p7-present-windows.ps1").read_text(encoding="utf-8")
assert "[switch] $A8P7Performance" in source
assert "--a8-p7-performance" in source
assert "A8_P7_REQUIRES_FULL_ETW_30S_GPU_NO_CAPTURE_WARMUP_1000_SEED_20261119" in source
assert "A8_P7_REQUIRES_INTERACTIVE_GPU_SESSION_NOT_SERVICE_SESSION_0" in launch
assert "PresentMonExe" in launch and "a7-etw-session-guard.ps1" in launch
assert "A8_P7_ETW_PERMISSION_REQUIRED" in launch
assert "ResourceTelemetry=$true" in launch
assert "WarmupFrames=1000" in launch
assert "A8_P7_PILOT_VALID_ETW=TRUE strict=NOT_QUALIFIED" in launch
assert "var a8_p7_performance := false" in runtime
assert "a8_p7_spikes.json" in runtime
assert "P7_MAX_SPIKES := 4096" in runtime
assert "a8_p7_performance" in runner

def emit(path,data):
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(json.dumps(data),encoding="utf-8")

with tempfile.TemporaryDirectory() as tmp:
    root=Path(tmp)
    arm=root/"turns_18mps_300s_seed20261119_rep01"
    arm.mkdir()
    start=1_700_000_000.0
    manifest={
        "schema":"a7_campaign_v1",
        "baseline_checkpoint":"0c3fee959576d0a1faec9ceecffb4b132a65558b",
        "a8_p7_performance_requested":True,
        "presentmon_requested":True,
        "presentmon_gpu_tracking_requested":True,
        "capture":False,"ci_smoke":False,"full":False,
        "resource_diagnostic":True,
        "warmup_frames_requested":1000,"duration_override_s":30,
        "seeds":[20261119],"scenarios":["turns_18mps_300s"],
        "repeats":1,"voxel_threads_requested":0,
        "target_resolution":"1920x1080",
        "a8_p5_depth_video_requested":False,"a8_visual_evidence_requested":False,
        "git_sha":"a"*40,
    }
    emit(root/"manifest.json",manifest)
    route={
        "schema":"a7_route_v1","a8_p7_performance":True,
        "route":"turns_18mps_300s","seed":20261119,
        "duration_s":30.0,
        "warmup_drawn_frames_requested":1000,
        "warmup_drawn_frames_observed":1000,
        "capture":False,"screenshots":0,
        "a8_p5_depth_video":False,"ci_smoke":False,
        "voxel_threads_requested":0,"frame_count":1750,
        "vsync_mode_actual":1,
        "measurement_epoch_begin_s":start,
        "measurement_epoch_end_s":start+30.00,
        "frame_intervals_over_16_7_ms":1,
        "frame_intervals_over_20_ms":0,
        "frame_intervals_over_33_ms":0,
        "frame_start_p50_ms":16.64,"frame_start_p95_ms":16.67,
        "frame_start_p99_ms":16.69,"frame_start_p999_ms":16.7,
        "frame_start_max_ms":17.4,
        "perf_60_full_present_gate":"NOT_QUALIFIED",
        "stream_18_pixel_gate":"NOT_QUALIFIED",
        "view_130_pixel_depth_gate":"NOT_QUALIFIED"
    }
    emit(arm/"a7_route.json",route)
    spike={
        "schema":"a8_p7_spikes_v1","seed":20261119,
        "route":"turns_18mps_300s","duration_s":30.0,
        "measurement_epoch_begin_s":start,
        "frame_count":1750,"threshold_ms":16.7,
        "events":[[1.0,17.4,60]],
        "over_16_7_total":1,"overflow":0,
        "strict_perf_60":"NOT_QUALIFIED"
    }
    emit(arm/"a8_p7_spikes.json",spike)
    with (arm/"a7_route.jsonl").open("w",encoding="utf-8") as file:
        for i in range(30):
            file.write(json.dumps({
                "type":"sample","phase":"moving","t_s":i+0.01,
                "voxel_workers":{"queued_tasks":i%5,"active_threads":2},
                "mesh_blocks":105+i,"data_blocks":201+i,
                "meshed_radial_probes":8,
                "viewport_render_cpu_ms":2.0,
                "viewport_render_gpu_ms":4.0,
                "physics_ms":1.2,"process_ms":1.1,
            })+"\n")
    status={
        "collection_started":True,"exit_code":0,
        "gpu_tracking_requested":True,
        "etw_events_lost":0,"etw_buffers_lost":0,
        "csv_exists":True,"csv_bytes":199999,
        "capture_requested_duration_s":0,
    }
    emit(arm/"a7_presentmon_status.json",status)
    headers=("CPUStartDateTime","DisplayLatency","DisplayedTime",
             "FrameTime","CPUBusy","GPUTime","SwapChainAddress","PresentMode")
    with (arm/"a7_presentmon.csv").open("w",newline="",encoding="utf-8") as file:
        writer=csv.DictWriter(file,fieldnames=headers)
        writer.writeheader()
        elapsed=0.0
        for i in range(1771):
            elapsed+=1/60
            if i==600:elapsed+=.05
            # Keep ETW CPUStart inside 30s and monotonic.
            if elapsed>29.99:break
            writer.writerow({
                "CPUStartDateTime":datetime.fromtimestamp(start+elapsed).isoformat(sep=" "),
                "DisplayLatency":11,"DisplayedTime":16.6667,
                "FrameTime":16.6667,"CPUBusy":2,"GPUTime":4.0,
                "SwapChainAddress":"0xA5","PresentMode":"Composed: Flip"
            })
    report=audit(root)
    assert report["schema"]=="a8_p7_extreme_frame_pilot_v1"
    assert report["presentmon_etw_status"]=="ETW_ALIGNED", report
    assert report["frame_presentation_cadence"]["max_ms"]>33, report
    assert report["frame_presentation_cadence"]["over_33_0_ms"]>=1
    assert report["frame_presentation_cadence"]["over_16_7_ms"]>=1
    assert report["frame_presentation_cadence"]["fraction_over_16_7"]>0
    assert report["presentmon_gpu_work"]["p99_ms"]==4
    assert report["voxel_worker_queue_peak"]==4
    assert report["godot_spike_event_count"]==1
    assert all(report[k]=="NOT_QUALIFIED" for k in
               ("strict_perf_60","strict_stream_18","strict_view_130","strict_edit_100"))
    assert report["automatic_causal_attribution"] is False
    assert report["full_60fps_contract_verified"] is False
    assert all(x["proven_causal_subsystem"] is None
               for x in report["display_event_outliers_top_30"])
    def rejected(file,mutator):
        orig=file.read_bytes()
        value=json.loads(orig.decode())
        mutator(value)
        emit(file,value)
        try:audit(root)
        except ValueError:pass
        else:raise AssertionError("bad A8-P7 input was accepted")
        file.write_bytes(orig)
    rejected(root/"manifest.json",lambda x:x.update({"warmup_frames_requested":999}))
    rejected(root/"manifest.json",lambda x:x.update({"capture":True}))
    rejected(root/"manifest.json",lambda x:x.update({"seeds":[20261120]}))
    rejected(root/"manifest.json",lambda x:x.update({"presentmon_gpu_tracking_requested":False}))
    rejected(arm/"a7_route.json",lambda x:x.update({"stream_18_pixel_gate":"PASS"}))
    rejected(arm/"a7_route.json",lambda x:x.update({"warmup_drawn_frames_observed":999}))
    rejected(arm/"a8_p7_spikes.json",lambda x:x.update({"events":[]}))
    rejected(arm/"a8_p7_spikes.json",lambda x:x.update({"overflow":-1}))
    rejected(arm/"a7_presentmon_status.json",lambda x:x.update({"etw_events_lost":1}))
    rejected(arm/"a7_presentmon_status.json",lambda x:x.update({"gpu_tracking_requested":False}))

print("A8_P7_PRESENTMON_EXTREME_TAILS_AND_FAIL_CLOSED_PASS GPU_NOT_MEASURED")
