"""A7.1/A7.2 evidence is optional diagnostic capture; never automatic acceptance."""
from __future__ import annotations
import importlib.util
import json
import csv
import struct
import tempfile
from datetime import datetime
from pathlib import Path

root = Path(__file__).resolve().parents[1]
script = root / "scripts/a7_analyze_visual_evidence.py"
spec = importlib.util.spec_from_file_location("a7_evidence", script)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

route = (root / "godot/tests/a7_route_runtime.gd").read_text(encoding="utf-8")
edit = (root / "godot/tests/a7_edit_runner.gd").read_text(encoding="utf-8")
recorder = (root / "scripts/a7-record-evidence-windows.ps1").read_text(encoding="utf-8")
assert "capture_epoch_s" in route and "capture_ticks_us" in route
assert "_next_screenshot_s+=screenshot_interval_s" in route
assert "screenshot_interval_s>0.0" in route
assert "var screenshot_interval_s := 30.0" in route
route_runner = (root / "godot/tests/a7_route_runner.gd").read_text(encoding="utf-8")
assert 'screenshot-interval-s' in route_runner
assert "runner.screenshot_interval_s=screenshot_interval" in route_runner
assert "pixel_depth_verified" in route and "view_130_geometric_probe_hits" in route
assert "brush_call_epoch_s" in edit and "brush_call_ticks_us" in edit
assert "brush_return_epoch_s" in edit and "brush_return_ticks_us" in edit
assert "target_screen_xy_px" in edit and "target_behind_camera" in edit
assert "first_correct_presented_pixel_ms" in edit
assert "video_marker_meaning" in edit and "NOT correct terrain presentation" in edit
assert 'type":"video_sync' in route
assert "video_sync_marker_crop_xywh" in route
assert "visual_surface_follow" in route and "_surface_tool.raycast" in route
assert "surface_follow_misses" in route and "minimum_surface_clearance_m" in route
assert "if visual_follow and (not capture or ci" in route_runner
assert "ColorRect.new()" in route and "marker_rgb" in route
assert 'var evidence_stills := evidence and not _flag("no-stills")' in edit
assert "var do_capture:=evidence_stills" in edit
bootstrap = (root/"scripts/a7-bootstrap-ffmpeg-windows.ps1").read_text(encoding="utf-8")
assert "04861D3339C5EBE38B56C19A15CF2C0CC97F5DE4FA8910E4D47E5E6404E4A2D4" in bootstrap
assert "a7-ffmpeg-7.1.1" in bootstrap
assert "Get-FileHash" in bootstrap and "Expand-Archive" in bootstrap
assert "Invoke-WebRequest" in bootstrap
assert "a7-bootstrap-ffmpeg-windows.ps1" in recorder
assert "A7_EVIDENCE_REQUIRES_INTERACTIVE_DESKTOP" in recorder
assert "ddagrab_nvenc" in recorder and "gdigrab_x264" in recorder
assert "-c:v h264_nvenc" in recorder and "dup_frames=0" in recorder
assert "-fps_mode passthrough" in recorder
assert "A7_EVIDENCE_DDAGRAB_FILTER_UNAVAILABLE" in recorder
assert "A7_EVIDENCE_NVENC_ENCODER_UNAVAILABLE" in recorder
assert "recorder_mode =" in recorder
assert "$params.VisualSurfaceFollow = $true" in recorder
assert "evidence_camera_surface_follow =" in recorder
assert "evidence_surface_clearance_target_m = 5" in recorder
assert "gdigrab" in recorder and "-framerate 60" in recorder
assert "$screen.Width -lt 1920" in recorder and "$screen.Height -lt 1080" in recorder
assert "desktop_mode_changed = $false" in recorder
assert "video_capture_region_xywh = @(0,0,1920,1080)" in recorder
assert "A7_EVIDENCE_WINDOW_CROP=1920x1080" in recorder
assert "video_actual_fps_verified = $false" in recorder
assert "terrain_pixels_correct_verified = $false" in recorder
assert "strict_gates = 'NOT_QUALIFIED'" in recorder
assert "Capture = $true" in recorder
assert "$params.ScreenshotIntervalSeconds = if ($SkipVideo -and -not $NoStills) { 15.0 } else { 0.0 }" in recorder
assert "$params.EditNoStills = (-not $SkipVideo) -or [bool]$NoStills" in recorder
assert "video_capture_valid_container = [bool]$videoValid" in recorder
assert "capture_mode_valid = [bool]$captureValid" in recorder
assert "$videoValid = (-not $SkipVideo)" in recorder
assert "A7_NO_VIDEO:" in recorder
assert "PresentMonExe" in recorder and "EvidenceOnlyPresentMon" in recorder
assert "-Mode Preflight" in recorder and "-Mode Postflight" in recorder
runner = (root / "scripts/a7-run-windows.ps1").read_text(encoding="utf-8")
assert "[switch] $EvidenceOnlyPresentMon" in runner
assert "A7_EDIT_PRESENTMON_REQUIRES_EXPLICIT_CAPTURE_AND_EDIT_SCENARIO" in runner
assert "ScreenshotIntervalSeconds = 30.0" in runner
assert "[switch] $EditNoStills" in runner
assert '--no-stills' in runner
assert "($Capture -and -not $EvidenceOnlyPresentMon)" in runner

