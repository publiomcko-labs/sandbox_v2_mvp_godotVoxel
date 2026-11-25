#!/usr/bin/env python3
"""A7 strict gate compiler: never infer true presentation or pixel coverage."""
from __future__ import annotations
import argparse
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path

GATES = ("PERF-60", "STREAM-18", "VIEW-130", "EDIT-100")
BASELINE = "0c3fee959576d0a1faec9ceecffb4b132a65558b"

def _load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8-sig"))

def _finite(d: dict, key: str) -> float | None:
    v = d.get(key)
    if isinstance(v, bool) or not isinstance(v, (int,float)) or not math.isfinite(float(v)):
        return None
    return float(v)

def analyze(root: Path) -> dict:
    manifest = _load(root/"manifest.json") if (root/"manifest.json").is_file() else {}
    routes, edits, reopens, errors = [], [], [], []
    for kind, filename, expected, store in (
        ("route","a7_route.json","a7_route_v1",routes),
        ("edit","a7_edits.json","a7_edit_v1",edits),
        ("reopen","a7_reopen.json","a7_reopen_v1",reopens)
    ):
        for p in sorted(root.rglob(filename)):
            try:
                d = _load(p)
                if d.get("schema") != expected:
                    raise ValueError("unexpected "+kind+" schema")
                store.append(d)
            except (OSError,ValueError) as e:
                errors.append(f"{p}: {e}")
    expected = len(manifest.get("scenarios",[]))*len(manifest.get("seeds",[]))*int(manifest.get("repeats",0))
    actual = len(routes)+len(edits)+len(reopens)
    expected_checks = {"a3-smoke-windows.ps1", "a4-smoke-windows.ps1", "a5-smoke-windows.ps1"}
    reopen_valid = all(
        r.get("scenario") == "reopen_save" and r.get("seed") == 20261119
        and r.get("passed") is True and isinstance(r.get("checks"), list)
        and len(r["checks"]) == 3 and set(r["checks"]) == expected_checks
        for r in reopens
    )
    complete = expected > 0 and expected == actual and not errors and reopen_valid
    route_groups, edit_groups = defaultdict(list), defaultdict(list)
    for r in routes: route_groups[r.get("route","unknown")].append(r)
    for e in edits: edit_groups[e.get("scenario","unknown")].append(e)
    timed = {}
    for name, xs in sorted(route_groups.items()):
        p99 = [x for r in xs if (x := _finite(r,"frame_start_p99_ms")) is not None]
        maxs = [x for r in xs if (x := _finite(r,"frame_start_max_ms")) is not None]
        timed[name] = {
            "runs":len(xs),"seeds":sorted({x.get("seed") for x in xs}),
            "frame_start_p99_median_ms":statistics.median(p99) if p99 else None,
            "frame_start_max_ms_worst":max(maxs) if maxs else None,
            "frame_intervals_over_16_7":sum(int(x.get("frame_intervals_over_16_7_ms",0)) for x in xs),
            "frame_intervals_over_20":sum(int(x.get("frame_intervals_over_20_ms",0)) for x in xs),
            "frame_intervals_over_33":sum(int(x.get("frame_intervals_over_33_ms",0)) for x in xs),
            "minimum_meshed_probe_hits":min(int(x.get("min_radial_probe_hits_8",8)) for x in xs),
            "screen_capture_overhead":any(int(x.get("screenshots",0))>0 for x in xs),
            "evidence_capture_mode":any(bool(x.get("capture")) for x in xs)
        }
    edited = {}
    for name, xs in sorted(edit_groups.items()):
        edited[name] = {
            "runs":len(xs),"seeds":sorted({x.get("seed") for x in xs}),
            "attempts":sum(int(x.get("requested_count",0)) for x in xs),
            "accepted":sum(int(x.get("accepted_count",0)) for x in xs),
            "rejected":sum(int(x.get("rejected_count",0)) for x in xs),
            "sdf_changed":sum(int(x.get("sdf_changed_count",0)) for x in xs),
            "native_apply_over100":sum(int(x.get("native_apply_over_100_count",0)) for x in xs),
            "native_apply_max_ms":max((float(x.get("max_native_apply_ms",0)) for x in xs),default=0.0),
            "correct_presented_pixels_measured":0
        }
    slow = sum(row["native_apply_over100"] for row in edited.values())
    gates = {
        "PERF-60":{"status":"NOT_QUALIFIED","reason":"No synchronized CPU + render thread + GPU + compositor/present measurements. Frame-start and viewport metrics are diagnostic."},
        "STREAM-18":{"status":"NOT_QUALIFIED","reason":"Requires verified graphical full-length cold/warm routes and continuous video review of terrain/rocks/water."},
        "VIEW-130":{"status":"NOT_QUALIFIED","reason":"Mesh probe counters and color screenshots are not 360-degree depth-verified pixels at 130 m."},
        "EDIT-100":{"status":"FAIL" if slow else "NOT_QUALIFIED",
                    "reason":"Native brush >100ms proves a strict failure." if slow else
                    "No synchronized raw input to FIRST CORRECT PRESENTED pixel timestamps; frame_post_draw is not presentation."}
    }
    warnings = list(errors)
    if not reopen_valid:
        warnings.append("Reopen functional regression evidence incomplete or invalid.")
    if not complete:
        warnings.append(f"Missing or extra sessions: {actual}/{expected} reported.")
    if manifest.get("baseline_checkpoint") not in (None,BASELINE):
        warnings.append("Baseline checkpoint mismatch.")
    if any(bool(x.get("ci_smoke")) for x in routes+edits):
        warnings.append("Headless smoke cannot qualify visuals or frame performance.")
    in_engine_readbacks = any(int(x.get("screenshots",0))>0 for x in routes) or any(
        int(x.get("screenshot_count",0))>0 for x in edits)
    if in_engine_readbacks:
        warnings.append("In-engine PNG readback introduces non-comparable frame stalls.")
    elif any(bool(x.get("capture")) for x in routes+edits):
        warnings.append("Evidence capture mode without in-engine PNG readback remains non-comparable to strict PERF-60.")
    if any(x["minimum_meshed_probe_hits"] < 8 for x in timed.values()):
        warnings.append("At least one mesh radial probe incomplete; potential coverage issue.")
    if any(x["frame_intervals_over_16_7"] for x in timed.values()):
        warnings.append("Frame-start intervals over 16.7ms must be retained and causally reviewed.")
    return {
        "schema":"a7_acceptance_matrix_v1","baseline":"A5 CPU16 GL Compatibility",
        "baseline_checkpoint":BASELINE,"full":bool(manifest.get("full")),
        "headless_smoke":bool(manifest.get("ci_smoke")),
        "runs_expected":expected,"runs_reported":actual,"complete":complete,
        "route_results":timed,"edit_results":edited,
        "reopen_results":{"runs":len(reopens),"passed":sum(r.get("passed") is True for r in reopens),
                          "fixed_seed":20261119,"checks":sorted(expected_checks) if reopens else []},
        "gates":gates,
        "overall":"FAIL" if slow else "NOT_QUALIFIED",
        "automatic_acceptance":False,"warnings":warnings,
        "known_accepted_mvp_limitations":[
            "A4 dynamic rock size/shading mismatch accepted provisionally",
            "A5 isolated cavities below y=0 flooded: post-MVP issue #7",
            "A6 mesh32/experimental GPU not promoted: post-MVP issue #10"
        ],
        "missing_evidence":[
            "Full app CPU + GPU + present frame timestamps, 1080p native",
            "All 130 m 360-degree pixel/depth coverage with ground+rocks+water",
            "Cold/hot 18m/s continuous routes reviewed frame-by-frame",
            "Accepted raw inputs to first correct presented pixels for 100 edits",
            "Collider update and non-penetration after edits",
            "Full three seeds x three repeats and reproducible Windows Release export"
        ]
    }

