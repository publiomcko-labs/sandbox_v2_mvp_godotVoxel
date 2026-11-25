"""A0 static preflight: detects missing files and drift before expensive builds."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
lock = json.loads((root / "third_party.lock").read_text(encoding="utf-8"))
assert lock["godot"]["version"] == "4.7.2-stable"
assert lock["godot"]["voxel_tools_version"] == "v1.7"
assert len(lock["godot"]["editor_windows"]["sha256"]) == 64
assert len(lock["godot_cpp"]["commit"]) == 40
assert lock["godot_cpp"]["version"] == "10.0.0-stable"
required = [
    "native/SConstruct",
    "native/src/world_bootstrap.hpp",
    "native/src/world_bootstrap.cpp",
    "native/src/register_types.cpp",
    "godot/project.godot",
    "godot/sandbox_native.gdextension",
    "godot/scenes/main.tscn",
    "godot/tests/smoke.gd",
    "scripts/bootstrap-windows.ps1",
    "scripts/smoke-windows.ps1",
]
for p in required:
    assert (root / p).is_file(), f"Missing: {p}"
scene = (root / "godot/scenes/main.tscn").read_text(encoding="utf-8")
assert 'type="VoxelLodTerrain"' in scene
assert 'type="VoxelViewer"' in scene
assert 'type="WorldBootstrap"' in scene
extension = (root / "godot/sandbox_native.gdextension").read_text(encoding="utf-8")
assert "sandbox_library_init" in extension
assert "sandbox_native.windows.template_debug.x86_64.dll" in extension
print("A0_STATIC_PASS")
