"""A1 cheap static check; definitive runtime graph check uses Voxel Tools."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
script=(root/"godot/scripts/terrain_sdf.gd").read_text(encoding="utf-8")
scene=(root/"godot/scenes/main.tscn").read_text(encoding="utf-8")
assert "VoxelGeneratorGraph.new()" in script
assert "ZN_FastNoiseLite.new()" in script
assert "NODE_OUTPUT_SDF" in script and "NODE_MAX" in script
assert "seed_value" in script and "result.compile()" in script
assert "VoxelGeneratorFlat" not in scene
assert 'res://scripts/terrain_sdf.gd' in scene
assert "view_distance = 192" in scene
assert "lod_count = 4" in scene
assert "mesh_block_size = 16" in scene
assert "SPEED_MPS := 18.0" in (root/"godot/scripts/viewer_motion.gd").read_text(encoding="utf-8")
print("A1_STATIC_PASS")
