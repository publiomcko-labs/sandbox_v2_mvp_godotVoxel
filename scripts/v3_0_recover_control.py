"""Recover a completed raw control without inventing its missing metadata."""
import argparse
import importlib.util
import json
import re
from pathlib import Path

def recover(folder, contract):
    stdout = (folder / "godot-stdout.txt").read_text(encoding="utf-8-sig")
    stderr = (folder / "godot-stderr.txt").read_text(encoding="utf-8-sig")
    native = json.loads((folder / "native.json").read_text(encoding="utf-8-sig"))
    match = re.search(r"COMPARISON_V1_DONE frames=(\d+) edits_accepted=(\d+)", stdout)
    if not match or stderr.strip() or "COMPARISON_V1_START duration_s=46 warmup_s=12 speed_mps=18 edits=6" not in stdout:
        raise ValueError("incomplete control logs")
    if native.get("edits_requested") != 6 or native.get("edits_accepted") != 6 or native.get("save_status") != "completed":
        raise ValueError("control edits/save not complete")
    gpu = re.search(r"OpenGL API .*? NVIDIA (\S+) - Compatibility - Using Device: NVIDIA - (NVIDIA GeForce GTX 1050 Ti)", stdout)
    if not gpu:
        raise ValueError("expected graphical baseline not observed")
    spec = importlib.util.spec_from_file_location("comparison_reduce", Path(__file__).with_name("comparison-v1-reduce.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    rows = module.parse_csv(folder / "frames.csv")
    if len(rows) != int(match[1]) or int(match[2]) != native["edits_accepted"]:
        raise ValueError("control counters disagree")
    metadata = {"engine":"godot_voxel_tools","scenario_id":"survey46-six-edits-v1","render_mode":"interactive","profile":"cold",
                "v3_trace":False,"presentmon_requested":False,"functional_proxies":native,"recovered_control":True,
                "observed_driver":gpu[1],"observed_gpu_name":gpu[2],"backend":"Godot GL Compatibility",
                "metadata_limit":"Process exit code and contemporaneous CPU/host/commit/binary fingerprints not captured. Cold profile and no trace from original control directory/log provenance."}
    result = module.reduce_trace(rows, contract, metadata)
    for filename, value in (("metadata.json", metadata), ("comparison-v1-result.json", result)):
        (folder/filename).write_text(json.dumps(value,indent=2)+"\n",encoding="utf-8")
    print("V3_0_CONTROL_RECOVERED",len(rows),"frames; no new control run")
if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("folder",type=Path)
    p.add_argument("--contract",type=Path,required=True)
    a=p.parse_args()
    recover(a.folder,a.contract)
