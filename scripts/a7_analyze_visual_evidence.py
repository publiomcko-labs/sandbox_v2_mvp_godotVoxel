#!/usr/bin/env python3
"""Inspect A7.1/A7.2 visual evidence without inferring unobserved pixels."""
from __future__ import annotations
import argparse
import bisect
import csv
import importlib.util
import json
import struct
import zipfile
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "a7_present_report", Path(__file__).with_name("a7_streaming_present_report.py"))
_pm = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
_spec.loader.exec_module(_pm)

PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def png_dimensions(path: Path):
    try:
        with path.open("rb") as f:
            chunk = f.read(24)
        if len(chunk) != 24 or chunk[:8] != PNG_SIGNATURE or chunk[12:16] != b"IHDR":
            return None
        w, h = struct.unpack(">II", chunk[16:24])
        return [w, h] if 0 < w <= 32768 and 0 < h <= 32768 else None
    except OSError:
        return None


def parse_edit_presentmon(folder: Path, accepted: list[dict]) -> dict:
    """Find earliest measured display *opportunity* after each accepted brush.
    This is NOT first visibly correct terrain pixel and cannot grant EDIT-100.
    """
    result = {
        "available": False, "clock_verified": False,
        "csv_rows": 0, "displayed_frame_rows": 0,
        "etw_events_lost": None, "offset_seconds": None,
        "earliest_display_opportunity_ms": {},
        "note": "Earliest display after the scripted call is a lower bound only. It does not demonstrate a correct terrain pixel or raw HID latency.",
    }
    status_file = folder / "a7_presentmon_status.json"
    if not status_file.is_file():
        return result
    status = read_json(status_file)
    result["etw_events_lost"] = status.get("etw_events_lost")
    if (not status.get("collection_started") or status.get("exit_code") != 0
            or (status.get("etw_events_lost") or 0) > 0
            or (status.get("etw_buffers_lost") or 0) > 0):
        return result
    raw_file = folder / "a7_presentmon.csv"
    zipped = folder / "a7_presentmon.csv.zip"
    if not raw_file.is_file() and not zipped.is_file():
        return result
    if raw_file.is_file():
        data_source = raw_file
    else:
        data_source = zipped
    raw_min, raw_max = None, None
    presented_rows = []
    def rows():
        if data_source.suffix == ".zip":
            with zipfile.ZipFile(data_source) as zf:
                names = [x for x in zf.namelist() if Path(x).name == "a7_presentmon.csv"]
                if len(names) != 1:
                    return
                with zf.open(names[0]) as raw:
                    import io
                    yield from csv.DictReader(io.TextIOWrapper(raw, encoding="utf-8-sig"))
        else:
            with data_source.open(encoding="utf-8-sig", newline="") as inp:
                yield from csv.DictReader(inp)
    for row in rows():
        result["csv_rows"] += 1
        stamp = _pm.epoch(row.get("CPUStartDateTime"))
        latency = _pm.number(row.get("DisplayLatency"))
        if stamp is None:
            continue
        raw_min = stamp if raw_min is None else min(stamp, raw_min)
        raw_max = stamp if raw_max is None else max(stamp, raw_max)
        if latency is None or latency < 0:
            continue
        presented_rows.append(stamp + latency / 1000.0)
    result["displayed_frame_rows"] = len(presented_rows)
    capture_start = _pm.number(status.get("capture_started_epoch_s"))
    brush_end = max((row.get("brush_return_epoch_s", 0) for row in accepted), default=0)
    if (raw_min is None or raw_max is None or capture_start is None
            or brush_end <= capture_start or len(presented_rows) < 100):
        return result
    # Confirm the system's known UTC offset, not an arbitrary post-hoc shift.
    clock = _pm.choose_clock_alignment(raw_min, raw_max, capture_start, brush_end)
    if not clock["verified"]:
        return result
    result["clock_verified"] = True
    result["offset_seconds"] = clock["offset_s"]
    times = sorted(v + clock["offset_s"] for v in presented_rows)
    for row in accepted:
        start = row.get("brush_call_epoch_s")
        if not isinstance(start, (float, int)):
            continue
        idx = bisect.bisect_left(times, start)
        if idx < len(times):
            result["earliest_display_opportunity_ms"][str(row["index"])] = round(
                max(0.0, (times[idx] - start) * 1000.0), 3)
    result["available"] = True
    return result


