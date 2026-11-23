#!/usr/bin/env python3
"""A7.4 CPU-only pre-edit SDF / analytic-CSG reference vs external video pilot.

Independent of the *post-edit rendered mesh*, but NOT of the pre-edit Godot SDF.
RGB/luma agreement is a geometric change candidate, NOT a verified depth pixel,
presented-frame timing, or strict EDIT-100 acceptance. Never auto-promote.
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import subprocess
from pathlib import Path

from a7_video_timeline import (
    CROP, correlate_markers, decode_probe_json, marker_transitions, read_json,
)

SCHEMA = "a74_geometry_video_pilot_v1"
STEP_M = 0.125
VIDEO_CROP = "crop=240:240:840:420,format=gray"
PATCH_SIDE = 240
PATCH_BYTES = PATCH_SIDE * PATCH_SIDE


def vec(values: object, n: int = 3) -> tuple[float, ...]:
    if (not isinstance(values, list) or len(values) != n or
            any(not isinstance(v, (int, float)) or
                isinstance(v, bool) or not math.isfinite(v) for v in values)):
        raise ValueError("Nonfinite/missing geometry vector")
    return tuple(float(v) for v in values)


def validate_reference(ref: dict) -> None:
    if ref.get("schema") != "a74_preedit_reference_v1":
        raise ValueError("Unrecognized pre-edit geometry schema")
    if ref.get("camera_fixed") is not True or ref.get("screen_size") != [1920, 1080]:
        raise ValueError("Fixed 1080p camera provenance required")
    brush = ref["brush"]
    vec(brush["center"])
    if brush.get("operation") not in ("add", "remove") or brush.get("radius_m") != 1.5:
        raise ValueError("Expected analytic spherical CSG operation and radius")
    baseline = ref["baseline"]
    side = baseline.get("side")
    if (not isinstance(side, int) or side < 5 or side > 32 or
            baseline.get("source") != "PRE_EDIT_VOXELTOOL_SDF_LATTICE"):
        raise ValueError("Unrecognized independent-of-mesher baseline")
    vec(baseline["origin"])
    values = baseline.get("values")
    if not isinstance(values, list) or len(values) != side ** 3:
        raise ValueError("Incomplete voxel lattice")
    if any(not isinstance(v, (int, float)) or isinstance(v, bool) or
           not math.isfinite(v) for v in values):
        raise ValueError("Nonfinite voxel baseline")
    rays = ref.get("rays")
    if not isinstance(rays, list) or len(rays) < 25:
        raise ValueError("Reference needs >=25 screen rays")
    if len(set(tuple(r["pixel"]) for r in rays)) != len(rays):
        raise ValueError("Repeated reference pixel")
    for r in rays:
        px, py = vec(r["pixel"], 2)
        if not (840 <= px < 1080 and 420 <= py < 660):
            raise ValueError("Ray outside separately decoded ROI")
        vec(r["origin"])
        d = vec(r["direction"])
        if abs(sum(x*x for x in d)-1.0) > 0.02:
            raise ValueError("Ray direction is not normalized")


def sample_sdf(ref: dict, pos: tuple[float, float, float]) -> float:
    grid = ref["baseline"]
    side = grid["side"]
    origin = grid["origin"]
    u = [pos[i]-origin[i] for i in range(3)]
    if any(v < 0 or v >= side-1 for v in u):
        raise ValueError("Point outside SDF interpolation lattice")
    ix, iy, iz = [int(math.floor(x)) for x in u]
    fx, fy, fz = [x-math.floor(x) for x in u]
    values = grid["values"]

    def at(x: int, y: int, z: int) -> float:
        return float(values[(z*side+y)*side+x])

    total = 0.0
    for dz in (0, 1):
        for dy in (0, 1):
            for dx in (0, 1):
                w = ((fx if dx else 1-fx) *
                     (fy if dy else 1-fy) *
                     (fz if dz else 1-fz))
                total += w*at(ix+dx, iy+dy, iz+dz)
    return total


def expected_sdf(ref: dict, pos: tuple[float, float, float],
                 after: bool) -> float:
    base = sample_sdf(ref, pos)
    if not after:
        return base
    brush = ref["brush"]
    center = vec(brush["center"])
    sphere = math.sqrt(sum((pos[i]-center[i])**2 for i in range(3))) - brush["radius_m"]
    return min(base, sphere) if brush["operation"] == "add" else max(base, -sphere)


def ray_interval(ref: dict, ray: dict) -> tuple[float, float] | None:
    grid = ref["baseline"]
    low = vec(grid["origin"])
    high = tuple(v + grid["side"] - 1 - 1e-6 for v in low)
    o, d = vec(ray["origin"]), vec(ray["direction"])
    near, far = 0.0, float("inf")
    for i in range(3):
        if abs(d[i]) < 1e-12:
            if o[i] < low[i] or o[i] > high[i]:
                return None
            continue
        a, b = (low[i]-o[i])/d[i], (high[i]-o[i])/d[i]
        if a > b:
            a, b = b, a
        near, far = max(near, a), min(far, b)
        if near > far:
            return None
    return near, far


def first_surface_t(ref: dict, ray: dict, after: bool) -> float | None:
    interval = ray_interval(ref, ray)
    if interval is None:
        return None
    start, end = interval
    if end-start < STEP_M:
        return None
    o, d = vec(ray["origin"]), vec(ray["direction"])
    # Ignore the end boundary to leave room for the trilinear stencil.
    def sdf(t: float) -> float:
        return expected_sdf(ref, tuple(o[i]+d[i]*t for i in range(3)), after)
    base_t = start + 1e-5
    previous_t = base_t
    previous = sdf(previous_t)
    if previous < 0.0:
        # Cannot assign a visible front face if the ray starts inside material.
        return None
    n = int(math.ceil((end-base_t)/STEP_M))
    for k in range(1, n+1):
        t = min(end-1e-5, base_t+k*STEP_M)
        if t <= previous_t:
            break
        current = sdf(t)
        if previous > 0.0 and current <= 0.0:
            alpha = previous/(previous-current) if previous != current else 1.0
            return previous_t + (t-previous_t)*alpha
        previous_t, previous = t, current
    return None


def reference_rays(ref: dict) -> list[dict]:
    validate_reference(ref)
    output = []
    for ray in ref["rays"]:
        before = first_surface_t(ref, ray, False)
        after = first_surface_t(ref, ray, True)
        delta = None if before is None or after is None else after-before
        visible_change = ((before is None) != (after is None) or
                          (delta is not None and abs(delta) >= 0.25))
        output.append({
            "pixel": ray["pixel"], "pre_hit_t_m": before,
            "oracle_post_hit_t_m": after, "oracle_depth_delta_m": delta,
            "predicted_changed": visible_change,
        })
    return output


def roi_luma(patches: bytes, frame: int, px: list[int]) -> float:
    x, y = px[0]-840, px[1]-420
    if not (1 <= x < PATCH_SIDE-1 and 1 <= y < PATCH_SIDE-1):
        raise ValueError("Pixel falls outside safe ROI")
    offset = frame*PATCH_BYTES
    values = [patches[offset+(y+dy)*PATCH_SIDE+x+dx]
              for dy in (-1, 0, 1) for dx in (-1, 0, 1)]
    return statistics.median(values)


def evaluate_video(ref_rays: list[dict], patches: bytes, frames: int,
                   edit_marker: int, pts: list[float],
                   brush_epoch_s: float, offset_s: float) -> dict:
    if len(patches) != frames * PATCH_BYTES or len(pts) != frames:
        raise ValueError("Decoded luma and PTS frame indices disagree")
    if not (8 <= edit_marker < frames-8):
        raise ValueError("Insufficient pre/post-edit video frames")
    changed = [r for r in ref_rays if r["predicted_changed"]]
    controls = [r for r in ref_rays if not r["predicted_changed"]]
    if len(changed) < 8 or len(controls) < 8:
        return {"status": "INSUFFICIENT_INDEPENDENT_RAYS",
                "expected_changed_rays": len(changed), "control_rays": len(controls),
                "first_oracle_consistent_candidate_ms": None}
    baseline = {
        tuple(r["pixel"]): statistics.median(
            roi_luma(patches, j, r["pixel"]) for j in range(edit_marker-6, edit_marker-2)
        ) for r in ref_rays
    }
    # Global video timing can contain recorder startup gaps. The EDIT window
    # is independently checked; duplicated/backward/gapped PTS would make
    # candidate latency ambiguous, even when the image comparison is clear.
    window_deltas_ms = [
        (pts[j+1] - pts[j]) * 1000.0
        for j in range(edit_marker-6, edit_marker+7)
    ]
    window_bad = any(delta <= 0.0 or delta > 34.0 for delta in window_deltas_ms)
    frames_checked = []
    first = None
    for frame in range(edit_marker, edit_marker+7):
        def deltas(rows: list[dict]) -> list[float]:
            return [abs(roi_luma(patches, frame, r["pixel"]) -
                        baseline[tuple(r["pixel"])]) for r in rows]
        hit_delta, control_delta = deltas(changed), deltas(controls)
        hit = sum(v >= 18.0 for v in hit_delta) / len(hit_delta)
        false = sum(v >= 18.0 for v in control_delta) / len(control_delta)
        # The legacy strong-per-pixel test missed a visually obvious A7.4
        # cavity: changed rays averaged 9.7 luma levels, controls 2.5.
        # A second, more sensitive CONTRAST test requires spatial selectivity,
        # substantial change coverage and quiet independent control rays.
        # It remains a diagnostic, not correct-depth or latency qualification.
        hit_low = sum(v >= 4.0 for v in hit_delta) / len(hit_delta)
        false_low = sum(v >= 4.0 for v in control_delta) / len(control_delta)
        hit_mean = statistics.mean(hit_delta)
        control_mean = statistics.mean(control_delta)
        strong = hit >= 0.60 and false <= 0.15
        contrast = (hit_mean >= 6.0 and control_mean <= 3.5 and
                    hit_mean >= 2.8 * max(control_mean, 0.1) and
                    hit_low >= 0.70 and false_low <= 0.25)
        candidate = strong or contrast
        frames_checked.append({
            "frame": frame, "video_pts_s": pts[frame],
            "predicted_change_signal_ratio": round(hit, 3),
            "control_false_change_ratio": round(false, 3),
            "predicted_change_low_contrast_ratio": round(hit_low, 3),
            "control_low_contrast_ratio": round(false_low, 3),
            "predicted_mean_abs_luma": round(hit_mean, 3),
            "control_mean_abs_luma": round(control_mean, 3),
            "detection_method": "STRONG_PIXEL" if strong else
                                "SPATIAL_CONTRAST" if contrast else "NONE",
            "oracle_consistent_luma_candidate": candidate
        })
        if candidate and first is None and not window_bad:
            first = round((pts[frame] + offset_s - brush_epoch_s)*1000.0, 3)
    return {
        "status": "TIMING_AMBIGUOUS" if window_bad else
                  "ORACLE_CONSISTENT_LUMA_CANDIDATE" if first is not None
                  else "NO_CONSISTENT_LUMA_SIGNAL",
        "expected_changed_rays": len(changed), "control_rays": len(controls),
        "edit_window_gap_max_ms": round(max(window_deltas_ms), 3),
        "edit_window_invalid_pts": window_bad,
        "frames_reviewed": frames_checked,
        "first_oracle_consistent_candidate_ms": first,
        "first_correct_presented_pixel_ms": None,
    }


def run(root: Path, ffmpeg: str, ffprobe: str) -> dict:
    manifest = read_json(root / "a74_capture_manifest.json")
    if (manifest.get("schema") != "a74_capture_manifest_v1" or
            manifest.get("foreground_ok") is not True or
            manifest.get("game_exit_code") != 0 or
            manifest.get("ffmpeg_exit_code") != 0 or
            manifest.get("video_container_valid") is not True):
        raise ValueError("Capture provenance invalid; no pilot conclusion")
    # New fast-batch capture: demand 1000 *actually drawn* warmup frames,
    # then an explicit recorder handshake; never silently fall back to seconds.
    warmup_target = manifest.get("warmup_frames_requested", 0)
    if type(warmup_target) is not int or warmup_target < 0 or warmup_target > 10000:
        raise ValueError("Invalid warmup provenance")
    if warmup_target:
        ready = read_json(root / "a74_ready.json")
        if (ready.get("schema") != "a74_capture_ready_v1" or
                ready.get("scenario") != manifest.get("scenario") or
                ready.get("seed") != manifest.get("seed") or
                ready.get("warmup_mode") != "rendered_frames" or
                ready.get("warmup_frames_requested") != warmup_target or
                ready.get("warmup_frames_observed", 0) < warmup_target or
                manifest.get("recording_started_after_warmup") is not True or
                manifest.get("warmup_frames_observed") != ready.get("warmup_frames_observed")):
            raise ValueError("Incomplete drawn-frame warmup / recorder handshake")
    ref = read_json(root / "a74_reference.json")
    validate_reference(ref)
    result = read_json(root / "a74_result.json")
    if (result.get("accepted_count") != 1 or result.get("scenario") != ref.get("scenario")
            or result.get("edit_100_gate") != "NOT_QUALIFIED"):
        raise ValueError("Invalid single-edit pilot result")
    events = [json.loads(line) for line in
              (root / "a74_events.jsonl").read_text(encoding="utf-8-sig").splitlines()
              if line.strip()]
    marks = [r for r in events if r.get("type") == "sync"]
    edits = [r for r in events if r.get("type") == "edit"]
    if (len(marks) != 8 or len(edits) != 1 or
            [r.get("index") for r in marks] != list(range(8)) or
            edits[0].get("accepted") is not True):
        raise ValueError("Eight ordered clock markers + exactly one edit required")
    video = root/"desktop-1080p-60fps.mkv"
    if not video.is_file() or video.stat().st_size < 1_000_000:
        raise ValueError("No complete visual evidence")
    probe = subprocess.run([
        ffprobe, "-v", "error", "-select_streams", "v:0",
        "-show_entries", "stream=width,height,avg_frame_rate:frame=best_effort_timestamp_time",
        "-of", "json", str(video)], capture_output=True, check=True, timeout=300)
    info = decode_probe_json(probe.stdout.decode("utf-8"))
    pts = info["pts_s"]
    sync = subprocess.run([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
        "-i", str(video), "-map", "0:v:0", "-vf", CROP,
        "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "rgb24", "pipe:1"],
        capture_output=True, check=True, timeout=300)
    observed = marker_transitions(sync.stdout, pts)["transitions"]
    expected = [{"index": r["index"], "color":
                 "green" if r["marker_rgb"] == "00ff00" else "magenta",
                 "event_epoch_s": r["event_epoch_s"]} for r in marks]
    alignment = correlate_markers(expected, observed)
    if (not alignment["alignment_verified"] or len(alignment["aligned_events"]) != 8
            or any(r["event_index"] != k for k, r in
                   enumerate(alignment["aligned_events"]))):
        raise ValueError("Visual clock alignment failed closed")
    roi = subprocess.run([
        ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
        "-i", str(video), "-map", "0:v:0", "-vf", VIDEO_CROP,
        "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1"],
        capture_output=True, check=True, timeout=300)
    edit_frame = alignment["aligned_events"][4]["video_frame_index"]
    rays = reference_rays(ref)
    observations = evaluate_video(
        rays, roi.stdout, info["frames"], edit_frame, pts,
        edits[0]["brush_call_epoch_s"], alignment["video_epoch_offset_s"])
    report = {
        "schema": SCHEMA, "scenario": ref["scenario"],
        "warmup_frames_requested": warmup_target,
        "warmup_frames_observed": manifest.get("warmup_frames_observed"),
        "pilot_status": observations["status"],
        "reference_source": "pre-edit SDF samples plus analytic CSG, NOT rendered mesh",
        "video_frame_count": info["frames"],
        "video_duplicate_pts_pairs": info["duplicated_timestamp_pairs"],
        "video_gap_max_ms": info["gap_max_ms"],
        "video_startup_gaps_not_attributed_to_edit": True,
        "marker_alignment_residual_p99_ms": alignment["offset_residual_p99_ms"],
        "observations": observations,
        "oracle_rays": rays,
        "input_kind": "SCRIPTED_BRUSH_NOT_HID",
        "depth_buffer_independently_verified": False,
        "etw_present_aligned": False,
        "automatic_acceptance": False,
        "first_correct_presented_pixel_ms": None,
        "edit_100_gate": "NOT_QUALIFIED",
        "limitations": [
            "Expected geometry is independent of post-edit meshing, but pre-edit SDF comes from Godot",
            "Color/luminance cannot establish depth or exact geometry",
            "FFmpeg video PTS/clock marker do not certify compositor/display presentation time",
            "No ETW/HID correlation in this pilot",
            "Never reuse this evidence as PERF-60, STREAM-18 or VIEW-130 approval"
        ]
    }
    (root/"a74_pilot_review.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("campaign", type=Path)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--ffprobe", required=True)
    a = parser.parse_args()
    result = run(a.campaign, a.ffmpeg, a.ffprobe)
    print("A74_PILOT_REVIEW " + json.dumps({
        "status": result["pilot_status"], "edit_100_gate": result["edit_100_gate"],
        "observations": result["observations"].get("first_oracle_consistent_candidate_ms")
    }))


if __name__ == "__main__":
    main()