def write_json(path, x):
    path.write_text(json.dumps(x), encoding="utf-8")

def write_png(path):
    path.write_bytes(b"\x89PNG\r\n\x1a\n" + struct.pack(">I",13)
        + b"IHDR" + struct.pack(">II",1920,1080) + b"\x08\x02\x00\x00\x00" + b"\x00"*4)

with tempfile.TemporaryDirectory() as tmp:
    folder = Path(tmp) / "evidence"
    game = folder / "game" / "r1"
    game.mkdir(parents=True)
    manifest = {
        "schema":"a7_visual_evidence_manifest_v1", "mode":"Route",
        "scenario":"shoreline_180s", "seed":20261119,
        "video_path":None, "video_exit_code":None,
        "video_capture_valid_container":False,
        "video_actual_fps_verified":False,
    }
    write_json(folder/"visual_evidence_manifest.json", manifest)
    write_json(game/"a7_route.json", {
        "schema":"a7_route_v1", "route":"shoreline_180s",
        "seed":20261119,"frame_count":1800,
    })
    write_png(game/"a7_shoreline_180s_ms00010000.png")
    (game/"a7_route.jsonl").write_text("\n".join(json.dumps(x) for x in [
        {"type":"sample","phase":"moving","t_s":0,"meshed_radial_probes":8},
        {"type":"sample","phase":"moving","t_s":1,"meshed_radial_probes":7},
        {"type":"screenshot","t_s":10,"name":"a7_shoreline_180s_ms00010000.png",
         "capture_epoch_s":1_700_000_000,"view_130_geometric_probe_hits":8},
    ]) + "\n", encoding="utf-8")
    result = module.analyze(folder)
    assert result["route"]["radial_probe_below_eight_count"] == 1
    assert result["route"]["visual_surface_follow"] is False
    assert result["screenshot_count"] == 1, result
    assert result["screenshots"][0]["dimensions"] == [1920,1080]
    assert result["gates"]["STREAM-18"] == "NOT_QUALIFIED"
    assert result["gates"]["VIEW-130"] == "NOT_QUALIFIED"
    assert not result["automatic_acceptance"]
    assert not result["video_container_available"]

    manifest["mode"], manifest["scenario"] = "Edit", "edit_idle_100"
    write_json(folder/"visual_evidence_manifest.json", manifest)
    (game/"a7_route.json").unlink()
    (game/"a7_route.jsonl").unlink()
    write_json(game/"a7_edits.json", {
        "schema":"a7_edit_v1", "scenario":"edit_idle_100",
        "seed":20261119, "requested_count":2,
    })
    write_png(game/"edit_000_before.png")
    write_png(game/"edit_000_after_01.png")
    (game/"a7_edits.jsonl").write_text("\n".join(json.dumps(x) for x in [
        {"type":"edit","index":0,"accepted":True,"brush_call_epoch_s":1_700_000_000,
         "brush_call_ticks_us":2300000,"first_correct_presented_pixel_ms":None,
         "video_marker_index":0,
         "visual_before_sample":{"file":"edit_000_before.png","capture_epoch_s":1_700_000_000},
         "visual_after_samples":[{"file":"edit_000_after_01.png","capture_epoch_s":1_700_000_000.1}]},
        {"type":"edit","index":1,"accepted":False,"reject_reason":"no_ray_hit"},
    ])+"\n", encoding="utf-8")
    result=module.analyze(folder)
    assert result["edit"]["accepted"] == 1
    assert result["edit"]["review_screenshot_count"] == 2
    assert result["screenshot_count"] == 2
    assert result["edit"]["correct_presented_pixel_unverified"] == [0]
    assert result["edit"]["timestamped_calls"] == 1
    assert result["gates"]["EDIT-100"] == "NOT_QUALIFIED"
    assert not result["automatic_acceptance"]

