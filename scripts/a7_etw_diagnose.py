"""Inspect an existing PresentMon capture without rerunning Godot or changing A7 gates."""
from __future__ import annotations

import collections
import csv
import datetime as dt
import importlib.util
import json
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("a7_present_parser", ROOT / "scripts/a7_streaming_present_report.py")
parser = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(parser)

def fmt_epoch(value: float | None):
    return dt.datetime.fromtimestamp(value).isoformat(sep=" ") if value is not None else None

def diagnostic(folder: Path):
    routes = list(folder.glob("a7_route.json")) or list(folder.glob("*/a7_route.json"))
    if len(routes) != 1:
        raise SystemExit(f"Expected one route report in {folder}: got {len(routes)}")
    folder = routes[0].parent
    data = json.loads(routes[0].read_text(encoding="utf-8-sig"))
    a = float(data["measurement_epoch_begin_s"])
    b = float(data["measurement_epoch_end_s"])
    raw = folder / "a7_presentmon.csv"
    zipped = folder / "a7_presentmon.csv.zip"
    status_path = folder / "a7_presentmon_status.json"
    status = json.loads(status_path.read_text(encoding="utf-8-sig")) if status_path.exists() else {}
    if zipped.is_file():
        archive = zipfile.ZipFile(zipped)
        names = [n for n in archive.namelist() if n.endswith("a7_presentmon.csv")]
        if len(names) != 1:
            raise SystemExit(f"Missing or ambiguous CSV in {zipped}: {archive.namelist()}")
        import io
        stream = io.TextIOWrapper(archive.open(names[0]), encoding="utf-8-sig", errors="replace", newline="")
    elif raw.is_file():
        stream = raw.open("r", encoding="utf-8-sig", errors="replace", newline="")
    else:
        raise SystemExit(f"No raw or compressed ETW CSV at {folder}")
    count=valid_times=window_rows=valid_window_display=0
    earliest=latest=window_earliest=window_latest=None
    display_values=collections.Counter()
    present_modes=collections.Counter()
    malformed_timestamps=[]
    sample_window_rows=[]
    sample_start=[]
    sample_end=collections.deque(maxlen=3)
    with stream as f:
        reader=csv.DictReader(f)
        headers=reader.fieldnames or []
        for row in reader:
            count += 1
            if len(sample_start)<3: sample_start.append(row)
            sample_end.append(row)
            ts=parser.epoch(row.get("CPUStartDateTime"))
            if ts is None:
                if len(malformed_timestamps)<3: malformed_timestamps.append(row.get("CPUStartDateTime"))
                continue
            valid_times+=1
            earliest=ts if earliest is None else min(ts,earliest)
            latest=ts if latest is None else max(ts,latest)
            if a <= ts <= b:
                window_rows+=1
                window_earliest=ts if window_earliest is None else min(ts,window_earliest)
                window_latest=ts if window_latest is None else max(ts,window_latest)
                latency=parser.number(row.get("DisplayLatency"))
                if latency is not None and latency >= 0:
                    valid_window_display+=1
                display_values[str(row.get("DisplayLatency"))] += 1
                present_modes[str(row.get("PresentMode"))] += 1
                if len(sample_window_rows)<3:
                    sample_window_rows.append(row)
    summary={
        "schema":"a7_etw_diagnostic_v1",
        "route":data["route"], "seed":data["seed"],
        "presentmon_exit_code":status.get("exit_code"),
        "presentmon_capture_error":status.get("capture_error"),
        "godot_window_local":[fmt_epoch(a),fmt_epoch(b)],
        "csv_window_local":[fmt_epoch(earliest),fmt_epoch(latest)],
        "actual_matched_window_local":[fmt_epoch(window_earliest),fmt_epoch(window_latest)],
        "window_duration_s":round(b-a,3),
        "matched_window_duration_s":round((window_latest-window_earliest) if window_earliest is not None else 0,3),
        "csv_header":headers,
        "csv_rows":count,
        "rows_with_parseable_timestamp":valid_times,
        "rows_in_measurement_window":window_rows,
        "rows_with_valid_display_latency_in_window":valid_window_display,
        "display_latency_values_in_window":dict(display_values.most_common(8)),
        "present_modes_in_window":dict(present_modes.most_common(8)),
        "unparseable_timestamp_examples":malformed_timestamps,
        "csv_start_examples":[{k:r.get(k) for k in ("CPUStartDateTime","DisplayLatency","DisplayedTime","PresentMode","Dropped")} for r in sample_start],
        "csv_end_examples":[{k:r.get(k) for k in ("CPUStartDateTime","DisplayLatency","DisplayedTime","PresentMode","Dropped")} for r in sample_end],
        "in_window_examples":[{k:r.get(k) for k in ("CPUStartDateTime","DisplayLatency","DisplayedTime","PresentMode","Dropped")} for r in sample_window_rows],
    }
    return summary

if __name__=="__main__":
    if len(sys.argv) != 2: raise SystemExit("usage: python scripts/a7_etw_diagnose.py PATH_TO_CAMPAIGN_OR_ARM")
    p=Path(sys.argv[1])
    if p.is_dir() and (p / "streaming_manifest.json").is_file():
        manifest=json.loads((p / "streaming_manifest.json").read_text(encoding="utf-8-sig"))
        results=[diagnostic(p / item["directory"]) for item in manifest["runs"]]
        print(json.dumps(results,ensure_ascii=False,indent=2))
    else:
        print(json.dumps(diagnostic(p),ensure_ascii=False,indent=2))
