#!/usr/bin/env python3
"""Summarize independent A7.4 GPU captures without qualifying correct pixels."""
from __future__ import annotations

import argparse
import csv
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path

SCHEMA = "a74_batch_report_v1"
SCENARIOS = ("static_remove", "static_add", "boundary_remove", "boundary_add")


def load(path: Path) -> dict:
    obj = json.loads(path.read_text(encoding="utf-8-sig"))
    if not isinstance(obj, dict):
        raise ValueError("Expected JSON object")
    return obj


def number(obj: object) -> float | None:
    if isinstance(obj, bool) or not isinstance(obj, (int, float)) or not math.isfinite(obj):
        return None
    return float(obj)


def stats(values: list[float]) -> dict:
    if not values:
        return {"n": 0, "mean": None, "median": None, "p95": None,
                "stddev_sample": None, "min": None, "max": None}
    ordered = sorted(values)
    return {
        "n": len(ordered),
        "mean": round(statistics.mean(ordered), 3),
        "median": round(statistics.median(ordered), 3),
        "p95": round(ordered[math.ceil(.95 * len(ordered))-1], 3),
        "stddev_sample": round(statistics.stdev(ordered), 3) if len(ordered)>1 else None,
        "min": round(ordered[0], 3), "max": round(ordered[-1], 3),
    }


def safe_dir(root: Path, relative: object) -> Path:
    if not isinstance(relative, str) or not relative or Path(relative).is_absolute():
        raise ValueError("Relative trial path required")
    candidate = (root / relative).resolve()
    if not candidate.is_relative_to(root.resolve()):
        raise ValueError("Trial path outside batch directory")
    return candidate


