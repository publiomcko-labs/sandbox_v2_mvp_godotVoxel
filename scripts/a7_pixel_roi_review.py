#!/usr/bin/env python3
"""A7 CPU-only offline target-ROI audit; deliberately NOT a correctness gate.

A visible change near a brush is a candidate, not proof of a first correct
terrain pixel. HUD markers are clock cues only. Requires pinned ffmpeg/ffprobe
and Python stdlib; never performs Godot GPU readback.
"""
from __future__ import annotations
import argparse
import json
import math
import statistics
import subprocess
from pathlib import Path

from a7_video_timeline import locate_video, process_video, read_json

SCHEMA = "a7_pixel_roi_review_v1"
SIDE = 120
CROP_SIDE = 240
INNER = [y * SIDE + x for y in range(SIDE) for x in range(SIDE)
         if 4 < max(abs(x - 60), abs(y - 60)) <= 25]
CONTROL = [y * SIDE + x for y in range(SIDE) for x in range(SIDE)
           if 38 <= max(abs(x - 60), abs(y - 60)) <= 54]


def compare_pixels(before: bytes | memoryview, after: bytes | memoryview) -> dict:
    if len(before) != SIDE * SIDE or len(after) != SIDE * SIDE:
        raise ValueError("Expected matching 120x120 grayscale video patches")
    inner_sum = 0
    changed = 0
    for k in INNER:
        delta = abs(int(before[k]) - int(after[k]))
        inner_sum += delta
        changed += delta > 12
    control_mean = sum(abs(int(before[k]) - int(after[k])) for k in CONTROL) / len(CONTROL)
    inner_mean = inner_sum / len(INNER)
    candidate = (inner_mean > 2.0 and changed >= 20 and
                 control_mean <= 2.5 and inner_mean > 2.5 * max(control_mean, 0.1))
    motion = inner_mean > 2.0 and changed >= 20 and control_mean > 2.5
    return {
        "inner_mean_abs_luma": round(inner_mean, 3),
        "control_mean_abs_luma": round(control_mean, 3),
        "inner_changed_pixels": changed,
        "localized_candidate": candidate,
        "ambiguous_scene_motion": motion,
    }


def classify_edit(patches: bytes, pts: list[float], frame_index: int,
                  next_frame_index: int, call_epoch: float, offset_s: float) -> dict:
    if not 1 <= frame_index < next_frame_index <= len(pts):
        return {"status": "UNUSABLE_MARKER_INDEX", "first_candidate_recorded_pixel_ms": None,
                "first_correct_presented_pixel_ms": None}
    if not isinstance(call_epoch, (int, float)) or not math.isfinite(call_epoch):
        return {"status": "UNUSABLE_BRUSH_TIMESTAMP", "first_candidate_recorded_pixel_ms": None,
                "first_correct_presented_pixel_ms": None}
    baseline = memoryview(patches)[(frame_index-1)*SIDE*SIDE:frame_index*SIDE*SIDE]
    # Camera is aimed at the edit before the brush call. Frames immediately
    # preceding the NEXT marker can contain the next camera orientation.
    last = min(frame_index + 3, next_frame_index - 2)
    if last < frame_index:
        return {"status": "INSUFFICIENT_STABLE_FRAMES",
                "first_candidate_recorded_pixel_ms": None,
                "first_correct_presented_pixel_ms": None}
    findings = []
    for j in range(frame_index, last+1):
        patch = memoryview(patches)[j*SIDE*SIDE:(j+1)*SIDE*SIDE]
        score = compare_pixels(baseline, patch)
        findings.append({"frame": j, "video_pts_s": pts[j], **score})
        if score["localized_candidate"]:
            return {
                "status": "LOCAL_CHANGE_CANDIDATE",
                "first_candidate_frame": j,
                "first_candidate_recorded_pixel_ms": round((pts[j] + offset_s - call_epoch)*1000, 3),
                "first_change_after_marker_ms": round((pts[j] - pts[frame_index])*1000, 3),
                "reviewed_frames": findings,
                "first_correct_presented_pixel_ms": None,
                "note": "Localized recorded appearance change only; not independently correct terrain geometry or HID.",
            }
    status = ("AMBIGUOUS_SCENE_MOTION"
              if any(f["ambiguous_scene_motion"] for f in findings)
              else "NO_LOCAL_CHANGE_DETECTED")
    return {
        "status": status,
        "first_candidate_recorded_pixel_ms": None,
        "first_correct_presented_pixel_ms": None,
        "reviewed_frames": findings,
    }


