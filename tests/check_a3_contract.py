"""A3 preflight: code, persistence and tests may not silently disappear."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
required=[
    "godot/scripts/a3_edit_controller.gd",
    "godot/tests/a3_persistence.gd",
    "scripts/a3-smoke-windows.ps1",
    "docs/A3_IMPLEMENTACAO.md",
]
for name in required:
    assert (root / name).is_file(), name
native=(root/"native/src/world_bootstrap.cpp").read_text(encoding="utf-8")
header=(root/"native/src/world_bootstrap.hpp").read_text(encoding="utf-8")
terrain=(root/"godot/scripts/terrain_sdf.gd").read_text(encoding="utf-8")
scene=(root/"godot/scenes/main.tscn").read_text(encoding="utf-8")
controller=(root/"godot/scripts/a3_edit_controller.gd").read_text(encoding="utf-8")
for text in ["can_edit_sphere", "edit_sphere", "is_area_editable", "do_sphere",
             "MODE_ADD", "MODE_REMOVE", "get_last_edit_apply_ms"]:
    assert text in native and text in native+header, text
assert "VoxelStreamSQLite.new()" in terrain
assert 'sqlite.save_generator_output = false' in terrain
assert 'A3_SAVE_PATH' in terrain and "stream = sqlite" in terrain
assert "save_modified_blocks()" in controller
assert "collision_lod_count = 1" in scene
assert "generate_collisions = true" in scene and "requires_collisions = true" in scene
assert "a3_edit_controller.gd" in scene
assert "A2_NATIVE_SNAPSHOT_NOT_USED" in (root/"tests/check_a2_contract.py").read_text(encoding="utf-8")
print("A3_STATIC_PASS")
