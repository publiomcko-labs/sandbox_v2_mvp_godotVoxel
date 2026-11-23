#!/usr/bin/env python3
"""A7.4-P1e: post-hoc, diagnostic-only audit of existing addition JSON evidence.

Does not modify the original batch, the geometric oracle, or strict acceptance.
Requires the compact ZIP already collected; no GPU, video, FFmpeg or NumPy.
"""
from __future__ import annotations

import argparse
import json
import statistics
import zipfile
from pathlib import Path

SCENARIOS = ("static_add", "boundary_add")
SCHEMA = "a74_addition_investigation_v1"


def weak_signature(observation: dict) -> dict:
    frames = observation.get("frames_reviewed", [])
    if (observation.get("status") != "NO_CONSISTENT_LUMA_SIGNAL" or
            observation.get("edit_window_invalid_pts") is not False or
            len(frames) != 7 or
            observation.get("expected_changed_rays", 0) < 8 or
            observation.get("control_rays", 0) < 8 or
            any(type(f.get("frame")) is not int for f in frames) or
            any(frames[j+1]["frame"] != frames[j]["frame"] + 1 for j in range(6))):
        return {"signature": "NOT_EVALUABLE"}

    def quiet(f):
        return (f.get("predicted_mean_abs_luma", -1) < .25 and
                f.get("control_mean_abs_luma", -1) < .25 and
                f.get("predicted_change_low_contrast_ratio", -1) < .01)

    def localized(f):
        hit = f.get("predicted_mean_abs_luma")
        control = f.get("control_mean_abs_luma")
        hit_cov = f.get("predicted_change_low_contrast_ratio")
        false_cov = f.get("control_low_contrast_ratio")
        if any(type(x) not in (int, float) or x < 0 for x in
               (hit, control, hit_cov, false_cov)):
            return False
        return (hit >= 1.2 and control <= .75 and
                hit >= 5 * max(.1, control) and
                hit_cov >= .12 and false_cov <= .10)

    initial_quiet = all(quiet(f) for f in frames[:2])
    post = [localized(f) for f in frames[2:]]
    yes = initial_quiet and sum(post) >= 4 and all(post[1:4])
    return {
        "signature": "REPEATABLE_WEAK_LOCALIZED_LUMA" if yes else
                     "WEAK_SIGNAL_NOT_ESTABLISHED",
        "quiet_initial_frames": initial_quiet,
        "persistent_post_frames": sum(post),
        "first_post_marker_delta_frames": (
            next((i + 2 for i, detected in enumerate(post) if detected), None)
            if yes else None),
        "max_expected_mean_abs_luma": max(f["predicted_mean_abs_luma"] for f in frames),
        "max_control_mean_abs_luma": max(f["control_mean_abs_luma"] for f in frames),
        "peak_expected_ge4_coverage": max(
            f["predicted_change_low_contrast_ratio"] for f in frames),
        "peak_control_ge4_coverage": max(
            f["control_low_contrast_ratio"] for f in frames),
    }


def analyze(source_zip: Path) -> dict:
    with zipfile.ZipFile(source_zip) as z:
        names = set(z.namelist())
        if "a74_batch_manifest.json" not in names:
            raise ValueError("Missing batch manifest")
        manifest = json.loads(z.read("a74_batch_manifest.json"))
        if (manifest.get("schema") != "a74_batch_manifest_v1" or
                manifest.get("expected_runs") != 12):
            raise ValueError("Wrong source batch schema/run count")
        rows = []
        for entry in manifest["trials"]:
            scenario = entry.get("scenario")
            if scenario not in SCENARIOS:
                continue
            repeat, seed = entry.get("repeat"), entry.get("seed")
            if type(repeat) is not int or type(seed) is not int:
                raise ValueError("Invalid run identity")
            relative = f"{scenario}/seed-{seed}/run-{repeat:02d}"
            if (entry.get("relative_path") != relative or
                    entry.get("runner_exit_code") != 0):
                raise ValueError("Run path/provenance mismatch")

            def read(name):
                target = relative + "/" + name
                if target not in names:
                    raise ValueError(f"Missing source: {target}")
                return json.loads(z.read(target))

            capture = read("a74_capture_manifest.json")
            edit = read("a74_result.json")
            review = read("a74_pilot_review.json")
            if (capture.get("scenario") != scenario or
                    capture.get("seed") != seed or
                    capture.get("foreground_ok") is not True or
                    capture.get("video_container_valid") is not True or
                    capture.get("game_exit_code") != 0 or
                    capture.get("ffmpeg_exit_code") != 0 or
                    edit.get("scenario") != scenario or
                    edit.get("accepted_count") != 1 or
                    review.get("schema") != "a74_geometry_video_pilot_v1" or
                    review.get("pilot_status") != review.get("observations", {}).get("status") or
                    review.get("first_correct_presented_pixel_ms") is not None or
                    review.get("edit_100_gate") != "NOT_QUALIFIED" or
                    review.get("automatic_acceptance") is not False):
                raise ValueError("Invalid evidence or strict qualification fields")
            rows.append({
                "scenario": scenario, "seed": seed, "repeat": repeat,
                "original_status": review["pilot_status"],
                "native_apply_ms": edit["native_apply_ms"],
                **weak_signature(review["observations"])
            })
    if len(rows) != 6 or len({(r["scenario"], r["repeat"]) for r in rows}) != 6:
        raise ValueError("Six distinct addition trials are required")
    grouped = {}
    for scenario in SCENARIOS:
        subset = [r for r in rows if r["scenario"] == scenario]
        grouped[scenario] = {
            "runs": len(subset),
            "weak_luma_signatures": sum(
                r["signature"] == "REPEATABLE_WEAK_LOCALIZED_LUMA" for r in subset),
            "old_detector_candidates": sum(
                r["original_status"] == "ORACLE_CONSISTENT_LUMA_CANDIDATE"
                for r in subset),
            "native_apply_mean_ms": round(
                statistics.mean(r["native_apply_ms"] for r in subset), 3),
            "max_expected_mean_abs_luma": round(
                statistics.mean(r.get("max_expected_mean_abs_luma", 0) for r in subset), 3),
            "max_control_mean_abs_luma": round(
                statistics.mean(r.get("max_control_mean_abs_luma", 0) for r in subset), 3),
        }
    return {
        "schema": SCHEMA,
        "source_zip": source_zip.name,
        "scenarios": grouped,
        "trials": rows,
        "post_hoc_exploratory": True,
        "original_detector_unchanged": True,
        "automatic_acceptance": False,
        "first_correct_presented_pixel_ms": None,
        "edit_100_gate": "NOT_QUALIFIED",
        "other_gates": "NOT_QUALIFIED",
        "limitations": [
            "Thresholds are post-hoc exploratory: NOT a preregistered acceptance rule",
            "All six runs use the same seed and camera; do not claim broad generalization",
            "Review JSON has only 7 post-marker frame summaries, not six full videos",
            "Localized luma persistence cannot prove independent correct depth",
            "HID-to-present and ETW-correlated timing are not available",
        ]
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("summary_zip", type=Path)
    p.add_argument("--output", type=Path)
    args = p.parse_args()
    report = analyze(args.summary_zip)
    dest = args.output or args.summary_zip.with_name("a74_addition_investigation.json")
    if dest.exists():
        raise FileExistsError("Refusing to overwrite an existing audit")
    dest.write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")
    print("A74_ADDITION_DIAGNOSTIC_ONLY " + json.dumps(
        report["scenarios"], ensure_ascii=False))


if __name__ == "__main__":
    main()
