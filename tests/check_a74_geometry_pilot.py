"""A7.4 CPU-only tests: independent analytic CSG, ray depth, and fail-closed gate."""
from __future__ import annotations
import json
import math
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / "scripts"))
import a74_geometry_pilot as p


def fixture(operation: str) -> dict:
    side = 11
    origin = [-5, -5, -5]
    values = [float(y-5) for z in range(side)
              for y in range(side) for x in range(side)]
    rays = []
    for j in range(5):
        for i in range(5):
            x, z = float(i-2), float(j-2)
            rays.append({
                "pixel": [900+i*14, 480+j*14],
                "origin": [x, 5.0, z], "direction": [0.0, -1.0, 0.0]
            })
    return {
        "schema": "a74_preedit_reference_v1",
        "camera_fixed": True, "screen_size": [1920, 1080],
        "brush": {"center": [0.0, -.25 if operation == "remove" else .25, 0.0],
                  "radius_m": 1.5, "operation": operation},
        "baseline": {"side": side, "origin": origin, "values": values,
                     "source": "PRE_EDIT_VOXELTOOL_SDF_LATTICE"},
        "rays": rays
    }


remove = fixture("remove")
add = fixture("add")
p.validate_reference(remove)
p.validate_reference(add)
assert abs(p.sample_sdf(remove, (0.0, .75, 0.0)) - .75) < 1e-9
assert p.expected_sdf(remove, (0.0, -.25, 0.0), False) < 0
assert p.expected_sdf(remove, (0.0, -.25, 0.0), True) > 0
assert p.expected_sdf(add, (0.0, .25, 0.0), False) > 0
assert p.expected_sdf(add, (0.0, .25, 0.0), True) < 0
center = {"origin": [0.0, 5.0, 0.0], "direction": [0.0, -1.0, 0.0]}
pre = p.first_surface_t(remove, center, False)
removed = p.first_surface_t(remove, center, True)
added = p.first_surface_t(add, center, True)
assert pre is not None and removed is not None and added is not None
assert abs(pre-5.0) < .15, pre
assert removed > pre+.25, (pre, removed)
assert added < pre-.25, (pre, added)
controls = {"origin": [4.0, 5.0, 4.0], "direction": [0.0, -1.0, 0.0]}
assert abs(p.first_surface_t(remove, controls, False) -
           p.first_surface_t(remove, controls, True)) < .01
assert sum(r["predicted_changed"] for r in p.reference_rays(remove)) >= 1
assert sum(r["predicted_changed"] for r in p.reference_rays(add)) >= 1
broken = fixture("add")
broken["baseline"]["values"][0] = float("nan")
try:
    p.validate_reference(broken)
    raise AssertionError("Nonfinite SDF accepted")
except ValueError:
    pass
broken = fixture("remove")
broken["rays"][1]["pixel"] = broken["rays"][0]["pixel"]
try:
    p.validate_reference(broken)
    raise AssertionError("Duplicate ray accepted")
except ValueError:
    pass
# Controlled synthetic pixel oracle: false changes in all control rays
# must never masquerade as independently correct geometry.
changed = [{"pixel": [900+i*14, 480], "predicted_changed": True}
           for i in range(9)]
controls = [{"pixel": [900+i*14, 550], "predicted_changed": False}
            for i in range(9)]
n = 22
frames = [bytearray([100]*p.PATCH_BYTES) for _ in range(n)]
for frame in range(12, 19):
    for ray in changed:
        px, py = ray["pixel"]
        x, y = px-840, py-420
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                frames[frame][(y+dy)*p.PATCH_SIDE + x+dx] = 170
blob = b"".join(frames)
pts = [i/60 for i in range(n)]
result = p.evaluate_video(changed+controls, blob, n, 12, pts, 2000.0, 2000.0)
assert result["status"] == "ORACLE_CONSISTENT_LUMA_CANDIDATE", result
assert result["first_correct_presented_pixel_ms"] is None
for frame in range(12, 19):
    for ray in controls:
        x, y = ray["pixel"][0]-840, ray["pixel"][1]-420
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                frames[frame][(y+dy)*p.PATCH_SIDE+x+dx] = 170
ambiguous = p.evaluate_video(changed+controls, b"".join(frames),
                             n, 12, pts, 2000.0, 2000.0)
assert ambiguous["status"] == "NO_CONSISTENT_LUMA_SIGNAL", ambiguous
src = (root / "scripts/a74_geometry_pilot.py").read_text(encoding="utf-8")
assert '"automatic_acceptance": False' in src
assert '"first_correct_presented_pixel_ms": None' in src
assert '"edit_100_gate": "NOT_QUALIFIED"' in src
assert '"etw_present_aligned": False' in src
print("A74_INDEPENDENT_GEOMETRY_PILOT_CPU_PASS")
