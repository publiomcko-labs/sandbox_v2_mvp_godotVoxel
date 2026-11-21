"""A7 experimental ETW presentation analysis; NEVER auto-qualifies strict gates."""
from __future__ import annotations
import csv
import contextlib
import datetime as dt
import io
import json
import math
import re
import sys
import time
import zipfile
from pathlib import Path

# PresentMon 2.6.0 --v2_metrics --date_time columns; do not mix v1 names.
NUMERIC_COLUMNS = ["DisplayLatency", "DisplayedTime", "FrameTime", "CPUBusy", "GPUTime"]
def percentile(values, q):
    if not values:
        return None
    sorted_values = sorted(values)
    return round(sorted_values[min(len(sorted_values)-1, math.ceil((len(sorted_values)-1)*q))], 5)

def number(value):
    try:
        n = float(str(value).strip())
        if math.isfinite(n):
            return n
    except (ValueError, TypeError):
        pass
    return None

def epoch(value):
    if not value or str(value).strip().upper() in ("NA", "N/A"):
        return None
    v = str(value).strip().replace("Z", "+00:00")
    try:
        d = dt.datetime.fromisoformat(v)
        if d.tzinfo is not None:
            return d.timestamp()
        # PresentMon date_time uses the local Windows host time.
        return time.mktime(d.timetuple()) + d.microsecond/1e6
    except (ValueError, OverflowError):
        # PresentMon's native DateTime formatter does not zero-pad month/day/hour
        # and emits nine fractional digits. Python fromisoformat rejects that.
        match = re.fullmatch(r"(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{1,2}):(\d{1,2})(?:\.(\d{1,9}))?", v)
        if match is None:
            return None
        year, month, day, hour, minute, second, fraction = match.groups()
        try:
            micros = int(((fraction or "") + "000000")[:6])
            local = dt.datetime(int(year), int(month), int(day), int(hour),
                                int(minute), int(second), micros)
            return time.mktime(local.timetuple()) + local.microsecond / 1e6
        except (ValueError, OverflowError):
            return None


@contextlib.contextmanager
def open_presentmon_csv(folder: Path):
    """Read raw CSV, or the lossless .csv.zip left by campaign cleanup."""
    csv_file = folder / "a7_presentmon.csv"
    zipped = folder / "a7_presentmon.csv.zip"
    if csv_file.is_file():
        with csv_file.open("r", encoding="utf-8-sig", errors="replace", newline="") as f:
            yield f
    elif zipped.is_file():
        with zipfile.ZipFile(zipped) as archive:
            names = [name for name in archive.namelist() if name.endswith("a7_presentmon.csv")]
            if len(names) != 1:
                raise ValueError(f"Expected exactly one PresentMon CSV in {zipped}")
            with archive.open(names[0]) as binary:
                with io.TextIOWrapper(binary, encoding="utf-8-sig", errors="replace", newline="") as f:
                    yield f
    else:
        raise FileNotFoundError(f"Missing PresentMon CSV at {csv_file} or {zipped}")


def choose_clock_alignment(raw_min: float, raw_max: float, start: float, end: float,
                           utc_offset_s: float | None = None) -> dict:
    """Align PresentMon's timezone-naive date with Godot's Unix epoch.

    Only consider no shift or the host's known UTC offset in either direction.
    Require >=85% interval overlap, and reject ambiguous interpretations;
    never infer arbitrary shifts or silently declare ETW aligned.
    """
    if utc_offset_s is None:
        offset = dt.datetime.fromtimestamp(start).astimezone().utcoffset()
        utc_offset_s = offset.total_seconds() if offset is not None else 0.0
    duration = end - start
    candidates = [(0.0, "native_local")]
    if utc_offset_s:
        candidates += [
            (-utc_offset_s, "local_utc_offset_correction"),
            (utc_offset_s, "reverse_local_utc_offset"),
        ]
    seen = set()
    scored = []
    for shift, method in candidates:
        if shift in seen:
            continue
        seen.add(shift)
        overlap = max(0.0, min(end, raw_max + shift) - max(start, raw_min + shift))
        scored.append({"offset_s": shift, "method": method, "overlap_s": round(overlap, 4)})
    ranked = sorted(scored, key=lambda item: item["overlap_s"], reverse=True)
    best = ranked[0]
    ambiguous = len(ranked) > 1 and ranked[1]["overlap_s"] >= duration * .85
    verified = best["overlap_s"] >= duration * .85 and not ambiguous
    return {
        "verified": verified,
        "offset_s": best["offset_s"] if verified else None,
        "method": best["method"] if verified else "unresolved",
        "host_utc_offset_s": utc_offset_s,
        "candidates": scored,
    }