def process(root: Path, ffmpeg: str, ffprobe: str,
            roi_x: int = 960, roi_y: int = 540) -> dict:
    manifest = read_json(root/"visual_evidence_manifest.json")
    if manifest.get("mode") != "Edit":
        raise ValueError("Target-ROI audit applies only to A7 Edit campaigns")
    video = locate_video(root, manifest)
    if video is None:
        raise FileNotFoundError("Full-resolution desktop video not found")
    matches = sorted((root/"game").rglob("a7_edits.jsonl"))
    if len(matches) != 1:
        raise ValueError("Exactly one A7 edit trace required")
    events = [json.loads(x) for x in matches[0].read_text(encoding="utf-8-sig").splitlines() if x.strip()]
    accepted = [x for x in events if x.get("type") == "edit" and x.get("accepted") is True]
    if len(accepted) != 100 or [x.get("index") for x in accepted] != list(range(100)):
        raise ValueError("Exactly 100 ordered accepted calls required")
    if any(x.get("target_behind_camera") or
           abs(x["target_screen_xy_px"][0] - roi_x) > 16 or
           abs(x["target_screen_xy_px"][1] - roi_y) > 16 for x in accepted):
        raise ValueError("Screen targets outside locked centered ROI tolerance")
    timeline = process_video(root, ffmpeg, ffprobe)
    marker = timeline["marker"]
    if (not marker["alignment_verified"] or len(marker["aligned_events"]) != 100 or
            [x["event_index"] for x in marker["aligned_events"]] != list(range(100))):
        raise ValueError("100 markers must align to ordered accepted brush events")
    cmd = [
        ffmpeg, "-hide_banner", "-loglevel", "error", "-nostdin",
        "-i", str(video), "-map", "0:v:0",
        "-vf", f"crop=240:240:{roi_x-120}:{roi_y-120},scale=120:120:flags=area,format=gray",
        "-fps_mode", "passthrough", "-f", "rawvideo", "-pix_fmt", "gray", "pipe:1",
    ]
    output = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            check=True, timeout=600)
    frames = len(output.stdout)//(SIDE*SIDE)
    if (frames != timeline["frame_integrity"]["frames"] or
            frames*SIDE*SIDE != len(output.stdout)):
        raise ValueError("ROI and marker/video frame indices mismatch")
    probe = subprocess.run([
        ffprobe, "-v", "error", "-select_streams", "v:0",
        "-show_entries", "frame=best_effort_timestamp_time",
        "-of", "json", str(video),
    ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True, timeout=600)
    pts = [float(x["best_effort_timestamp_time"]) for x in json.loads(probe.stdout)["frames"]]
    if len(pts) != frames:
        raise ValueError("Video frame count mismatch between ffprobe and ffmpeg")
    counts = {
        "LOCAL_CHANGE_CANDIDATE": 0,
        "AMBIGUOUS_SCENE_MOTION": 0,
        "NO_LOCAL_CHANGE_DETECTED": 0,
        "INSUFFICIENT_STABLE_FRAMES": 0,
    }
    rows = []
    marks = marker["aligned_events"]
    for i, (edit, mark) in enumerate(zip(accepted, marks)):
        start = mark["video_frame_index"]
        next_frame = marks[i+1]["video_frame_index"] if i < 99 else min(frames, start+6)
        result = classify_edit(output.stdout, pts, start, next_frame,
                               edit.get("brush_call_epoch_s"), marker["video_epoch_offset_s"])
        counts[result["status"]] = counts.get(result["status"], 0) + 1
        rows.append({
            "edit_index": i,
            "brush_call_epoch_s": edit["brush_call_epoch_s"],
            "add": edit["add"],
            "center_sdf_changed": edit.get("sdf_changed"),
            "video_marker_frame": start,
            "roi_center_xy": [roi_x, roi_y],
            **result,
        })
    candidates = [r["first_candidate_recorded_pixel_ms"] for r in rows
                  if r["first_candidate_recorded_pixel_ms"] is not None]
    report = {
        "schema": SCHEMA,
        "scenario": manifest["scenario"],
        "git_sha": manifest.get("git_sha"),
        "video_filename": video.name,
        "video_frames_decoded": frames,
        "input_kind": "SCRIPTED_BRUSH_NOT_HID",
        "alignment_residual_p99_ms": marker["offset_residual_p99_ms"],
        "counts": counts,
        "first_local_candidate_median_ms": round(statistics.median(candidates), 3) if candidates else None,
        "first_local_candidate_max_ms": round(max(candidates), 3) if candidates else None,
        "first_correct_presented_pixel_verified_count": 0,
        "edit_100_gate": "NOT_QUALIFIED",
        "automatic_acceptance": False,
        "constraints": [
            "Video PTS duplicates and clock-alignment uncertainty",
            "Camera changes between edits; control-zone scene-motion check is conservative",
            "Localized luma/color change does not independently verify correct terrain geometry",
            "Scripted brush call is not a physical HID event",
            "No independent depth or ground-truth terrain surface mask in these videos",
        ],
        "edits": rows,
    }
    (root/"a7_pixel_roi_review.json").write_text(
        json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("campaign", type=Path)
    parser.add_argument("--ffmpeg", required=True)
    parser.add_argument("--ffprobe", required=True)
    args = parser.parse_args()
    report = process(args.campaign, args.ffmpeg, args.ffprobe)
    keys = ("scenario", "counts", "first_local_candidate_median_ms",
            "first_local_candidate_max_ms", "edit_100_gate")
    print("A7_ROI_DIAGNOSTIC " + json.dumps({k: report[k] for k in keys}))


if __name__ == "__main__":
    main()