def markdown(d: dict) -> str:
    rows = [
        "# A7 — Relatório de aceitação","",
        f"Baseline: A5 CPU16 GL Compatibility ({d['baseline_checkpoint']}).",
        f"Execuções: {d['runs_reported']}/{d['runs_expected']}. Conjunto completo: {d['complete']}.",
        "","| Gate | Estado | Motivo |","|---|---|---|"
    ]
    rows.extend(f"| {k} | {d['gates'][k]['status']} | {d['gates'][k]['reason']} |" for k in GATES)
    rows.extend(["","## Rotas","",
                 "| Rota | Runs | Mediana p99 início de frame (ms) | Pior intervalo (ms) | Pior sonda |",
                 "|---|---:|---:|---:|---:|"])
    for name,r in d["route_results"].items():
        rows.append(f"| {name} | {r['runs']} | {r['frame_start_p99_median_ms']} | {r['frame_start_max_ms_worst']} | {r['minimum_meshed_probe_hits']}/8 |")
    rows.extend(["","## Edição","",
                 "| Cenário | Runs | Tentativas | Aceitas | SDF alterado | Aplicações >100ms |",
                 "|---|---:|---:|---:|---:|---:|"])
    for name,r in d["edit_results"].items():
        rows.append(f"| {name} | {r['runs']} | {r['attempts']} | {r['accepted']} | {r['sdf_changed']} | {r['native_apply_over100']} |")
    if d["reopen_results"]["runs"]:
        rows.extend(["","## Reabertura funcional","",
                     f"A3/A4/A5 smokes registrados (seed fixa 20261119): {d['reopen_results']['passed']}/{d['reopen_results']['runs']} sessões."])
    rows.extend(["","## Evidências faltantes",""])
    rows.extend("- "+m for m in d["missing_evidence"])
    rows.extend(["","## Avisos",""])
    rows.extend("- "+w for w in d["warnings"])
    rows.extend(["","**A7 não concede PASS a metas estritas sem evidência de apresentação gráfica.**",""])
    return "\n".join(rows)

def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("directory",type=Path)
    args = p.parse_args()
    if not args.directory.is_dir():
        p.error("A7 results directory absent")
    result=analyze(args.directory)
    (args.directory/"a7_acceptance_matrix.json").write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding="utf-8")
    (args.directory/"A7_REPORT.md").write_text(markdown(result),encoding="utf-8")
    print("A7_REPORT_READY runs="+str(result["runs_reported"])+"/"+str(result["runs_expected"])+" status="+result["overall"])
    for gate in GATES: print("A7_GATE "+gate+"="+result["gates"][gate]["status"])

if __name__=="__main__":
    main()
