#!/usr/bin/env python3
"""A7 offline 1080p video frame/clock-index builder (CPU only).

Decodes just an 8x8 HUD color patch for synchronization. Does not certify
world pixels, depth, zero seams, or input-to-correct-pixel EDIT-100.
Requires ffmpeg and ffprobe binaries, never modifies the Windows desktop.
"""
from __future__ import annotations

import argparse
import json
import math
import statistics
import subprocess
from pathlib import Path

CROP = "crop=8:8:1888:42,format=rgb24"
FRAME_BYTES = 8 * 8 * 3
COLORS = {"green", "magenta"}
SCHEMA = "a7_video_timeline_v1"


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def locate_video(folder: Path, manifest: dict) -> Path | None:
    name = manifest.get("video_path")
    if not isinstance(name, str) or not name:
        return None
    candidate = Path(name)
    if candidate.is_file():
        return candidate
    # Windows absolute paths in portable/archived campaign evidence.
    candidate = folder / name.replace("\\", "/").split("/")[-1]
    return candidate if candidate.is_file() else None


def decode_probe_json(blob: str) -> dict:
    d = json.loads(blob)
    streams = d.get("streams", [])
    if len(streams) != 1:
        raise ValueError("Expected exactly one selected video stream")
    stream = streams[0]
    if (int(stream.get("width", 0)), int(stream.get("height", 0))) != (1920, 1080):
        raise ValueError("Video must contain original 1920x1080 frames")
    timestamps = []
    for frame in d.get("frames", []):
        value = frame.get("best_effort_timestamp_time")
        if value in (None, "N/A"):
            continue
        try:
            stamp = float(value)
        except (ValueError, TypeError):
            continue
        if not math.isfinite(stamp):
            continue
        timestamps.append(stamp)
    if len(timestamps) < 100:
        raise ValueError("At least 100 video frames with valid PTS required")
    # D3D11 Desktop Duplication + NVENC can emit duplicate millisecond PTS.
    # Preserve the actual frame order and report these defects rather than
    # dropping evidence or failing before correlation with Godot's markers.
    deltas = [b-a for a,b in zip(timestamps,timestamps[1:])]
    duplicates = sum(d == 0 for d in deltas)
    backwards = sum(d < 0 for d in deltas)
    gaps = [max(0.0,d)*1000.0 for d in deltas]
    return {
        "width": 1920, "height": 1080,
        "frames": len(timestamps),
        "first_pts_s": timestamps[0],
        "last_pts_s": timestamps[-1],
        "duration_by_pts_s": timestamps[-1] - timestamps[0],
        "nominal_video_fps": stream.get("avg_frame_rate"),
        "observed_fps": (len(timestamps)-1)/(timestamps[-1]-timestamps[0]),
        "duplicated_timestamp_pairs": duplicates,
        "backward_timestamp_pairs": backwards,
        "timestamp_strictly_increasing": duplicates == 0 and backwards == 0,
        "gaps_over_33ms": sum(g > 33.0 for g in gaps),
        "gap_p99_ms": sorted(gaps)[math.ceil((len(gaps)-1)*0.99)],
        "gap_max_ms": max(gaps),
        "pts_s": timestamps,
    }


def classify_marker(blob: bytes) -> str:
    if len(blob) != FRAME_BYTES:
        raise ValueError("Expected 8x8 rgb24 marker frame")
    red = sum(blob[i] for i in range(0, len(blob), 3)) / 64
    green = sum(blob[i] for i in range(1, len(blob), 3)) / 64
    blue = sum(blob[i] for i in range(2, len(blob), 3)) / 64
    if green >= 145 and red <= 105 and blue <= 115:
        return "green"
    if red >= 145 and blue >= 135 and green <= 115:
        return "magenta"
    return "unclassified"


def marker_transitions(raw: bytes, pts: list[float]) -> dict:
    if len(raw) % FRAME_BYTES != 0:
        raise ValueError("Non-integral rgb24 output")
    n = len(raw) // FRAME_BYTES
    if n != len(pts):
        raise ValueError(f"Decoder frame mismatch {n} vs ffprobe {len(pts)}")
    events = []
    last = "unclassified"
    classified = 0
    for idx in range(n):
        state = classify_marker(raw[idx*FRAME_BYTES:(idx+1)*FRAME_BYTES])
        if state in COLORS:
            classified += 1
            if state != last:
                events.append({"frame_index":idx, "pts_s":pts[idx], "color":state})
        last = state
    return {"frame_count":n, "classified_frames":classified, "transitions":events}


