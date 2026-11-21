"""A7 ETW diagnostic parser is fail-closed, aligned to the timed moving phase."""
import csv
import importlib.util
import json
import os
import shutil
import tempfile
from datetime import datetime
from pathlib import Path

root = Path(__file__).resolve().parents[1]
parser_file = root / "scripts/a7_streaming_present_report.py"
spec = importlib.util.spec_from_file_location("a7_present_report", parser_file)
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)

for path in [
    "scripts/a7-streaming-present-windows.ps1",
    "scripts/a7_streaming_present_report.py",
    "scripts/a7_etw_diagnose.py",
    ".github/workflows/a7-streaming-present-interactive.yml",
]:
    assert (root / path).is_file(), path

source = (root / "scripts/a7-run-windows.ps1").read_text(encoding="utf-8")
runtime = (root / "godot/tests/a7_route_runtime.gd").read_text(encoding="utf-8")
campaign = (root / "scripts/a7-streaming-present-windows.ps1").read_text(encoding="utf-8")
workflow = (root / ".github/workflows/a7-streaming-present-interactive.yml").read_text(encoding="utf-8")
assert "PresentMonExe" in source and "a7_presentmon_status.json" in source
assert "--session_name " in source and "--v2_metrics" in source
# A7 must not kill the collector before --timed reaches its own bounded stop.
assert "Ceiling($Warmup + $Duration + 8.0)" in source
assert "$pmProcess.WaitForExit(30000)" in source
assert "Ceiling($Warmup+$Duration+45)" not in source
assert "$pmProcess.WaitForExit(15000)" not in source
assert "a7_presentmon_stderr.txt" in source
assert "[switch] $PresentMonNoGpu" in source and "--no_track_gpu" in source
assert "etw_events_lost" in source
assert "[switch] $EtwStressProbe" in campaign and "[switch] $DisplayOnly" in campaign
assert "A7_ETW_CAPTURE_FAILED_FAST" in campaign and "A7_ETW_EVENTS_LOST" in campaign
assert "duration=90" in campaign
assert "measurement_epoch_begin_s" in runtime and "measurement_epoch_end_s" in runtime
assert "voxel_threads_requested=0" in campaign and "ResourceTelemetry=$true" in campaign
assert "interactive-gpu" in workflow
assert "B2A706BC6AD475749E3B7E3409263AA1E6906D45BDCF993F6DBC0F660188F1AF" in campaign
assert "strict_acceptance" in parser_file.read_text(encoding="utf-8")
assert module.epoch("2026-11-1 9:02:03.123456789") is not None
assert module.epoch("not-a-presentmon-time") is None
# Regression from live local 2026-11-21 capture: PresentMon CSV clocks ran
# exactly three hours behind Godot's Unix measurement epoch.
clock = module.choose_clock_alignment(
    raw_min=1_700_000_000.0-10800-20,
    raw_max=1_700_000_000.0-10800+30,
    start=1_700_000_000.0,
    end=1_700_000_030.0,
    utc_offset_s=-10800.0,
)
assert clock["verified"] and clock["offset_s"] == 10800, clock
assert clock["method"] == "local_utc_offset_correction", clock
assert not module.choose_clock_alignment(
    raw_min=1_700_000_000.0-3600,
    raw_max=1_700_000_000.0-3550,
    start=1_700_000_000.0,
    end=1_700_000_030.0,
    utc_offset_s=-10800.0,
)["verified"]
# Never invent shifts from arbitrary 1-hour offsets.
assert not module.choose_clock_alignment(
    raw_min=1_700_000_000.0-7200-20,
    raw_max=1_700_000_000.0-7200+30,
    start=1_700_000_000.0,
    end=1_700_000_030.0,
    utc_offset_s=-10800.0,
)["verified"]