def analyze_run(folder: Path) -> dict:
    summary_path = folder / "a7_route.json"
    if not summary_path.exists():
        candidates = list(folder.glob("*/a7_route.json"))
        if len(candidates) != 1:
            raise ValueError(f"Expected exactly one A7 route report in {folder}, found {len(candidates)}")
        summary_path = candidates[0]
        folder = summary_path.parent
    data = json.loads(summary_path.read_text(encoding="utf-8-sig"))
    start = number(data.get("measurement_epoch_begin_s"))
    end = number(data.get("measurement_epoch_end_s"))
    result = {
        "schema": "a7_present_etw_run_v1",
        "route": data["route"], "seed": data["seed"],
        "measurement_duration_s": data["duration_s"],
        "measurement_epoch_begin_s": start,
        "measurement_epoch_end_s": end,
        "frame_start_p99_ms": data["frame_start_p99_ms"],
        "frame_start_max_ms": data["frame_start_max_ms"],
        "voxel_threads_requested": data["voxel_threads_requested"],
        "voxel_threads_actual": data["voxel_threads_actual"],
        "vsync_mode_actual": data["vsync_mode_actual"],
        "min_radial_probe_hits_8": data["min_radial_probe_hits_8"],
        "frame_intervals_over_33_ms": data["frame_intervals_over_33_ms"],
        "presentation_status": "NOT_MEASURED",
        "presentmon_rows_total": 0,
        "presentmon_rows_in_window": 0,
        "presentmon_displayed_rows": 0,
        "presentmon_dropped_rows": 0,
        "window_coverage_s": 0.0,
        "display_latency_p99_ms": None,
        "display_change_p99_ms": None,
        "present_interval_p99_ms": None,
        "gpu_work_p99_ms": None,
        "cpu_frame_time_p99_ms": None,
        "displayed_time_p99_ms": None,
        "etw_csv_schema": "v2_metrics",
        "gpu_tracking_requested": None,
        "etw_events_lost": None,
        "etw_buffers_lost": None,
        "etw_scope": "full_route",
        "etw_capture_window_begin_s": None,
        "etw_capture_window_end_s": None,
        "etw_capture_target_duration_s": None,
        "timestamp_adjustment_seconds": None,
        "timestamp_alignment_method": "unresolved",
        "timestamp_alignment_candidates": [],
        "timestamp_rows_parseable": 0,
        "reason": None,
        "strict_acceptance": "NOT_QUALIFIED",
    }
    status_file = folder / "a7_presentmon_status.json"
    csv_file = folder / "a7_presentmon.csv"
    zipped_file = folder / "a7_presentmon.csv.zip"
    if not status_file.exists() or not (csv_file.exists() or zipped_file.exists()):
        result["reason"] = "PresentMon status or CSV missing"
        return result
    status = json.loads(status_file.read_text(encoding="utf-8-sig"))
    result["gpu_tracking_requested"] = status.get("gpu_tracking_requested")
    result["etw_events_lost"] = status.get("etw_events_lost")
    result["etw_buffers_lost"] = status.get("etw_buffers_lost")
    if not status.get("collection_started") or status.get("exit_code") != 0:
        result["reason"] = f"PresentMon collector error: {status.get('capture_error')}, exit={status.get('exit_code')}"
        return result
    if number(status.get("etw_events_lost")) is not None and number(status["etw_events_lost"]) > 0:
        result["presentation_status"] = "ETW_INCOMPLETE"
        result["reason"] = f"PresentMon reported lost ETW events: {status['etw_events_lost']}"
        return result
    if number(status.get("etw_buffers_lost")) is not None and number(status["etw_buffers_lost"]) > 0:
        result["presentation_status"] = "ETW_INCOMPLETE"
        result["reason"] = f"PresentMon reported lost ETW buffers: {status['etw_buffers_lost']}"
        return result
    if start is None or end is None or start >= end:
        result["reason"] = "Missing reliable Godot measurement time-window"
        return result
    capture_s = number(status.get("capture_requested_duration_s"))
    capture_delay_s = number(status.get("capture_start_delay_s"))
    sample_is_partial = capture_s is not None and capture_s > 0
    target_start, target_end = start, end
    if sample_is_partial:
        if capture_delay_s is None or capture_delay_s <= 0:
            result["reason"] = "ETW slice lacks validated deferred-start configuration"
            return result
        sample_start = number(status.get("capture_started_epoch_s"))
        sample_end = number(status.get("capture_window_end_epoch_s"))
        if (sample_start is None or sample_end is None or sample_end <= sample_start
                or sample_start < start or sample_end > end + 2.0
                or sample_end - sample_start < capture_s * .9):
            result["reason"] = "ETW sample missing, outside measured motion, or too short"
            return result
        target_start = max(start, sample_start)
        target_end = min(end, sample_end)
        result["etw_scope"] = "sampled_subwindow_only"
    result["etw_capture_window_begin_s"] = target_start
    result["etw_capture_window_end_s"] = target_end
    result["etw_capture_target_duration_s"] = round(target_end - target_start, 3)
    # First pass: determine the possible clock interpretation from capture bounds.
    raw_min = raw_max = None
    with open_presentmon_csv(folder) as f:
        reader = csv.DictReader(f)
        headers = set(reader.fieldnames or [])
        required = {"CPUStartDateTime", "DisplayLatency", "DisplayedTime", "FrameTime", "GPUTime"}
        if not required.issubset(headers):
            result["reason"] = "PresentMon --v2_metrics CSV headers missing: " + ", ".join(sorted(required - headers))
            return result
        for row in reader:
            result["presentmon_rows_total"] += 1
            stamp = epoch(row.get("CPUStartDateTime"))
            if stamp is None:
                continue
            result["timestamp_rows_parseable"] += 1
            raw_min = stamp if raw_min is None else min(raw_min, stamp)
            raw_max = stamp if raw_max is None else max(raw_max, stamp)
    if raw_min is None or raw_max is None:
        result["reason"] = "PresentMon date-time values could not be parsed"
        return result
    clock = choose_clock_alignment(raw_min, raw_max, target_start, target_end)
    result["timestamp_alignment_candidates"] = clock["candidates"]
    result["timestamp_alignment_method"] = clock["method"]
    result["timestamp_adjustment_seconds"] = clock["offset_s"]
    if not clock["verified"]:
        result["presentation_status"] = "ETW_INCOMPLETE"
        result["reason"] = "ETW time not aligned: none or ambiguous among local/UTC offset interpretations"
        return result
    offset_s = clock["offset_s"]
    samples = {k: [] for k in NUMERIC_COLUMNS}
    first = last = None
    previous_display_epoch_by_swapchain = {}
    displayed_gaps_ms = []
    with open_presentmon_csv(folder) as f:
        reader = csv.DictReader(f)
        for row in reader:
            stamp = epoch(row.get("CPUStartDateTime"))
            if stamp is None:
                continue
            stamp += offset_s
            if stamp < target_start or stamp > target_end:
                continue
            result["presentmon_rows_in_window"] += 1
            if first is None: first = stamp
            last = stamp
            latency = number(row.get("DisplayLatency"))
            if latency is None or latency < 0:
                result["presentmon_dropped_rows"] += 1
                continue
            result["presentmon_displayed_rows"] += 1
            swapchain = row.get("SwapChainAddress", "main")
            displayed_epoch = stamp + latency / 1000.0
            prior = previous_display_epoch_by_swapchain.get(swapchain)
            if prior is not None and displayed_epoch > prior:
                displayed_gaps_ms.append(1000.0 * (displayed_epoch - prior))
            previous_display_epoch_by_swapchain[swapchain] = displayed_epoch
            for key in NUMERIC_COLUMNS:
                v = number(row.get(key))
                if v is not None and v >= 0:
                    samples[key].append(v)
    # Parseability was established in the full first pass.
    result["window_coverage_s"] = round((last-first) if first is not None and last is not None else 0, 3)
    result["display_latency_p99_ms"] = percentile(samples["DisplayLatency"], .99)
    # Derive actual display-change cadence from CPU start + measured display latency,
    # per swap chain; do not conflate CPU frame intervals with screen updates.
    result["display_change_p99_ms"] = percentile(displayed_gaps_ms, .99)
    result["present_interval_p99_ms"] = percentile(displayed_gaps_ms, .99)
    result["gpu_work_p99_ms"] = (percentile(samples["GPUTime"], .99)
                                 if status.get("gpu_tracking_requested") is not False else None)
    result["cpu_frame_time_p99_ms"] = percentile(samples["FrameTime"], .99)
    result["displayed_time_p99_ms"] = percentile(samples["DisplayedTime"], .99)
    if (result["presentmon_displayed_rows"] < 100 or len(displayed_gaps_ms) < 30
            or result["window_coverage_s"] < .85 * (target_end-target_start)):
        result["presentation_status"] = "ETW_INCOMPLETE"
        result["reason"] = "Insufficient displayed frames or under 85% timestamp coverage"
        return result
    result["presentation_status"] = "ETW_PARTIAL_ALIGNED" if sample_is_partial else "ETW_ALIGNED"
    result["reason"] = (
        "Bounded ETW subwindow aligned; NOT full-route or strict A7 qualification"
        if sample_is_partial else
        "Per-process ETW presentation metrics aligned to Godot Unix epoch; clock adjustment recorded"
    )
    return result

