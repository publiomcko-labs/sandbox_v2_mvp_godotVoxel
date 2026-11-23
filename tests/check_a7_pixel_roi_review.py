"""A7.3 CPU-only unit tests: a video-localized change is NOT correct pixels."""
from __future__ import annotations
import importlib.util
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "scripts"))
spec = importlib.util.spec_from_file_location("a7_pixel_roi_review",
                                             root / "scripts/a7_pixel_roi_review.py")
assert spec and spec.loader
pixel = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pixel)

SIDE = pixel.SIDE
base = bytes([90]) * (SIDE*SIDE)
empty = pixel.compare_pixels(base, base)
assert not empty["localized_candidate"]
assert not empty["ambiguous_scene_motion"]

changed = bytearray(base)
for y in range(42, 78):
    for x in range(42, 78):
        changed[y*SIDE+x] = 140
local = pixel.compare_pixels(base, bytes(changed))
assert local["localized_candidate"] and not local["ambiguous_scene_motion"], local
assert local["inner_changed_pixels"] > 20

global_change = pixel.compare_pixels(base, bytes([130]) * (SIDE*SIDE))
assert not global_change["localized_candidate"]
assert global_change["ambiguous_scene_motion"], global_change

crosshair = bytearray(base)
for y in range(58, 63):
    for x in range(58, 63):
        crosshair[y*SIDE+x] = 240
assert not pixel.compare_pixels(base, crosshair)["localized_candidate"]

# One distinct after-marker frame. The output must retain an unqualified
# first-correct-terrain-pixel even if the ROI candidate is obvious.
patches = base + base + bytes(changed) + bytes(changed) + base + base
pts = [i*.016 for i in range(6)]
row = pixel.classify_edit(patches, pts, 1, 5, 1000.01, 1000.0)
assert row["status"] == "LOCAL_CHANGE_CANDIDATE", row
assert row["first_candidate_frame"] == 2, row
assert row["first_candidate_recorded_pixel_ms"] == 22.0, row
assert row["first_correct_presented_pixel_ms"] is None
assert pixel.classify_edit(patches, pts, 0, 5, 1000.0, 1000.0)["status"] == "UNUSABLE_MARKER_INDEX"
no_change = pixel.classify_edit(base*6, pts, 1, 5, 1000.0, 1000.0)
assert no_change["status"] == "NO_LOCAL_CHANGE_DETECTED"
ambiguous = pixel.classify_edit(base + base + bytes([130])*(SIDE*SIDE)*4,
                                 pts, 1, 5, 1000.0, 1000.0)
assert ambiguous["status"] == "AMBIGUOUS_SCENE_MOTION"
src = (root / "scripts/a7_pixel_roi_review.py").read_text(encoding="utf-8")
assert '"automatic_acceptance": False' in src
assert '"edit_100_gate": "NOT_QUALIFIED"' in src
assert '"first_correct_presented_pixel_ms": None' in src
assert '"first_correct_presented_pixel_verified_count": 0' in src
assert '"input_kind": "SCRIPTED_BRUSH_NOT_HID"' in src
print("A7_PIXEL_ROI_AUDIT_FAIL_CLOSED_PASS")
