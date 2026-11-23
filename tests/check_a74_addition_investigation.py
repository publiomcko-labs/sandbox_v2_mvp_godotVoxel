"""A7.4-P1e advisory addition signature: positive and negative CPU-only tests."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location(
    "a74_addition_investigation", root / "scripts/a74_addition_investigation.py")
assert spec is not None and spec.loader is not None
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


def example(hit: float, control: float, coverage: float, false_coverage: float) -> dict:
    frames = []
    for i in range(7):
        frames.append({
            "frame": 100+i,
            "predicted_mean_abs_luma": hit if i >= 2 else 0.,
            "control_mean_abs_luma": control if i >= 2 else 0.,
            "predicted_change_low_contrast_ratio": coverage if i >= 2 else 0.,
            "control_low_contrast_ratio": false_coverage if i >= 2 else 0.,
        })
    return {
        "status": "NO_CONSISTENT_LUMA_SIGNAL",
        "edit_window_invalid_pts": False,
        "expected_changed_rays": 34,
        "control_rays": 87,
        "frames_reviewed": frames,
    }


static = example(1.706, 0.172, 0.147, 0)
boundary = example(3.862, 0.652, 0.621, 0.043)
assert audit.weak_signature(static)["signature"] == "REPEATABLE_WEAK_LOCALIZED_LUMA"
assert audit.weak_signature(boundary)["signature"] == "REPEATABLE_WEAK_LOCALIZED_LUMA"
assert audit.weak_signature(static)["first_post_marker_delta_frames"] == 2

# Global lighting, transient noise, baseline instability, and clock ambiguity
# must all be rejected (not treated as expected terrain geometry).
assert audit.weak_signature(example(3., 3., 0.6, 0.6))["signature"] == "WEAK_SIGNAL_NOT_ESTABLISHED"
transient = json.loads(json.dumps(static))
for frame in transient["frames_reviewed"][3:]:
    frame["predicted_mean_abs_luma"] = 0
assert audit.weak_signature(transient)["signature"] == "WEAK_SIGNAL_NOT_ESTABLISHED"
preexisting = json.loads(json.dumps(static))
preexisting["frames_reviewed"][0]["predicted_mean_abs_luma"] = 3
assert audit.weak_signature(preexisting)["signature"] == "WEAK_SIGNAL_NOT_ESTABLISHED"
bad_pts = json.loads(json.dumps(static))
bad_pts["edit_window_invalid_pts"] = True
assert audit.weak_signature(bad_pts)["signature"] == "NOT_EVALUABLE"
bad_status = json.loads(json.dumps(static))
bad_status["status"] = "TIMING_AMBIGUOUS"
assert audit.weak_signature(bad_status)["signature"] == "NOT_EVALUABLE"
sparse = json.loads(json.dumps(static))
sparse["expected_changed_rays"] = 7
assert audit.weak_signature(sparse)["signature"] == "NOT_EVALUABLE"

# Strict acceptance is hardwired off; never repurpose a post-hoc threshold
# for EDIT-100 certification or independent correct-depth verification.
source = (root / "scripts/a74_addition_investigation.py").read_text(encoding="utf-8")
assert '"post_hoc_exploratory": True' in source
assert '"automatic_acceptance": False' in source
assert '"first_correct_presented_pixel_ms": None' in source
assert '"edit_100_gate": "NOT_QUALIFIED"' in source
print("A74_ADDITION_WEAK_LUMA_DIAGNOSTIC_PASS")
