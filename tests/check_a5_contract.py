"""A5 static contracts; native ABI parity remains checked by A4."""
from pathlib import Path
r = Path(__file__).resolve().parents[1]
for file in ("godot/scripts/a5_water.gd","godot/assets/shaders/a5_water.gdshader",
             "godot/tests/a5_water_physics.gd","godot/tests/a5_shoreline.gd",
             "scripts/a5-smoke-windows.ps1","docs/A5_IMPLEMENTACAO.md"):
    assert (r/file).is_file(), file
water = (r/"godot/scripts/a5_water.gd").read_text(encoding="utf-8")
scene = (r/"godot/scenes/main.tscn").read_text(encoding="utf-8")
motion = (r/"godot/scripts/viewer_motion.gd").read_text(encoding="utf-8")
rock = (r/"godot/scripts/a4_rock_body.gd").read_text(encoding="utf-8")
for token in ("PlaneMesh.new()", "Area3D.new()", "SURFACE_Y := 0.0",
              "OCEAN_SIZE_M := 640.0", "get_overlapping_bodies()",
              "submerged_sphere_fraction", "buoyancy_newtons", "apply_central_force",
              "MAX_ACTIVE_WET_BODIES := 24", "RIVER_FLOW_MPS := 2.2"):
    assert token in water, token
assert 'name="Water" type="Node3D"' in scene
assert 'name="Player" type="CharacterBody3D"' in scene
assert 'name="CollisionShape3D" type="CollisionShape3D" parent="Player"' in scene
assert 'extends CharacterBody3D' in motion and 'SPEED_MPS := 18.0' in motion
assert "KEY_G" in motion and "move_and_slide()" in motion
assert "a5_displaced_volume_m3" in rock
assert "mass = 3600.0" in (r/"godot/scenes/rock_body.tscn").read_text(encoding="utf-8")
assert "view_distance = 192" in scene and "VoxelLodTerrain" in scene
assert "VoxelInstanceLibraryMultiMeshItem" in (r/"godot/scripts/a4_rock_item.gd").read_text(encoding="utf-8")
print("A5_STATIC_PASS")
