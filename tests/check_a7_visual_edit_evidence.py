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
assert "_next_screenshot_s+=1.0" in route
assert "pixel_depth_verified" in route and "view_130_geometric_probe_hits" in route
assert "brush_call_epoch_s" in edit and "brush_call_ticks_us" in edit
assert "brush_return_epoch_s" in edit and "brush_return_ticks_us" in edit
assert "target_screen_xy_px" in edit and "target_behind_camera" in edit
assert "first_correct_presented_pixel_ms" in edit
assert "video_marker_meaning" in edit and "NOT correct terrain presentation" in edit
assert "A7_EVIDENCE_REQUIRES_INTERACTIVE_DESKTOP" in recorder
assert "gdigrab" in recorder and "-framerate 60" in recorder
assert "video_actual_fps_verified = $false" in recorder
assert "terrain_pixels_correct_verified = $false" in recorder
assert "strict_gates = 'NOT_QUALIFIED'" in recorder
assert "Capture = $true" in recorder
assert "PresentMonExe" in recorder and "EvidenceOnlyPresentMon" in recorder
assert "-Mode Preflight" in recorder and "-Mode Postflight" in recorder
runner = (root / "scripts/a7-run-windows.ps1").read_text(encoding="utf-8")
assert "[switch] $EvidenceOnlyPresentMon" in runner
assert "A7_EDIT_PRESENTMON_REQUIRES_EXPLICIT_CAPTURE_AND_EDIT_SCENARIO" in runner
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
    (game/"a7_edits.jsonl").write_text("\n".join(json.dumps(x) for x in [
        {"type":"edit","index":0,"accepted":True,"brush_call_epoch_s":1_700_000_000,
         "brush_call_ticks_us":2300000,"first_correct_presented_pixel_ms":None,
         "video_marker_index":0},
        {"type":"edit","index":1,"accepted":False,"reject_reason":"no_ray_hit"},
    ])+"\n", encoding="utf-8")
    result=module.analyze(folder)
    assert result["edit"]["accepted"] == 1
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

print("A7_VISUAL_EDIT_EVIDENCE_FAIL_CLOSED_CONTRACT_PASS")