# Correlate an explicitly lossless ETW trace to the earliest display
# opportunity, never to the first correct terrain pixel.
with tempfile.TemporaryDirectory() as tmp:
    folder = Path(tmp)
    start = 1_700_000_000.0
    status = {
        "collection_started": True, "exit_code": 0,
        "etw_events_lost": 0, "etw_buffers_lost": 0,
        "capture_started_epoch_s": start,
    }
    write_json(folder / "a7_presentmon_status.json", status)
    with (folder / "a7_presentmon.csv").open("w", newline="", encoding="utf-8") as output:
        writer = csv.DictWriter(output, fieldnames=["CPUStartDateTime","DisplayLatency"])
        writer.writeheader()
        for i in range(125):
            stamp = datetime.fromtimestamp(start + i * 0.016)
            writer.writerow({"CPUStartDateTime":stamp.strftime("%Y-%m-%d %H:%M:%S.%f"),
                             "DisplayLatency":"20.0"})
    brush = [{
        "index": 0, "brush_call_epoch_s": start + 0.5,
        "brush_return_epoch_s": start + 1.9,
    }]
    presented = module.parse_edit_presentmon(folder, brush)
    assert presented["available"], presented
    assert presented["clock_verified"], presented
    assert len(presented["earliest_display_opportunity_ms"]) == 1, presented
    assert "correct terrain pixel" in presented["note"], presented
    status["etw_events_lost"] = 15
    write_json(folder/"a7_presentmon_status.json", status)
    assert not module.parse_edit_presentmon(folder, brush)["available"]

# Video decoder/marker alignment is deterministic and does not need GPU,
# video fixtures, third-party Python packages, or a graphical runner.
_video_spec=importlib.util.spec_from_file_location("a7_video",root/"scripts/a7_video_timeline.py")
_video=importlib.util.module_from_spec(_video_spec)
assert _video_spec.loader is not None
_video_spec.loader.exec_module(_video)
def patch(r,g,b):
    return bytes([r,g,b])*64
assert _video.classify_marker(patch(0,240,0))=="green"
assert _video.classify_marker(patch(230,0,222))=="magenta"
assert _video.classify_marker(patch(20,20,20))=="unclassified"
pts = [0.00,0.016,0.033,0.050,0.066,0.083]
raw = patch(20,20,20)+patch(0,240,0)*2+patch(230,0,222)*2+patch(0,240,0)
transitions=_video.marker_transitions(raw,pts)
assert [x["color"] for x in transitions["transitions"]]==["green","magenta","green"]
expected=[{"index":i,"color":c,"event_epoch_s":1700000000+p+0.025}
          for i,c,p in zip((0,1,2),("green","magenta","green"),(0.016,0.050,0.083))]
aligned=_video.correlate_markers(expected,transitions["transitions"])
assert aligned["sequence_verified"] and aligned["alignment_verified"], aligned
assert len(aligned["aligned_events"])==3
assert aligned["video_epoch_offset_s"] > 1700000000
assert not _video.correlate_markers(expected,transitions["transitions"][:-1])["alignment_verified"]
probe={"streams":[{"width":1920,"height":1080,"avg_frame_rate":"60/1"}],
       "frames":[{"best_effort_timestamp_time":f"{i/60:.8f}"} for i in range(120)]}
decoded=_video.decode_probe_json(json.dumps(probe))
assert decoded["frames"]==120
assert abs(decoded["observed_fps"]-60)<0.01
probe["streams"][0]["width"]=1280
try:
    _video.decode_probe_json(json.dumps(probe))
    raise AssertionError("Incorrect video resolution accepted")
except ValueError:
    pass

# A screenshot-free capture arm must not be blamed for GPU readback
# stalls in the canonical A7 reporting/acceptance matrix.
_report_spec = importlib.util.spec_from_file_location("a7_report", root / "scripts/a7_report.py")
_report = importlib.util.module_from_spec(_report_spec)
assert _report_spec.loader is not None
_report_spec.loader.exec_module(_report)
with tempfile.TemporaryDirectory() as tmp:
    folder=Path(tmp)
    write_json(folder/"manifest.json", {
        "schema":"a7_campaign_v1","scenarios":["shoreline_180s"],
        "seeds":[20261119],"repeats":1
    })
    trace_path=folder/"a7_route.json"
    report={
        "schema":"a7_route_v1","route":"shoreline_180s",
        "seed":20261119,"ci_smoke":False,"capture":True,
        "screenshots":0,"frame_start_p99_ms":16.7,
        "frame_start_max_ms":16.7,"min_radial_probe_hits_8":8,
    }
    write_json(trace_path, report)
    analyzed=_report.analyze(folder)
    assert analyzed["route_results"]["shoreline_180s"]["screen_capture_overhead"] is False
    assert analyzed["route_results"]["shoreline_180s"]["evidence_capture_mode"] is True
    assert any("without in-engine PNG readback" in w for w in analyzed["warnings"])
    assert not any("PNG readback introduces" in w for w in analyzed["warnings"])
    report["screenshots"]=31
    write_json(trace_path,report)
    analyzed=_report.analyze(folder)
    assert analyzed["route_results"]["shoreline_180s"]["screen_capture_overhead"] is True
    assert any("PNG readback introduces" in w for w in analyzed["warnings"])

print("A7_VISUAL_EDIT_EVIDENCE_FAIL_CLOSED_CONTRACT_PASS")