def summarize(campaign: Path):
    manifest = json.loads((campaign / "streaming_manifest.json").read_text(encoding="utf-8-sig"))
    results = []
    for run in manifest["runs"]:
        folder = campaign / run["directory"]
        result = analyze_run(folder)
        result.update({"profile":run["profile"], "sequence":run["sequence"],
                       "directory":run["directory"]})
        (folder / "a7_present_analysis.json").write_text(json.dumps(result,indent=2),encoding="utf-8")
        results.append(result)
        print("A7_STREAM_PRESENT_RESULT", result["route"], result["profile"],
              "ETW="+result["presentation_status"],
              "display_p99="+str(result["display_latency_p99_ms"]),
              "probes="+str(result["min_radial_probe_hits_8"]), flush=True)
    payload = {
        "schema":"a7_streaming_present_campaign_v1",
        "git_sha":manifest["git_sha"],
        "baseline":manifest["baseline"],
        "presentmon_version":manifest["presentmon_version"],
        "route_count":len(results),
        "etw_aligned_count":sum(1 for r in results if r["presentation_status"]=="ETW_ALIGNED"),
        "etw_partial_aligned_count":sum(1 for r in results if r["presentation_status"]=="ETW_PARTIAL_ALIGNED"),
        "strict_acceptance":"NOT_QUALIFIED",
        "warnings":[
            "PresentMon ETW measures software-to-display timing, not camera pixel coverage, HID-to-photon, or actual panel photons.",
            "Results have the same external ETW and process telemetry for both VSync arms.",
            "This is a single-seed diagnostic; do not promote performance settings automatically.",
            "ETW_PARTIAL_ALIGNED is a sample, not 85% coverage of the full route; it never qualifies A7.",
        ],
        "runs":results,
    }
    (campaign / "streaming_comparison.json").write_text(json.dumps(payload,indent=2),encoding="utf-8")
    with (campaign / "streaming_comparison.csv").open("w",encoding="utf-8",newline="") as f:
        writer=csv.DictWriter(f,fieldnames=list(results[0].keys()))
        writer.writeheader()
        writer.writerows(results)
    return payload

def main():
    if len(sys.argv)!=2: raise SystemExit("usage: python a7_streaming_present_report.py CAMPAIGN_DIR")
    p=Path(sys.argv[1])
    payload=summarize(p)
    print("A7_STREAMING_PRESENT_SUMMARY runs="+str(payload["route_count"]) +
          " etw_aligned="+str(payload["etw_aligned_count"])+
          " strict_acceptance=NOT_QUALIFIED")

if __name__=="__main__":
    main()
