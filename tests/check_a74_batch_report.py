"""A7.4 batch regression: statistics, omissions and strict fail-closed provenance."""
from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root/"scripts"))
import a74_batch_report as batch


def save(path: Path, obj: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj), encoding="utf-8")


with tempfile.TemporaryDirectory() as tmp:
    folder = Path(tmp)
    trials = []
    values = [4.0, 6.0, 8.0]
    for i, duration in enumerate(values, 1):
        rel = f"static_add/seed-20261119/run-{i:02d}"
        trial = folder/rel
        trials.append({"scenario":"static_add","repeat":i,"seed":20261119,
                       "relative_path":rel,"runner_exit_code":0})
        save(trial/"a74_capture_manifest.json",{
            "schema":"a74_capture_manifest_v1", "scenario":"static_add",
            "seed":20261119, "game_exit_code":0,"ffmpeg_exit_code":0,
            "foreground_ok":True,"video_container_valid":True})
        save(trial/"a74_result.json",{
            "schema":"a74_pilot_result_v1","scenario":"static_add",
            "accepted_count":1,"native_apply_ms":duration,
            "edit_100_gate":"NOT_QUALIFIED","first_correct_presented_pixel_ms":None})
        status = "ORACLE_CONSISTENT_LUMA_CANDIDATE" if i < 3 else "NO_CONSISTENT_LUMA_SIGNAL"
        save(trial/"a74_pilot_review.json",{
            "schema":"a74_geometry_video_pilot_v1", "scenario":"static_add",
            "automatic_acceptance":False,"edit_100_gate":"NOT_QUALIFIED",
            "first_correct_presented_pixel_ms":None,"input_kind":"SCRIPTED_BRUSH_NOT_HID",
            "pilot_status":status,
            "observations":{
                "status":status,"edit_window_invalid_pts":False,
                "first_oracle_consistent_candidate_ms":20.0+i if i < 3 else None,
                "expected_changed_rays":30,"control_rays":90,
                "frames_reviewed":[{"predicted_mean_abs_luma":10.0,
                                    "control_mean_abs_luma":2.0}]}})
    manifest = {"schema":"a74_batch_manifest_v1","batch_id":"fixture",
                "collection_complete":True,"expected_runs":3,
                "sampling_policy":"fixed seed, independent repeat",
                "trials":trials}
    save(folder/"a74_batch_manifest.json",manifest)
    result = batch.summarize(folder)
    a = result["scenarios"]["static_add"]
    assert result["collection_complete"] and result["invalid_runs"] == 0
    assert a["visual_candidates"] == 2 and a["visual_no_signal"] == 1
    assert a["native_apply_ms"]["mean"] == 6.0
    assert a["native_apply_ms"]["median"] == 6.0
    assert a["native_apply_ms"]["p95"] == 8.0
    assert a["native_apply_ms"]["max"] == 8.0
    assert a["native_apply_ms"]["stddev_sample"] == 2.0
    assert a["video_candidate_ms"]["n"] == 2
    assert a["video_candidate_ms"]["mean"] == 21.5
    assert result["edit_100_gate"] == "NOT_QUALIFIED"
    assert result["automatic_acceptance"] is False
    assert result["first_correct_presented_pixel_ms"] is None
    assert (folder/"a74_batch_trials.csv").is_file()
    # A succeeded process with no pixel signal remains VALID for the batch;
    # it is not falsely converted into candidate success or a zero latency.
    save(folder/trials[2]["relative_path"]/"a74_capture_manifest.json", {
        "schema":"a74_capture_manifest_v1","scenario":"static_add",
        "seed":20261119,"game_exit_code":0,"ffmpeg_exit_code":0,
        "foreground_ok":False,"video_container_valid":True})
    negative = batch.summarize(folder)
    assert negative["invalid_runs"] == 1 and not negative["collection_complete"]
    assert negative["scenarios"]["static_add"]["native_apply_ms"]["n"] == 2
    # Malicious traversal must not read arbitrary files outside the campaign.
    assert not batch.inspect_trial(folder,{
        "scenario":"static_add","repeat":4,"seed":20261119,
        "runner_exit_code":0,"relative_path":"../../outside"})["acquisition"] == "VALID_DIAGNOSTIC_ONLY"
    manifest["collection_complete"] = False
    save(folder/"a74_batch_manifest.json",manifest)
    assert batch.summarize(folder)["collection_complete"] is False

print("A74_BATCH_STATISTICS_FAIL_CLOSED_PASS")
