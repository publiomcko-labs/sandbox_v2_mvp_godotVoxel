#!/usr/bin/env python3
"""Inspect A7.1/A7.2 visual evidence without inferring unobserved pixels."""
from __future__ import annotations
import argparse
import json
import struct
from pathlib import Path

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
    if manifest.get("video_actual_fps_verified") is not True:
        problems.append("Actual captured video FPS/timestamps not independently verified")
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
        missing_call = [x.get("index") for x in accepted
                        if not isinstance(x.get("brush_call_epoch_s"), (int,float))
                        or not isinstance(x.get("brush_call_ticks_us"), int)]
        if missing_call:
            problems.append("Accepted edit lacks precise timestamp")
        unqualified = [x.get("index") for x in accepted
                       if x.get("first_correct_presented_pixel_ms") is None]
        edit_result = {
            "requested": summary.get("requested_count"),
            "accepted": len(accepted),
            "rejected": len(edits) - len(accepted),
            "missing_call_timestamps": missing_call,
            "correct_presented_pixel_unverified": unqualified,
            "timestamped_calls": len(accepted)-len(missing_call),
            "marker_indices": [x.get("video_marker_index") for x in accepted
                               if x.get("video_marker_index") is not None],
            "time_origin": "scripted brush call; NOT OS HID input",
            "first_correct_presented_pixel_verified": False,
            "note": "Video marker proves timing cue only. Terrain pixels must be independently observed, correlated with ETW, and reviewed.",
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