def inspect_trial(root: Path, row: dict) -> dict:
    scenario, repeat, seed = row.get("scenario"), row.get("repeat"), row.get("seed")
    if scenario not in SCENARIOS or type(repeat) is not int or repeat < 1 or type(seed) is not int:
        raise ValueError("Bad scenario/repeat/seed in batch manifest")
    result = {
        "scenario": scenario, "seed": seed, "repeat": repeat,
        "relative_path": row.get("relative_path"),
        "runner_exit_code": row.get("runner_exit_code"),
        "acquisition": "INVALID", "failure_reason": None,
        "visual_diagnostic": None, "native_apply_ms": None,
        "candidate_video_latency_ms": None, "video_timing_valid": False,
        "visual_signal_without_timing": False, "mean_expected_luma": None,
        "mean_control_luma": None, "expected_rays": None, "control_rays": None,
        "edit_100_gate": "NOT_QUALIFIED",
    }
    try:
        trial = safe_dir(root, row.get("relative_path"))
        capture = load(trial / "a74_capture_manifest.json")
        edit = load(trial / "a74_result.json")
        review = load(trial / "a74_pilot_review.json")
        if row.get("runner_exit_code") != 0:
            raise ValueError("Runner failed")
        if (capture.get("schema") != "a74_capture_manifest_v1" or
                capture.get("scenario") != scenario or capture.get("seed") != seed or
                capture.get("game_exit_code") != 0 or capture.get("ffmpeg_exit_code") != 0 or
                capture.get("foreground_ok") is not True or
                capture.get("video_container_valid") is not True):
            raise ValueError("Invalid capture provenance")
        if (edit.get("schema") != "a74_pilot_result_v1" or
                edit.get("scenario") != scenario or edit.get("accepted_count") != 1 or
                edit.get("edit_100_gate") != "NOT_QUALIFIED" or
                edit.get("first_correct_presented_pixel_ms") is not None):
            raise ValueError("Invalid single-edit result")
        if (review.get("schema") != "a74_geometry_video_pilot_v1" or
                review.get("scenario") != scenario or
                review.get("automatic_acceptance") is not False or
                review.get("edit_100_gate") != "NOT_QUALIFIED" or
                review.get("first_correct_presented_pixel_ms") is not None or
                review.get("input_kind") != "SCRIPTED_BRUSH_NOT_HID"):
            raise ValueError("Invalid independent review contract")
        ms = number(edit.get("native_apply_ms"))
        if ms is None or ms < 0:
            raise ValueError("Missing or nonfinite native apply duration")
        observation = review.get("observations")
        if not isinstance(observation, dict):
            raise ValueError("Missing frame diagnostics")
        if review.get("pilot_status") != observation.get("status"):
            raise ValueError("Inconsistent diagnostic status")
        status = observation.get("status")
        if status not in (
                "ORACLE_CONSISTENT_LUMA_CANDIDATE", "NO_CONSISTENT_LUMA_SIGNAL",
                "INSUFFICIENT_INDEPENDENT_RAYS", "TIMING_AMBIGUOUS"):
            raise ValueError("Unrecognized diagnostic status")
        invalid_pts = observation.get("edit_window_invalid_pts")
        if type(invalid_pts) is not bool:
            raise ValueError("Missing edit-window PTS validation")
        if (status == "TIMING_AMBIGUOUS") != invalid_pts:
            raise ValueError("Contradictory edit-window timing classification")
        candidate = number(observation.get("first_oracle_consistent_candidate_ms"))
        if status == "ORACLE_CONSISTENT_LUMA_CANDIDATE" and candidate is None:
            raise ValueError("Visual candidate without approximate time")
        if status != "ORACLE_CONSISTENT_LUMA_CANDIDATE" and candidate is not None:
            raise ValueError("Candidate timing not permitted for ambiguous/no-signal runs")
        frames = observation.get("frames_reviewed", [])
        if not isinstance(frames, list) or any(not isinstance(f, dict) for f in frames):
            raise ValueError("Invalid frame diagnostics")
        visible_without_time = (status == "TIMING_AMBIGUOUS" and
                                any(f.get("oracle_consistent_luma_candidate") is True
                                    for f in frames))
        strongest = max(frames, key=lambda f: float(f.get("predicted_mean_abs_luma") or 0.0),
                        default={})
        result.update(
            acquisition="VALID_DIAGNOSTIC_ONLY",
            visual_diagnostic=status,
            native_apply_ms=ms,
            video_timing_valid=not invalid_pts,
            visual_signal_without_timing=visible_without_time,
            candidate_video_latency_ms=candidate,
            mean_expected_luma=number(strongest.get("predicted_mean_abs_luma")),
            mean_control_luma=number(strongest.get("control_mean_abs_luma")),
            expected_rays=observation.get("expected_changed_rays"),
            control_rays=observation.get("control_rays"),
        )
    except (OSError, ValueError, TypeError, KeyError) as e:
        result["failure_reason"] = str(e)
    return result