with tempfile.TemporaryDirectory() as t:
    folder = Path(t)
    start = 1_700_000_000.0
    data = {
        "route": "shoreline_180s", "seed": 20261119,
        "measurement_epoch_begin_s": start,
        "measurement_epoch_end_s": start + 10.0,
        "duration_s":10.0,
        "frame_start_p99_ms": 16.666, "frame_start_max_ms": 33.2,
        "voxel_threads_requested":0, "voxel_threads_actual":14,
        "vsync_mode_actual":0, "min_radial_probe_hits_8":8,
        "frame_intervals_over_33_ms":1,
    }
    (folder/"a7_route.json").write_text(json.dumps(data),encoding="utf-8")
    miss = module.analyze_run(folder)
    assert miss["presentation_status"] == "NOT_MEASURED"
    (folder/"a7_presentmon_status.json").write_text(json.dumps(
        {"collection_started": True, "exit_code":0, "capture_error":None}
    ),encoding="utf-8")
    with (folder/"a7_presentmon.csv").open("w",encoding="utf-8",newline="") as f:
        w=csv.DictWriter(f,fieldnames=[
            "CPUStartDateTime","DisplayLatency","DisplayedTime",
            "FrameTime","CPUBusy","GPUTime","SwapChainAddress"])
        w.writeheader()
        for i in range(125):
            utc = datetime.fromtimestamp(start + 0.1+i*.075)
            w.writerow({"CPUStartDateTime":utc.isoformat(sep=" "),
                        "DisplayLatency":"12.5","DisplayedTime":"16.66",
                        "FrameTime":"75.0","CPUBusy":"1.1","GPUTime":"4.0",
                        "SwapChainAddress":"0x1234"})
    out=module.analyze_run(folder)
    assert out["presentation_status"] == "ETW_ALIGNED",out
    assert out["presentmon_rows_in_window"] == 125
    assert out["display_latency_p99_ms"] == 12.5
    assert out["gpu_work_p99_ms"] == 4.0
    assert out["cpu_frame_time_p99_ms"] == 75.0
    assert abs(out["display_change_p99_ms"]-75.0)<0.01
    assert out["etw_csv_schema"] == "v2_metrics"
    assert out["timestamp_alignment_method"] == "native_local"
    # Archived CSV must remain analyzable after runner cleanup.
    import zipfile
    with zipfile.ZipFile(folder/"a7_presentmon.csv.zip", "w") as z:
        z.write(folder/"a7_presentmon.csv", arcname="a7_presentmon.csv")
    (folder/"a7_presentmon.csv").unlink()
    archived_out=module.analyze_run(folder)
    assert archived_out["presentation_status"] == "ETW_ALIGNED",archived_out
    assert archived_out["presentmon_rows_in_window"] == 125
    # A clean exit and CSV are insufficient when PresentMon reports ETW loss.
    (folder/"a7_presentmon_status.json").write_text(json.dumps({
        "collection_started": True, "exit_code": 0, "capture_error": None,
        "gpu_tracking_requested": False, "etw_events_lost": 860404,
    }), encoding="utf-8")
    lossy=module.analyze_run(folder)
    assert lossy["presentation_status"] == "ETW_INCOMPLETE", lossy
    assert lossy["etw_events_lost"] == 860404
    assert "lost ETW events" in lossy["reason"]
    (folder/"a7_presentmon_status.json").write_text(json.dumps({
        "collection_started": True, "exit_code": 0, "capture_error": None,
        "gpu_tracking_requested": False, "etw_events_lost": 0,
    }), encoding="utf-8")
    clean=module.analyze_run(folder)
    assert clean["presentation_status"] == "ETW_ALIGNED"
    assert clean["gpu_tracking_requested"] is False
    assert out["strict_acceptance"] == "NOT_QUALIFIED"
    # Keep plain CSV for existing nested-layout diagnostic regression.
    with zipfile.ZipFile(folder/"a7_presentmon.csv.zip") as z:
        z.extract("a7_presentmon.csv", folder)
    (folder/"a7_presentmon.csv.zip").unlink()
    data["measurement_epoch_begin_s"] = start + 3600
    data["measurement_epoch_end_s"] = start + 3610
    (folder/"a7_route.json").write_text(json.dumps(data),encoding="utf-8")
    incomplete=module.analyze_run(folder)
    assert incomplete["presentation_status"] == "ETW_INCOMPLETE",incomplete
    # Actual A7 runner nests reports under <arm>/<route>_seed*_rep01/.
    nested=folder/"shoreline_180s_seed20261119_rep01"
    nested.mkdir()
    for filename in ("a7_route.json","a7_presentmon_status.json","a7_presentmon.csv"):
        shutil.move(str(folder/filename),str(nested/filename))
    nested_out=module.analyze_run(folder)
    assert nested_out["presentation_status"] == "ETW_INCOMPLETE",nested_out
    import subprocess
    probe=subprocess.run(
        [os.sys.executable, str(root/"scripts/a7_etw_diagnose.py"), str(folder)],
        text=True, capture_output=True, check=True
    )
    diagnostic=json.loads(probe.stdout)
    assert diagnostic["csv_rows"] == 125, diagnostic
    assert diagnostic["rows_in_measurement_window"] == 0, diagnostic
    assert diagnostic["rows_with_parseable_timestamp"] == 125, diagnostic
    assert diagnostic["presentmon_exit_code"] == 0, diagnostic
print("A7_STREAMING_ETW_FAIL_CLOSED_CONTRACT_PASS")
