"""V3.0 survey triage. No automatic causal attribution or qualification."""
import argparse
import csv
import json
import math
from pathlib import Path
from a7_streaming_present_report import epoch, number, choose_clock_alignment

def load_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))

def csv_rows(path):
    with path.open(newline="", encoding="utf-8-sig") as f:
        return list(csv.DictReader(f))

def require(ok, message):
    if not ok:
        raise ValueError(message)

def analyze(control, traced):
    c, t = [load_json(p / "comparison-v1-result.json") for p in (control, traced)]
    for result in (c, t):
        e = result["environment"]
        require(e["render_mode"] == "interactive" and e["profile"] == "cold", "not interactive cold")
        require(e["functional_proxies"]["edits_requested"] == 6, "incomplete edits")
    for key in ("git_sha", "hostname", "cpu", "gpu", "resolution", "backend", "godot_sha256", "native_sha256"):
        require(c["environment"][key] == t["environment"][key], "mismatch " + key)
    require(c["contract_sha256"] == t["contract_sha256"], "contract mismatch")
    require(not c["environment"]["v3_trace"] and t["environment"]["v3_trace"], "invalid trace arms")
    meta = load_json(traced / "v3-trace.csv.json")
    rows = csv_rows(traced / "v3-trace.csv")
    frames = csv_rows(traced / "frames.csv")
    require(meta["schema"] == "v3_0_survey_trace_v1" and meta["overflow"] == 0, "trace overflow or schema")
    require(len(rows) == len(frames) == meta["rows"] and len(rows) >= 100, "trace count")
    anchor = (meta["anchor_utc_usec"] - meta["anchor_mono_usec"]) / 1e6
    drift_ms = abs((meta["end_anchor_utc_usec"] - meta["end_anchor_mono_usec"])/1e6 - anchor)*1000
    spikes = []
    prev = None
    for raw, frame in zip(rows, frames):
        r = {k: int(v) for k,v in raw.items()}
        times = [r[k] for k in ("previous_usec","now_usec","movement_end_usec","edit_end_usec","probe_end_usec","context_end_usec")]
        require(times == sorted(times), "invalid monotonic spans")
        require(prev is None or r["previous_usec"] == prev["now_usec"], "trace discontinuity")
        dt = (r["now_usec"] - r["previous_usec"])/1000
        sec = (r["now_usec"] - meta["start_usec"])/1e6
        require(abs(dt-float(frame["interval_ms"])) < .002 and abs(sec-float(frame["t_s"])) < .000005, "frame mismatch")
        if dt >= 33:
            # A frame-start gap contains the PREVIOUS callback, not the current one.
            parts = None if prev is None else {
                "movement_ms": (prev["movement_end_usec"]-prev["now_usec"])/1000,
                "edit_ms": (prev["edit_end_usec"]-prev["movement_end_usec"])/1000,
                "probe_ms": (prev["probe_end_usec"]-prev["edit_end_usec"])/1000,
                "context_ms": (prev["context_end_usec"]-prev["probe_end_usec"])/1000,
                "unaccounted_ms": (r["now_usec"]-prev["context_end_usec"])/1000,
                "edits": prev["edits"], "probe": prev["probe"],
                "process_monitor_ms": prev["process_monitor_usec"]/1000,
                "physics_monitor_ms": prev["physics_monitor_usec"]/1000
            }
            nearest = min(meta["context"], key=lambda x: abs(x["mono_usec"]-r["now_usec"])) if meta["context"] else None
            spikes.append({"t_s":sec,"interval_ms":dt,"begin_epoch_s":anchor+r["previous_usec"]/1e6,
                           "end_epoch_s":anchor+r["now_usec"]/1e6,"previous_callback":parts,
                           "nearest_context":nearest,"cause":"UNATTRIBUTED"})
        prev = r
    etw = {"status":"NOT_MEASURED"}
    if (traced / "presentmon-status.json").exists():
        status = load_json(traced / "presentmon-status.json")
        etw = {"status":"INCOMPLETE","collector":status}
        if status["exit_code"] == 0 and not status["timeout"] and status["csv_bytes"] > 0 and not (status["etw_events_lost"] or status["etw_buffers_lost"]):
            raw = csv_rows(traced / "presentmon.csv")
            samples = [(epoch(r.get("CPUStartDateTime")),r) for r in raw]
            samples = [(x,r) for x,r in samples if x is not None]
            start = anchor + meta["start_usec"]/1e6 + 12
            end = start+34
            if samples and drift_ms <= 5 and max(meta["anchor_span_usec"],meta["end_anchor_span_usec"]) <= 5000:
                alignment = choose_clock_alignment(min(x for x,_ in samples),max(x for x,_ in samples),start,end,status["host_utc_offset_s"])
                etw["alignment"] = alignment
                if alignment["verified"]:
                    offset = alignment["offset_s"]
                    from collections import Counter
                    window = [(x+offset,r) for x,r in samples if start <= x+offset <= end]
                    chains = Counter(r.get("SwapChainAddress") for _,r in window if r.get("SwapChainAddress"))
                    if chains:
                        chain, count = chains.most_common(1)[0]
                        dominant = [(x,r) for x,r in window if r.get("SwapChainAddress")==chain]
                        gpu_count = sum(number(r.get("GPUTime")) is not None for _,r in dominant)
                        display_count = sum((number(r.get("DisplayLatency")) or 0)>0 for _,r in dominant)
                        if count >= 100 and count >= .9*len(window) and gpu_count >= .8*count and display_count >= 100 and max(x for x,_ in dominant)-min(x for x,_ in dominant) >= 28.9:
                            etw.update(status="ALIGNED_DIAGNOSTIC",rows=count,swapchain=chain,
                                       loss_counters_explicit_zero=status["etw_events_lost"]==0 and status["etw_buffers_lost"]==0)
                            for spike in spikes:
                                a,b=spike["begin_epoch_s"],spike["end_epoch_s"]
                                spike["etw_nearby"]=[{"cpu_start_epoch_s":x,**{k:number(r.get(k)) for k in ("FrameTime","CPUBusy","GPUTime","DisplayLatency","DisplayedTime")}} for x,r in dominant if a-.05 <= x <= b+.05]
    control_spikes = [{"t_s":float(r["t_s"]),"interval_ms":float(r["interval_ms"])} for r in csv_rows(control/"frames.csv") if float(r["interval_ms"])>=100]
    cf,tf=c["frames"],t["frames"]
    return {"schema":"sandbox_v3_0_triage_v1","status":"CANDIDATE_REPRODUCED_UNATTRIBUTED" if control_spikes or any(s["interval_ms"]>=100 for s in spikes) else "NO_100MS_EVENT_IN_TWO_RUNS",
            "historical_reference":{"t_s":24.60,"interval_ms":143.75},"control_100ms_events":control_spikes,
            "traced_33ms_events":spikes,"clock_drift_ms":drift_ms,"etw":etw,
            "control_frames":cf,"traced_frames":tf,
            "combined_instrumentation_p99_delta_ms":tf["interval_p99_ms"]-cf["interval_p99_ms"],
            "overhead_note":"Two cold runs measure combined observed difference, not isolated instrumentation overhead; variance is not controlled.",
            "strict_gates":"NOT_QUALIFIED","cause":"UNATTRIBUTED",
            "limitations":["A7 worker/terrain statistics are sampled, not per-job events.","ETW proximity is not exact frame identity or scheduler attribution.","No native per-job or OS scheduling trace; unaccounted time must remain unattributed.","Candidate threshold >=100 ms is not proof of same historical cause."]}

if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--control",type=Path,required=True)
    p.add_argument("--traced",type=Path,required=True)
    p.add_argument("--out",type=Path,required=True)
    a=p.parse_args()
    result=analyze(a.control,a.traced)
    a.out.write_text(json.dumps(result,indent=2,allow_nan=False)+"\n",encoding="utf-8")
    print(result["status"],result["etw"]["status"],"cause=UNATTRIBUTED")
