#!/usr/bin/env python3
"""A8-P2: fail-closed provenance audit for a separate 1000-frame visual route.

This audit checks recorder/video clock and route setup, not pixel correctness.
The original desktop video is necessary for independent human visual review.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
from pathlib import Path

SCHEMA = "a8_visual_evidence_review_v1"
ROUTES = ("turns_18mps_300s", "straight_18mps_600s", "out_and_back_18mps_300s")


def load(path: Path) -> dict:
    obj = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(obj, dict):
        raise ValueError(f"Expected JSON object: {path}")
    return obj


def one(root: Path, name: str) -> Path:
    hits = list(root.rglob(name))
    if len(hits) != 1 or not hits[0].is_file():
        raise ValueError(f"Expected one evidence {name}; found {len(hits)}")
    return hits[0]


def report(root: Path) -> dict:
    m = load(root/"visual_evidence_manifest.json")
    timeline = load(root/"a7_video_timeline.json")
    campaign = load(root/"game"/"manifest.json")
    route = load(one(root/"game","a7_route.json"))
    if (m.get("schema") != "a7_visual_evidence_manifest_v1" or
            m.get("mode") != "Route" or
            m.get("scenario") not in ROUTES or
            m.get("a8_visual_evidence_requested") is not True or
            m.get("warmup_frames_requested") != 1000 or
            m.get("game_run_succeeded") is not True or
            m.get("capture_mode_valid") is not True or
            m.get("video_capture_valid_container") is not True or
            m.get("video_exit_code") != 0 or
            m.get("recorder_mode") != "ddagrab_nvenc" or
            m.get("video_fps_requested") != 60 or
            m.get("video_capture_region_xywh") != [0,0,1920,1080] or
            m.get("presentmon_requested") is not False or
            m.get("in_engine_screenshot_interval_s") != 0 or
            m.get("strict_gates") != "NOT_QUALIFIED"):
        raise ValueError("Incorrect visual-only route/recorder provenance")
    if (campaign.get("baseline_checkpoint") != "0c3fee959576d0a1faec9ceecffb4b132a65558b" or
            campaign.get("capture") is not True or
            campaign.get("full") is not False or
            campaign.get("warmup_frames_requested") != 1000 or
            campaign.get("a8_visual_evidence_requested") is not True or
            campaign.get("mesh_block_voxels") != 16 or
            campaign.get("lod_count") != 4 or
            campaign.get("target_speed_mps") != 18 or
            campaign.get("repeats") != 1):
        raise ValueError("Invalid A5 CPU16 baseline or visual-arm provenance")
    if (route.get("schema") != "a7_route_v1" or
            route.get("route") != m["scenario"] or
            route.get("seed") != m["seed"] or
            route.get("capture") is not True or
            route.get("a8_visual_evidence") is not True or
            route.get("warmup_drawn_frames_requested") != 1000 or
            type(route.get("warmup_drawn_frames_observed")) is not int or
            route["warmup_drawn_frames_observed"] < 1000 or
            route.get("screenshots") != 0 or
            route.get("perf_60_full_present_gate") != "NOT_QUALIFIED" or
            route.get("stream_18_pixel_gate") != "NOT_QUALIFIED" or
            route.get("view_130_pixel_depth_gate") != "NOT_QUALIFIED"):
        raise ValueError("Missing 1000-frame GPU route video attestation")
    if (timeline.get("schema") != "a7_video_timeline_v1" or
            timeline.get("source_mode") != "Route" or
            timeline.get("pixel_terrain_correctness_verified") is not False or
            timeline.get("depth_coverage_verified") is not False):
        raise ValueError("Missing independent timeline diagnostics")
    marker = timeline.get("marker", {})
    window = timeline.get("route_movement_window")
    if (not isinstance(window, dict) or
            marker.get("sequence_verified") is not True or
            marker.get("alignment_verified") is not True or
            window.get("frames", 0) < 100 or
            window.get("elapsed_pts_s", 0) < 20 or
            window.get("elapsed_pts_s", 0) > route.get("duration_s",0) + 2 or
            timeline.get("strict_stream_18") != "NOT_QUALIFIED" or
            timeline.get("strict_view_130") != "NOT_QUALIFIED"):
        raise ValueError("No reliable video/route marker correspondence")
    fps = window.get("observed_fps")
    if type(fps) not in (int,float) or not math.isfinite(fps) or fps < 1:
        raise ValueError("Invalid video FPS")
    video = root/"desktop-1080p-60fps.mkv"
    if not video.is_file() or video.stat().st_size < 1_000_000:
        raise ValueError("Missing independently reviewable desktop video")
    # Integrity: compare manifest bytes, hash the source without decoding it.
    if video.stat().st_size != m.get("video_bytes"):
        raise ValueError("Video size differs from original recorder evidence")
    digest=hashlib.sha256()
    with video.open("rb") as fd:
        for block in iter(lambda:fd.read(2**20),b""):
            digest.update(block)
    review = {
        "schema":SCHEMA,
        "baseline":"A5 CPU16 GL Compatibility",
        "route":m["scenario"],"seed":m["seed"],
        "warmup_drawn_frames":route["warmup_drawn_frames_observed"],
        "warmup_elapsed_s":route.get("warmup_observed_s"),
        "route_duration_s":route.get("duration_s"),
        "route_speed_target_mps":18,
        "video_sha256":digest.hexdigest(),
        "video_bytes":video.stat().st_size,
        "route_recording_frame_count":window["frames"],
        "route_recording_duration_s":window["elapsed_pts_s"],
        "route_recording_fps":fps,
        "video_gap_max_ms":window.get("gap_max_ms"),
        "video_gaps_over_33ms":window.get("gaps_over_33ms"),
        "video_duplicate_pts_pairs":window.get("duplicated_pts_pairs"),
        "video_marker_alignment_verified":True,
        "video_marker_residual_p99_ms":marker.get("offset_residual_p99_ms"),
        "recording_cadence_warning":fps < 59 or window.get("gaps_over_33ms",0)>0,
        "visual_review": "REQUIRED_ORIGINAL_VIDEO",
        "terrain_gap_events_verified":False,
        "lod_seams_verified":False,
        "rocks_and_water_publication_verified":False,
        "depth_130m_verified":False,
        "strict_perf_60":"NOT_QUALIFIED",
        "strict_stream_18":"NOT_QUALIFIED",
        "strict_view_130":"NOT_QUALIFIED",
        "strict_edit_100":"NOT_QUALIFIED",
        "automatic_acceptance":False,
        "limitations":[
            "Video/recorder load is excluded from canonical performance comparison",
            "Recorder PTS and marker alignment do not prove each world pixel was actually presented",
            "Without independently recorded depth, 130m world coverage cannot be certified",
            "One 30s turning route with one seed cannot certify all trajectories and scenes",
            "Requires direct review of original 1920x1080 video for terrain/rock/water flicker and visible seams"
        ]
    }
    out=root/"a8_visual_review.json"
    if out.exists():
        raise FileExistsError("Refuse to overwrite visual review")
    out.write_text(json.dumps(review,ensure_ascii=False,indent=2),encoding="utf-8")
    return review


def main() -> None:
    ap=argparse.ArgumentParser()
    ap.add_argument("folder",type=Path)
    args=ap.parse_args()
    d=report(args.folder)
    print("A8_VISUAL_REVIEW_PREPARED " + json.dumps({
        "route":d["route"],"warmup_frames":d["warmup_drawn_frames"],
        "route_recording_fps":d["route_recording_fps"],
        "review":d["visual_review"],
        "stream_18":d["strict_stream_18"],"view_130":d["strict_view_130"]}))


if __name__=="__main__":
    main()
