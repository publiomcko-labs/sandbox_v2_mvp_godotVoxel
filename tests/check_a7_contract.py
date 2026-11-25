"""A7 contract must remain pinned to A5 and never auto-approve strict gates."""
from pathlib import Path
import importlib.util
import json
import tempfile
root = Path(__file__).resolve().parents[1]
required = [
    "godot/tests/a7_routes.gd","godot/tests/a7_route_runtime.gd",
    "godot/tests/a7_route_runner.gd","godot/tests/a7_edit_runner.gd",
    "scripts/a7-run-windows.ps1","scripts/a7-smoke-windows.ps1",
    "scripts/a7_report.py","docs/A7_IMPLEMENTACAO.md",
]
for path in required:
    assert (root/path).is_file(), path
route=(root/"godot/tests/a7_route_runner.gd").read_text(encoding="utf-8")
runtime=(root/"godot/tests/a7_route_runtime.gd").read_text(encoding="utf-8")
edit=(root/"godot/tests/a7_edit_runner.gd").read_text(encoding="utf-8")
shell=(root/"scripts/a7-run-windows.ps1").read_text(encoding="utf-8")
scene=(root/"godot/scenes/main.tscn").read_text(encoding="utf-8")
assert 'terrain.set("world_seed",seed)' in route
assert "terrain.mesh_block_size!=16" in route and "terrain.use_gpu_generation" in route
assert route.index('terrain.set("world_seed",seed)') < route.index("root.add_child(world)")
assert "gl_compatibility" in route and "opengl3" in route
assert "RenderingServer.viewport_set_measure_render_time" in runtime
assert "frame_start_p99_ms" in runtime and "frame_start_p999_ms" in runtime
assert "viewport_render_gpu_p99_ms" in runtime and "view_130_pixel_depth_gate" in runtime
assert "EDIT_COUNT := 100" in edit and "RATE_S := 0.1" in edit
assert "frame_post_draw" in edit and '"first_correct_presented_pixel_ms":null' in edit
assert '"edit_100_gate":"NOT_QUALIFIED"' in edit
assert "A7_NO_AUTOMATIC_ACCEPTANCE" in shell
assert "VoxelEngine.set_thread_count" in route and "vsync-off" in route
assert "voxel_threads_actual" in runtime and "voxel_workers" in runtime
assert "ResourceTelemetry" in shell and "a7_process_resources.json" in shell
assert (root/"scripts/a7-resources-ab-windows.ps1").is_file()
assert (root/"docs/A7_RECURSOS_AB.md").is_file()
assert "a7_reopen.json" in shell and "A7_REOPEN_FUNCTIONAL_SMOKES_PASS" in shell
assert "Seeds.Count -lt 3" in shell and "A7_CAMPAIGN_DIR" in shell
assert "mesh_block_size = 16" in scene and "view_distance = 192" in scene
assert (root/"godot/project.godot").read_text(encoding="utf-8").count("gl_compatibility") >= 2
spec=importlib.util.spec_from_file_location("a7_report",root/"scripts/a7_report.py")
module=importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
with tempfile.TemporaryDirectory() as td:
    d=Path(td)
    (d/"manifest.json").write_text(json.dumps({
        "baseline_checkpoint":module.BASELINE,"full":False,"ci_smoke":True,
        "scenarios":["stationary_180s"],"seeds":[20261119],"repeats":1
    }),encoding="utf-8")
    result=module.analyze(d)
    assert not result["complete"] and result["overall"]=="NOT_QUALIFIED"
    assert all(result["gates"][gate]["status"]=="NOT_QUALIFIED" for gate in module.GATES)
    assert not result["automatic_acceptance"]
    (d/"a7_edits.json").write_text(json.dumps({
        "schema":"a7_edit_v1","scenario":"edit_idle_100","seed":20261119,
        "requested_count":100,"accepted_count":100,
        "native_apply_over_100_count":1,"max_native_apply_ms":101
    }),encoding="utf-8")
    result=module.analyze(d)
    assert result["gates"]["EDIT-100"]["status"]=="FAIL"
    assert all(result["gates"][gate]["status"]=="NOT_QUALIFIED" for gate in ("PERF-60","STREAM-18","VIEW-130"))
with tempfile.TemporaryDirectory() as td:
    d=Path(td)
    (d/"manifest.json").write_text(json.dumps({
        "baseline_checkpoint":module.BASELINE,"full":False,"ci_smoke":False,
        "scenarios":["reopen_save"],"seeds":[20261119],"repeats":1
    }),encoding="utf-8")
    expected_checks=["a3-smoke-windows.ps1","a4-smoke-windows.ps1","a5-smoke-windows.ps1"]
    result=module.analyze(d)
    assert not result["complete"] and result["runs_reported"]==0
    marker={"schema":"a7_reopen_v1","scenario":"reopen_save",
            "seed":20261119,"passed":True,"checks":expected_checks}
    (d/"a7_reopen.json").write_text(json.dumps(marker),encoding="utf-8")
    result=module.analyze(d)
    assert result["complete"] and result["runs_reported"]==1
    assert result["reopen_results"]["passed"]==1
    assert result["overall"]=="NOT_QUALIFIED" and not result["automatic_acceptance"]
    marker["checks"]=expected_checks[:-1]
    (d/"a7_reopen.json").write_text(json.dumps(marker),encoding="utf-8")
    assert not module.analyze(d)["complete"]
print("A7_STATIC_AND_FAIL_CLOSED_MATRIX_PASS")
