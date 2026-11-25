#!/usr/bin/env python3
"""A8-P0: read A7 CPU16 GPU-route telemetry without promoting visual gates.

One short, real-desktop, 1000-rendered-frame warmup route. No render readback,
video, ETW or automatic 60FPS/130m/18mps pixel qualification.
"""
from __future__ import annotations
import argparse
import json
import math
import statistics
from pathlib import Path

SCHEMA = "a8_route_triage_v1"
A5_SHA = "0c3fee959576d0a1faec9ceecffb4b132a65558b"
ALLOWED = ("straight_18mps_600s", "turns_18mps_300s", "out_and_back_18mps_300s")


def read(path: Path) -> dict:
    value = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(value, dict):
        raise ValueError(f"Expected object {path.name}")
    return value


def finite(value: object) -> float | None:
    if type(value) not in (int, float) or not math.isfinite(value):
        return None
    return float(value)


def summarize(folder: Path) -> dict:
    manifest = read(folder / "manifest.json")
    if (manifest.get("schema") != "a7_campaign_v1" or
            manifest.get("baseline_checkpoint") != A5_SHA or
            manifest.get("ci_smoke") is not False or
            manifest.get("full") is not False or
            manifest.get("capture") is not False or
            manifest.get("presentmon_requested") is not False or
            manifest.get("warmup_frames_requested") != 1000 or
            manifest.get("mesh_block_voxels") != 16 or
            manifest.get("lod_count") != 4 or
            manifest.get("requested_view_distance_m") != 192 or
            manifest.get("repeats") != 1):
        raise ValueError("A8 provenance mismatch: 1000-frame A5 CPU16 real GPU route only")
    scenarios = manifest.get("scenarios")
    seeds = manifest.get("seeds")
    if (not isinstance(scenarios, list) or len(scenarios) != 1 or
            scenarios[0] not in ALLOWED or
            not isinstance(seeds, list) or len(seeds) != 1 or
            type(seeds[0]) is not int):
        raise ValueError("Unexpected scenario or seed list")
    route = scenarios[0]
    seed = seeds[0]
    trials = list(folder.rglob("a7_route.json"))
    if len(trials) != 1:
        raise ValueError(f"Expected exactly one route report, found {len(trials)}")
    report = read(trials[0])
    if (report.get("schema") != "a7_route_v1" or
            report.get("route") != route or
            report.get("seed") != seed or
            report.get("ci_smoke") is not False or
            report.get("capture") is not False or
            report.get("warmup_drawn_frames_requested") != 1000 or
            type(report.get("warmup_drawn_frames_observed")) is not int or
            report["warmup_drawn_frames_observed"] < 1000 or
            report.get("frame_count", 0) < 60 or
            report.get("screenshots") != 0 or
            report.get("gpu_render_samples", -1) < 0 or
            report.get("perf_60_full_present_gate") != "NOT_QUALIFIED" or
            report.get("stream_18_pixel_gate") != "NOT_QUALIFIED" or
            report.get("view_130_pixel_depth_gate") != "NOT_QUALIFIED" or
            report.get("voxel_threads_requested") != 0 or
            report.get("vsync_off_requested") is not False or
            not finite(report.get("warmup_observed_s"))):
        raise ValueError("Route stats not comparable to A8 real graphical pilot")
    if (not finite(report.get("duration_s")) or report["duration_s"] < 5 or
            not finite(report.get("frame_start_max_ms")) or
            not finite(report.get("frame_start_p99_ms"))):
        raise ValueError("Route timing incomplete")
    trace_path = trials[0].with_name("a7_route.jsonl")
    if not trace_path.is_file():
        raise ValueError("Missing route trace")
    samples = []
    warmup_end = []
    with trace_path.open(encoding="utf-8-sig") as file:
        for line in file:
            if not line.strip():
                continue
            obj = json.loads(line)
            if obj.get("type") == "sample" and obj.get("phase") == "moving":
                samples.append(obj)
            elif obj.get("type") == "warmup_end":
                warmup_end.append(obj)
    if (len(warmup_end) != 1 or
            warmup_end[0].get("warmup_drawn_frames_requested") != 1000 or
            warmup_end[0].get("warmup_drawn_frames_observed", 0) < 1000 or
            len(samples) < 3):
        raise ValueError("No complete warmup/route sample sequence")
    if (report["warmup_drawn_frames_observed"] !=
            warmup_end[0]["warmup_drawn_frames_observed"]):
        raise ValueError("Warmup trace inconsistent with route report")

    def vals(key):
        return [v for x in samples if (v := finite(x.get(key))) is not None]

    probes = vals("meshed_radial_probes")
    if len(probes) != len(samples) or any(x < 0 or x > 8 for x in probes):
        raise ValueError("Missing/invalid 130m radial mesh probes")
    queue = []
    active = []
    speeds = []
    for sample in samples:
        workers = sample.get("voxel_workers", {})
        q = finite(workers.get("queued_tasks"))
        a = finite(workers.get("active_threads"))
        if q is not None and q >= 0: queue.append(q)
        if a is not None and a >= 0: active.append(a)
    for first, second in zip(samples, samples[1:]):
        t1, t2 = finite(first.get("t_s")), finite(second.get("t_s"))
        positions = [finite(row.get(key)) for row in (first, second)
                     for key in ("player_x", "player_z")]
        if t1 is None or t2 is None or t2 <= t1 or any(v is None for v in positions):
            raise ValueError("Nonmonotonic route samples or missing coordinates")
        horizontal = math.hypot(positions[2]-positions[0], positions[3]-positions[1])
        speeds.append(horizontal/(t2-t1))
    if any(not 0 <= v <= 60 for v in speeds):
        raise ValueError("Impossible sampled horizontal speeds")
    try:
        speed_median = round(statistics.median(speeds), 3)
    except statistics.StatisticsError:
        raise ValueError("Missing speed samples")
    over16 = report.get("frame_intervals_over_16_7_ms")
    over20 = report.get("frame_intervals_over_20_ms")
    over33 = report.get("frame_intervals_over_33_ms")
    if any(type(x) is not int or x < 0 or x > report["frame_count"]
           for x in (over16, over20, over33)):
        raise ValueError("Missing/non-monotonic frame interval counters")
    if not (over33 <= over20 <= over16):
        raise ValueError("Frame threshold counters inconsistent")
    result = {
        "schema": SCHEMA,
        "source_folder": folder.name,
        "baseline_sha": A5_SHA,
        "route": route, "seed": seed,
        "requested_speed_mps": 18,
        "sampled_horizontal_speed_mps_median": speed_median,
        "warmup_rendered_frames": report["warmup_drawn_frames_observed"],
        "warmup_elapsed_s": round(report["warmup_observed_s"], 3),
        "duration_s": report["duration_s"],
        "frames": report["frame_count"],
        "frame_start_p50_ms": finite(report.get("frame_start_p50_ms")),
        "frame_start_p95_ms": finite(report.get("frame_start_p95_ms")),
        "frame_start_p99_ms": finite(report.get("frame_start_p99_ms")),
        "frame_start_p999_ms": finite(report.get("frame_start_p999_ms")),
        "frame_start_max_ms": finite(report.get("frame_start_max_ms")),
        "start_intervals_over_16_7_ms": over16,
        "start_intervals_over_20_ms": over20,
        "start_intervals_over_33_ms": over33,
        "viewport_cpu_render_p99_ms": finite(report.get("viewport_render_cpu_p99_ms")),
        "viewport_gpu_render_p99_ms": finite(report.get("viewport_render_gpu_p99_ms")),
        "gpu_viewport_samples": report["gpu_render_samples"],
        "min_130m_mesh_probes_per_sample": min(probes),
        "samples_with_incomplete_mesh_probes": sum(p < 8 for p in probes),
        "mesh_probe_samples": len(probes),
        "max_voxel_worker_queue": max(queue) if queue else None,
        "max_active_workers": max(active) if active else None,
        "diagnostic_flags": {
            "frame_start_budget_exceeded": over16 > 0,
            "mesh_probes_incomplete": any(p < 8 for p in probes),
            "worker_queue_observed": bool(queue and max(queue) > 0),
            "sampled_speed_not_near_18mps": not (17.0 <= speed_median <= 19.0),
        },
        "evidence_class": "GRAPHICAL_ROUTE_DIAGNOSTIC_ONLY",
        "perf_60_gate": "NOT_QUALIFIED",
        "stream_18_gate": "NOT_QUALIFIED",
        "view_130_gate": "NOT_QUALIFIED",
        "edit_100_gate": "NOT_QUALIFIED",
        "automatic_acceptance": False,
        "limitations": [
            "Frame start-to-start intervals do not include independently validated GPU compositor/display present",
            "GPU viewport render times from Godot are not external full-frame presentation times",
            "Eight mesh-ready probes at 130m do not verify correct geometry pixels, seams, water or rocks",
            "No screen video in the performance arm; cannot certify zero flicker at 18mps",
            "One seed and one short run are for triage, not canonical acceptance",
            "Worker queue and frame spikes are correlations only, not proven causal bottlenecks"
        ]
    }
    (folder/"a8_triage.json").write_text(
        json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument("directory", type=Path)
    args = p.parse_args()
    r = summarize(args.directory)
    print("A8_DIAGNOSTIC_ONLY " + json.dumps({
        "route": r["route"], "warmup_frames":r["warmup_rendered_frames"],
        "frames":r["frames"],"p99_frame_start_ms":r["frame_start_p99_ms"],
        "over16_7":r["start_intervals_over_16_7_ms"],
        "mesh_probe_min":r["min_130m_mesh_probes_per_sample"],
        "gpu_present_qualified":False}, ensure_ascii=False))


if __name__ == "__main__":
    main()