def analyze(folder: Path) -> dict:
    manifest_path = folder / "visual_evidence_manifest.json"
    manifest = read_json(manifest_path)
    if manifest.get("schema") != "a7_visual_evidence_manifest_v1":
        raise ValueError("Unexpected visual evidence manifest schema")
    if not (folder / "game").is_dir():
        raise ValueError("Missing A7 game evidence directory")
    mode, scenario, seed = (manifest.get(k) for k in ("mode", "scenario", "seed"))
    if mode not in ("Route", "Edit"):
        raise ValueError("Unknown A7 evidence mode")
    expected_name = "a7_route.json" if mode == "Route" else "a7_edits.json"
    expected_events = "a7_route.jsonl" if mode == "Route" else "a7_edits.jsonl"
    runs = sorted((folder / "game").rglob(expected_name))
    traces = sorted((folder / "game").rglob(expected_events))
    if len(runs) != 1 or len(traces) != 1 or runs[0].parent != traces[0].parent:
        raise ValueError("Expected exactly one complete, matched game route/edit trace")
    summary = read_json(runs[0])
    if summary.get("seed") != seed:
        raise ValueError("Seed mismatch between video and game trace")
    if mode == "Route" and summary.get("route") != scenario:
        raise ValueError("Route mismatch")
    if mode == "Edit" and summary.get("scenario") != scenario:
        raise ValueError("Edit mismatch")
    trace = []
    for line in traces[0].read_text(encoding="utf-8-sig").splitlines():
        if line.strip():
            trace.append(json.loads(line))
    screenshots = []
    problems = []
    for event in trace:
        if event.get("type") == "screenshot":
            name = event.get("name")
            if not isinstance(name, str) or Path(name).name != name or not name.endswith(".png"):
                problems.append("Screenshot has invalid relative filename")
                continue
            dimensions = png_dimensions(runs[0].parent / name)
            if dimensions != [1920, 1080]:
                problems.append("Invalid/missing 1080p screenshot: " + name)
            screenshots.append({
                "name": name,
                "t_s": event.get("t_s"),
                "utc_s": event.get("capture_epoch_s"),
                "dimensions": dimensions,
                "geometric_probe_hits": event.get("view_130_geometric_probe_hits"),
                "pixel_depth_verified": False,
            })
    video = manifest.get("video_path")
    video_size = None
    if video:
        path = Path(video)
        if path.is_file():
            video_size = path.stat().st_size
        else:
            # The manifest records the absolute acquisition path on Windows;
            # an archived evidence directory can be moved without preserving it.
            local_path = folder / Path(video.replace("\\", "/")).name
            if local_path.is_file():
                video_size = local_path.stat().st_size
    video_valid = (
        video_size is not None
        and video_size > 1_000_000
        and manifest.get("video_exit_code") == 0
        and manifest.get("video_capture_valid_container") is True
    )
    if not video_valid:
        problems.append("Continuous 60fps 1080p desktop recording not available/verified")
    video_timeline = None
    timeline_path = folder / "a7_video_timeline.json"
    if timeline_path.is_file():
        video_timeline = read_json(timeline_path)
        if (video_timeline.get("schema") != "a7_video_timeline_v1"
                or not isinstance(video_timeline.get("frame_integrity"),dict)
                or video_timeline.get("video_name") != (
                    Path(video.replace("\\","/")).name if isinstance(video,str) else None)):
            problems.append("Video timeline provenance mismatch or invalid schema")
            video_timeline = None
    if video_valid and video_timeline is None:
        problems.append("CPU-side frame timestamp and marker analysis not yet produced")
    elif video_timeline is not None:
        if not video_timeline.get("video_fps_60_diagnostic"):
            problems.append("Recorded video cadence below 59 observed frames/s")
        if not video_timeline.get("marker",{}).get("alignment_verified"):
            problems.append("No reliable marker sequence and video/Godot clock alignment")
    if mode == "Route":
        moving_samples = [x for x in trace if x.get("type") == "sample" and x.get("phase") == "moving"]
        radial_low = [x.get("t_s") for x in moving_samples
                      if isinstance(x.get("meshed_radial_probes"), int)
                      and x.get("meshed_radial_probes") < 8]
        gaps = [x for x in trace if x.get("type") == "screenshot_failed"]
        if radial_low:
            problems.append("Under-eight geometry probes on moving path")
        if gaps:
            problems.append("Screenshot readback failures")
        route_result = {
            "moving_samples": len(moving_samples),
            "radial_probe_below_eight_count": len(radial_low),
            "radial_probe_below_eight_t_s": radial_low,
            "screenshot_failures": len(gaps),
            "frame_count": summary.get("frame_count"),
            "note": "8/8 mesh probes is NOT equivalent to presented 130m pixel/depth coverage.",
        }
        edit_result = None
    else:
        edits = [x for x in trace if x.get("type") == "edit"]
        accepted = [x for x in edits if x.get("accepted") is True]
        for edited in accepted:
            evidence_refs = []
            before = edited.get("visual_before_sample")
            if isinstance(before, dict):
                evidence_refs.append(("before", before))
            for after in edited.get("visual_after_samples", []):
                evidence_refs.append(("after", after))
            for phase, shot in evidence_refs:
                name = shot.get("file")
                if not isinstance(name, str) or Path(name).name != name or not name.endswith(".png"):
                    problems.append("Edit screenshot has invalid filename")
                    continue
                dims = png_dimensions(runs[0].parent / name)
                if dims != [1920, 1080]:
                    problems.append("Invalid/missing 1080p edit screenshot: " + name)
                screenshots.append({
                    "name": name, "phase": phase, "edit_index": edited.get("index"),
                    "utc_s": shot.get("capture_epoch_s"),
                    "dimensions": dims,
                    "pixel_depth_verified": False,
                    "pixel_change_correct_verified": False,
                })
        missing_call = [x.get("index") for x in accepted
                        if not isinstance(x.get("brush_call_epoch_s"), (int,float))
                        or not isinstance(x.get("brush_call_ticks_us"), int)]
        if missing_call:
            problems.append("Accepted edit lacks precise timestamp")
        unqualified = [x.get("index") for x in accepted
                       if x.get("first_correct_presented_pixel_ms") is None]
        present_trace = parse_edit_presentmon(runs[0].parent, accepted)
        if not present_trace["available"]:
            problems.append("No lossless clock-aligned per-frame PresentMon edit evidence")
        edit_result = {
            "requested": summary.get("requested_count"),
            "accepted": len(accepted),
            "rejected": len(edits) - len(accepted),
            "missing_call_timestamps": missing_call,
            "correct_presented_pixel_unverified": unqualified,
            "timestamped_calls": len(accepted)-len(missing_call),
            "review_screenshot_count": len(screenshots),
            "marker_indices": [x.get("video_marker_index") for x in accepted
                               if x.get("video_marker_index") is not None],
            "time_origin": "scripted brush call; NOT OS HID input",
            "first_correct_presented_pixel_verified": False,
            "presentmon": present_trace,
            "note": "Video marker proves timing cue only. Earliest ETW display opportunity after brush is NOT correct terrain presentation; independent pixel review required.",
        }
        route_result = None
        if len(edits) != summary.get("requested_count"):
            problems.append("Edit event count mismatches summary")
    return {
        "schema": "a7_visual_evidence_analysis_v1",
        "git_sha": manifest.get("git_sha"),
        "mode": mode, "scenario": scenario, "seed": seed,
        "video_container_available": video_valid,
        "video_bytes_observed": video_size,
        "video_timeline": video_timeline,
        "screenshots": screenshots,
        "screenshot_count": len(screenshots),
        "route": route_result, "edit": edit_result,
        "gates": {
            "STREAM-18": "NOT_QUALIFIED",
            "VIEW-130": "NOT_QUALIFIED",
            "EDIT-100": "NOT_QUALIFIED",
        },
        "automatic_acceptance": False,
        "problems": problems,
        "missing_evidence": [
            "Pixel-accurate continuous screen/video review for terrain, water, rocks and LOD seams",
            "Independent 360-degree 130m depth/pixel verification",
            "Edit target ROI pixel change verified in a presented frame and correlated to input and ETW",
        ],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("evidence_directory", type=Path)
    ns = ap.parse_args()
    d = analyze(ns.evidence_directory)
    output = ns.evidence_directory / "visual_evidence_analysis.json"
    output.write_text(json.dumps(d, indent=2, ensure_ascii=False), encoding="utf-8")
    print("A7_VISUAL_EVIDENCE_REVIEW_REQUIRED", d["mode"], d["scenario"],
          "screenshots", d["screenshot_count"],
          "video_available", d["video_container_available"],
          "issues", len(d["problems"]), flush=True)
    print("A7_VISUAL_EVIDENCE_ANALYSIS="+str(output), flush=True)


if __name__ == "__main__":
    main()