def expected_markers(mode: str, events: list[dict]) -> list[dict]:
    if mode == "Route":
        out = []
        for e in events:
            if e.get("type") == "video_sync":
                out.append({
                    "index":e.get("index"),
                    "color":"green" if e.get("marker_rgb") == "00ff00" else "magenta",
                    "event_epoch_s":e.get("event_epoch_s"),
                })
        return out
    out = []
    for e in events:
        if e.get("type") == "edit" and e.get("accepted") is True and e.get("video_marker_index") is not None:
            out.append({
                "index":e.get("video_marker_index"),
                "color":"green" if e.get("video_marker_rgb") == "00ff00" else "magenta",
                "event_epoch_s":e.get("brush_return_epoch_s"),
            })
    return out


def correlate_markers(expected: list[dict], observed: list[dict]) -> dict:
    result = {
        "expected_events":len(expected),
        "observed_transitions":len(observed),
        "sequence_verified":False,
        "video_epoch_offset_s":None,
        "offset_residual_p99_ms":None,
        "alignment_verified":False,
        "aligned_events":[],
        "note":"Video HUD marker identifies presentation timing cue only; NOT world-pixel correctness.",
    }
    if (len(expected) < 3 or len(expected) != len(observed) or
            any(e.get("color") != o.get("color") for e,o in zip(expected,observed)) or
            any(not isinstance(e.get("event_epoch_s"),(int,float)) for e in expected)):
        return result
    offsets = [e["event_epoch_s"] - o["pts_s"] for e,o in zip(expected,observed)]
    median = statistics.median(offsets)
    deviations_ms = sorted(abs(x - median)*1000.0 for x in offsets)
    residual_p99 = deviations_ms[math.ceil((len(deviations_ms)-1)*0.99)]
    result["sequence_verified"] = True
    result["video_epoch_offset_s"] = median
    result["offset_residual_p99_ms"] = round(residual_p99,3)
    result["aligned_events"] = [
        {"event_index":e["index"],"color":e["color"],
         "game_epoch_s":e["event_epoch_s"],"video_pts_s":o["pts_s"],
         "video_frame_index":o["frame_index"],
         "offset_residual_ms":round((offset-median)*1000.0,3)}
        for e,o,offset in zip(expected,observed,offsets)
    ]
    # This is an *estimated* clock alignment, not a certified presentation
    # timestamp. Render/compositor delay and video sampling remain unknown.
    result["alignment_verified"] = residual_p99 <= 50.0
    return result


def route_movement_window(frames: list[float], expected: list[dict],
                          aligned: dict) -> dict | None:
    """Measure only the routed 30s segment bracketed by visible sync changes.

    Avoid diluting 60fps conclusions with recorder startup/20s warmup.
    """
    marks = aligned.get("aligned_events", [])
    if len(marks) < 2 or len(expected) != len(marks):
        return None
    first, last = marks[0], marks[-1]
    i, j = first["video_frame_index"], last["video_frame_index"]
    if not (isinstance(i,int) and isinstance(j,int) and 0 <= i < j < len(frames)):
        return None
    section = frames[i:j+1]
    deltas = [(b-a)*1000.0 for a,b in zip(section,section[1:])]
    positive = [max(0.0,x) for x in deltas]
    elapsed = section[-1]-section[0]
    if elapsed <= 0.0:
        return None
    return {
        "start_frame": i,"end_frame":j,
        "frames":len(section),"elapsed_pts_s":round(elapsed,3),
        "observed_fps":round((len(section)-1)/elapsed,4),
        "duplicated_pts_pairs":sum(x==0.0 for x in deltas),
        "backward_pts_pairs":sum(x<0.0 for x in deltas),
        "gaps_over_33ms":sum(x>33.0 for x in deltas),
        "gap_max_ms":round(max(positive),3),
        "note":"Recorded video PTS only, NOT app/compositor presented-frame cadence",
    }


