"""A2 static contract guards; runtime correctness also requires CI GDScript tests."""
from pathlib import Path
import hashlib
root = Path(__file__).resolve().parents[1]
for rel in ("godot/tests/a2_routes.gd", "godot/tests/a2_runtime.gd",
            "godot/tests/a2_benchmark.gd", "godot/tests/a2_smoke.gd",
            "scripts/a2-benchmark-windows.ps1", "scripts/a2-smoke-windows.ps1"):
    assert (root / rel).is_file(), rel
routes = (root / "godot/tests/a2_routes.gd").read_text(encoding="utf-8")
runtime = (root / "godot/tests/a2_runtime.gd").read_text(encoding="utf-8")
for name in ("stationary_180s","straight_18mps_600s","turns_18mps_300s",
             "out_and_back_18mps_300s"):
    assert name in routes, name
assert "SPEED_MPS := 18.0" in routes
assert "Time.get_ticks_usec()" in runtime
assert 'get_statistics()' in runtime and "debug_get_mesh_block_count()" in runtime
assert "is_area_meshed" in runtime
assert "Performance.TIME_PROCESS" in runtime
assert "frame_interval_ms_p99" in runtime and "frame_interval_ms_p999" in runtime
assert '"NOT_QUALIFIED"' in runtime
assert "A2_OUTPUT_DIR" in runtime
assert "VoxelLodTerrain" in (root / "godot/scenes/main.tscn").read_text(encoding="utf-8")
print("A2_STATIC_PASS")

# Enforce exact snapshot parity only for the A2 workflow that restores the
# corresponding prebuilt native DLL. A3 explicitly recompiles C++ and is not
# allowed to re-use the A1 snapshot.
import os
if os.environ.get("A2_REUSE_SNAPSHOT", "1") == "1":
    # A2 reuses a specific successful A1 native DLL. Fail closed if ANY native
    # source changes, so the reused binary cannot silently drift from source.
    a1_native_blobs = {
        "native/SConstruct": "1d17454e664e2f5f2b11aca89b764a4db3f95638",
        "native/src/register_types.cpp": "1c33b0a691652aa91ec97c018ec2aceacc91f60a",
        "native/src/world_bootstrap.cpp": "842ea913c6ed700967fc79c0b137f751d3e17cae",
        "native/src/world_bootstrap.hpp": "6dc4f47883286ce05df0eeb7217053161e27a32b",
    }
    current_native_files = {p.relative_to(root).as_posix() for p in (root / "native").rglob("*")
                            if p.is_file() and not p.name.startswith(".")}
    # Exclude generated/native build intermediates if present; only tracked
    # C++ files are under native/src and SConstruct.
    tracked_cpp = {p for p in current_native_files if
                   p == "native/SConstruct" or p.startswith("native/src/")}
    assert tracked_cpp == set(a1_native_blobs), f"Native source set changed: {tracked_cpp}"
    for name, expected_blob in a1_native_blobs.items():
        # Windows checkout may materialize CRLF; compare the normalized
        # repository text, not platform-specific working-tree line endings.
        content = (root / name).read_bytes().replace(b"\r\n", b"\n")
        blob = hashlib.sha1(b"blob " + str(len(content)).encode("ascii") + b"\0" + content).hexdigest()
        assert blob == expected_blob, f"A2 native drift: {name}"
    print("A2_NATIVE_A1_SNAPSHOT_PARITY_PASS")

else:
    print("A2_NATIVE_SNAPSHOT_NOT_USED: native compilation required by A3")
