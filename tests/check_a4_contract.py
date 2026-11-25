"""A4 contract, pinned native API compatibility and batch/physics guards."""
from pathlib import Path
import hashlib
root=Path(__file__).resolve().parents[1]
paths=[
    "godot/scripts/a4_rocks_instancer.gd","godot/scripts/a4_rock_manager.gd",
    "godot/scripts/a4_rock_body.gd","godot/scenes/rock_body.tscn",
    "godot/scripts/a4_rock_item.gd",
    "godot/tests/a4_physics.gd","godot/tests/a4_smoke.gd",
    "scripts/a4-smoke-windows.ps1","docs/A4_IMPLEMENTACAO.md",
]
for name in paths:
    assert (root/name).is_file(), name
a=(root/"godot/scripts/a4_rocks_instancer.gd").read_text(encoding="utf-8")
m=(root/"godot/scripts/a4_rock_manager.gd").read_text(encoding="utf-8")
s=(root/"godot/scenes/main.tscn").read_text(encoding="utf-8")
assert "extends VoxelInstancer" in a
assert "var item := RockItem.new()" in a
assert "extends VoxelInstanceLibraryMultiMeshItem" in (root/"godot/scripts/a4_rock_item.gd").read_text(encoding="utf-8")
assert "VoxelInstanceGenerator.new()" in a
assert "item.persistent = true" in a
assert "REMOVAL_BEHAVIOR_CALLBACK" in a
assert "a4_rock_item.gd" in a
assert "item.lod_index = 2" in a
assert "remove_instances_in_sphere" in m
assert "spawn_promoted" in m
assert "MAX_ACTIVE_BODIES := 24" in m
assert "A4_ROCK_STATE_PATH" in m and "save_states()" in m and "_restore_states()" in m
assert 'parent="Terrain"' in s and 'type="VoxelInstancer"' in s
assert "VoxelLodTerrain" in s and "generate_collisions = true" in s
# The A4 tree contains no C++ changes: require exact A3 native tree hashes
# before reusing A3's compiled binary in the Windows Actions job.
a3 = {
    "native/SConstruct":"1d17454e664e2f5f2b11aca89b764a4db3f95638",
    "native/src/register_types.cpp":"1c33b0a691652aa91ec97c018ec2aceacc91f60a",
    "native/src/world_bootstrap.cpp":"66b67bb1c19a727469b20fcf74caed536f24d46e",
    "native/src/world_bootstrap.hpp":"14121beb194f672769ef9651a622650d9d50618f",
}
native_files={p.relative_to(root).as_posix() for p in (root/"native").rglob("*")
              if p.is_file() and (p.name=="SConstruct" or p.suffix in {".cpp",".hpp",".h"})}
assert native_files==set(a3), f"Unexpected native sources: {native_files}"
for name,sha in a3.items():
    data=(root/name).read_bytes().replace(b"\r\n",b"\n")
    gitblob=hashlib.sha1(b"blob "+str(len(data)).encode("ascii")+b"\0"+data).hexdigest()
    assert gitblob==sha, f"Native ABI drift: {name}"
print("A4_STATIC_AND_A3_ABI_PARITY_PASS")