def summarize(root: Path) -> dict:
    manifest = load(root / "a74_batch_manifest.json")
    entries = manifest.get("trials")
    if manifest.get("schema") != "a74_batch_manifest_v1" or not isinstance(entries, list) or not entries:
        raise ValueError("Invalid batch manifest")
    checked = [inspect_trial(root, trial) for trial in entries]
    groups = defaultdict(list)
    for trial in checked:
        groups[trial["scenario"]].append(trial)
    scenarios = {}
    for scenario, rows in groups.items():
        valid = [r for r in rows if r["acquisition"] == "VALID_DIAGNOSTIC_ONLY"]
        candidates = [r["candidate_video_latency_ms"] for r in valid
                      if r["candidate_video_latency_ms"] is not None]
        counts = {kind: sum(r["visual_diagnostic"] == kind for r in valid)
                  for kind in ("ORACLE_CONSISTENT_LUMA_CANDIDATE",
                               "NO_CONSISTENT_LUMA_SIGNAL",
                               "INSUFFICIENT_INDEPENDENT_RAYS", "TIMING_AMBIGUOUS")}
        scenarios[scenario] = {
            "requested": len(rows), "valid_diagnostic_runs": len(valid),
            "invalid_runs": len(rows)-len(valid),
            "visual_candidates": counts["ORACLE_CONSISTENT_LUMA_CANDIDATE"],
            "visual_no_signal": counts["NO_CONSISTENT_LUMA_SIGNAL"],
            "insufficient_geometry_rays": counts["INSUFFICIENT_INDEPENDENT_RAYS"],
            "timing_ambiguous": counts["TIMING_AMBIGUOUS"],
            "visual_signal_without_usable_timing": sum(
                r["visual_signal_without_timing"] for r in valid),
            "valid_video_timing_runs": sum(r["video_timing_valid"] for r in valid),
            "candidate_rate_among_valid": round(
                counts["ORACLE_CONSISTENT_LUMA_CANDIDATE"]/len(valid),3) if valid else None,
            "native_apply_ms": stats([r["native_apply_ms"] for r in valid]),
            "video_candidate_ms": stats(candidates),
            "max_expected_mean_abs_luma": stats([
                r["mean_expected_luma"] for r in valid if r["mean_expected_luma"] is not None]),
            "max_control_mean_abs_luma": stats([
                r["mean_control_luma"] for r in valid if r["mean_control_luma"] is not None]),
            "edit_100_gate": "NOT_QUALIFIED",
        }
    complete = sum(r["acquisition"] == "VALID_DIAGNOSTIC_ONLY" for r in checked)
    report = {
        "schema": SCHEMA, "batch_id": manifest.get("batch_id"),
        "requested_runs": len(checked), "valid_diagnostic_runs": complete,
        "invalid_runs": len(checked)-complete,
        "collection_complete": bool(
            manifest.get("collection_complete") and complete == len(checked) and
            len(checked) == manifest.get("expected_runs")),
        "video_timing_ambiguous_runs": sum(
            r["visual_diagnostic"] == "TIMING_AMBIGUOUS" for r in checked),
        "sampling_policy": manifest.get("sampling_policy"),
        "scenarios": scenarios, "trials": checked,
        "automatic_acceptance": False, "edit_100_gate": "NOT_QUALIFIED",
        "perf_60_gate": "NOT_QUALIFIED", "stream_18_gate": "NOT_QUALIFIED",
        "view_130_gate": "NOT_QUALIFIED",
        "first_correct_presented_pixel_ms": None,
        "limitations": [
            "Three independent captures are diagnostic, not a population confidence interval",
            "Scripted brush invocation is not raw HID input",
            "Video timestamp candidates do not certify the first correct presented pixel",
            "The CSG oracle is based on the Godot pre-edit SDF",
            "Timing-ambiguous frames retain valid native brush duration but no video latency estimate",
            "Candidate-only timing averages exclude missing/no-signal runs; never impute zero",
            "NVENC recordings are excluded from the canonical PERF-60 benchmark",
        ]
    }
    (root/"a74_batch_report.json").write_text(
        json.dumps(report,indent=2,ensure_ascii=False),encoding="utf-8")
    fields = ("scenario","seed","repeat","relative_path","runner_exit_code",
              "acquisition","failure_reason","visual_diagnostic","native_apply_ms",
              "candidate_video_latency_ms","video_timing_valid","visual_signal_without_timing",
              "mean_expected_luma","mean_control_luma",
              "expected_rays","control_rays","edit_100_gate")
    with (root/"a74_batch_trials.csv").open("w",encoding="utf-8-sig",newline="") as f:
        writer=csv.DictWriter(f,fieldnames=fields)
        writer.writeheader()
        writer.writerows({k:row.get(k) for k in fields} for row in checked)
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("batch_dir",type=Path)
    args=parser.parse_args()
    r=summarize(args.batch_dir)
    print("A74_BATCH_REPORT "+json.dumps({
        "requested":r["requested_runs"],"valid":r["valid_diagnostic_runs"],
        "complete":r["collection_complete"],
        "scenarios":{k:{"visual_candidates":v["visual_candidates"],
                        "valid":v["valid_diagnostic_runs"],
                        "native_apply_ms":v["native_apply_ms"]}
                     for k,v in r["scenarios"].items()},
        "strict":r["edit_100_gate"]
    },ensure_ascii=False))
    if not r["collection_complete"]:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