def process_video(root: Path, ffmpeg: str, ffprobe: str) -> dict:
    manifest = read_json(root/"visual_evidence_manifest.json")
    if manifest.get("schema") != "a7_visual_evidence_manifest_v1":
        raise ValueError("A7 evidence manifest schema mismatch")
    video = locate_video(root, manifest)
    if video is None or video.stat().st_size < 1_000_000:
        raise FileNotFoundError("Full desktop capture video missing")
    run_candidates = list((root/"game").rglob("a7_route.jsonl" if manifest.get("mode") == "Route" else "a7_edits.jsonl"))
    if len(run_candidates) != 1:
        raise ValueError("Expected exactly one matching Godot event trace")
    events = [json.loads(line) for line in run_candidates[0].read_text(encoding="utf-8-sig").splitlines() if line.strip()]
    probe_cmd = [ffprobe, "-v","error", "-select_streams","v:0",
                 "-show_entries","stream=width,height,avg_frame_rate:frame=best_effort_timestamp_time",
                 "-of","json",str(video)]
    probe = subprocess.run(probe_cmd, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, check=True,timeout=600)
    info = decode_probe_json(probe.stdout.decode("utf-8"))
    # Enforce passthrough, no fps filter/interpolation; every output sample
    # must correspond to a real decoded input frame and PTS index.
    patch_cmd = [ffmpeg,"-hide_banner","-loglevel","error","-nostdin",
                 "-i",str(video), "-map","0:v:0", "-vf",CROP,
                 "-fps_mode","passthrough","-f","rawvideo", "-pix_fmt","rgb24","pipe:1"]
    raw = subprocess.run(patch_cmd,stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, check=True,timeout=600)
    marker = marker_transitions(raw.stdout,info["pts_s"])
    expected = expected_markers(manifest["mode"],events)
    aligned = correlate_markers(expected,marker["transitions"])
    route_window = (
        route_movement_window(info["pts_s"],expected,aligned)
        if manifest.get("mode") == "Route" else None)
    info.pop("pts_s")
    report = {
        "schema":SCHEMA,"video_name":video.name,
        "video_sha256_status":"NOT_HASHED",
        "source_mode":manifest.get("mode"),
        "mode":"OFFLINE_CPU_VIDEO_ANALYSIS",
        "frame_integrity":info,
        "video_fps_60_diagnostic":info["observed_fps"]>=59.0,
        "video_gap_over_33ms":info["gap_max_ms"]>33.0,
        "route_movement_window":route_window,
        "marker":aligned,
        "marker_classified_frames":marker["classified_frames"],
        "marker_transitions":marker["transitions"],
        "strict_stream_18":"NOT_QUALIFIED",
        "strict_view_130":"NOT_QUALIFIED",
        "strict_edit_100":"NOT_QUALIFIED",
        "pixel_terrain_correctness_verified":False,
        "depth_coverage_verified":False,
        "note":"Recordings and HUD sync prove neither uninterrupted geometry nor 130m 360deg depth nor correct edited pixels. Review actual decoded video and target ROI.",
    }
    (root/"a7_video_timeline.json").write_text(json.dumps(report,indent=2,ensure_ascii=False),encoding="utf-8")
    return report


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("campaign",type=Path)
    ap.add_argument("--ffmpeg",required=True)
    ap.add_argument("--ffprobe",required=True)
    args=ap.parse_args()
    result=process_video(args.campaign,args.ffmpeg,args.ffprobe)
    print("A7_VIDEO_TIMELINE_FRAMES="+str(result["frame_integrity"]["frames"]))
    print("A7_VIDEO_PTS_DUPLICATES="+str(result["frame_integrity"]["duplicated_timestamp_pairs"]))
    if result["route_movement_window"] is not None:
        print("A7_VIDEO_ROUTE_EFFECTIVE_FPS="+str(result["route_movement_window"]["observed_fps"]))
    print("A7_VIDEO_SYNC_SEQUENCE="+str(result["marker"]["sequence_verified"]))
    print("A7_VIDEO_SYNC_ALIGNMENT="+str(result["marker"]["alignment_verified"]))
    print("A7_VIDEO_PIXELS=NOT_QUALIFIED")


if __name__=="__main__":
    main()
