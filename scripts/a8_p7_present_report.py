#!/usr/bin/env python3
"""A8-P7 — extreme frame & display-cadence investigation; fail-closed.

A5/CPU16 performance evidence is actual GPU/Windows PresentMon ETW.
No display-cadence number by itself proves application-caused stalls;
no single 30-second experiment can qualify all 60FPS, 18m/s and 130m gates.
"""
from __future__ import annotations

import argparse
import bisect
import collections
import csv
import hashlib
import json
import math
from pathlib import Path

from a7_streaming_present_report import (
    analyze_run, choose_clock_alignment, epoch, number, open_presentmon_csv, percentile,
)

SCHEMA="a8_p7_extreme_frame_pilot_v1"
A5_SHA="0c3fee959576d0a1faec9ceecffb4b132a65558b"
EXPECTED_ROUTE="turns_18mps_300s"
EXPECTED_SEED=20261119
BUDGET_MS=16.7
THRESHOLDS=(16.7,20.0,33.0,50.0,100.0)
GATES=("perf_60_full_present_gate","stream_18_pixel_gate",
       "view_130_pixel_depth_gate")


def check(ok,why):
    if not ok:
        raise ValueError("A8_P7_REJECTED "+why)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def positive_float(x):
    return type(x) in (float,int) and math.isfinite(x) and x>=0


def stats(values:list[float]) -> dict:
    numbers=sorted(x for x in values if math.isfinite(x) and x>=0)
    if not numbers:
        return {"n":0,"min_ms":None,"p50_ms":None,"p95_ms":None,"p99_ms":None,
                "p999_ms":None,"max_ms":None}
    return {"n":len(numbers),"min_ms":round(numbers[0],5),
            "p50_ms":percentile(numbers,.5),"p95_ms":percentile(numbers,.95),
            "p99_ms":percentile(numbers,.99),"p999_ms":percentile(numbers,.999),
            "max_ms":round(numbers[-1],5)}


def histogram(values:list[float]) -> dict:
    return {("over_"+str(x).replace(".","_")+"_ms"):
            sum(v>x for v in values) for x in THRESHOLDS}


def find_arm(root:Path):
    m=read_json(root/"manifest.json")
    check(m.get("schema")=="a7_campaign_v1"
          and m.get("baseline_checkpoint")==A5_SHA
          and m.get("a8_p7_performance_requested") is True
          and m.get("presentmon_requested") is True
          and m.get("presentmon_gpu_tracking_requested") is True
          and m.get("capture") is False
          and m.get("ci_smoke") is False and m.get("full") is False
          and m.get("resource_diagnostic") is True
          and m.get("warmup_frames_requested")==1000
          and m.get("duration_override_s")==30
          and m.get("seeds")==[EXPECTED_SEED]
          and m.get("scenarios")==[EXPECTED_ROUTE]
          and m.get("repeats")==1
          and m.get("voxel_threads_requested")==0
          and m.get("target_resolution")=="1920x1080"
          and m.get("a8_p5_depth_video_requested") is False
          and m.get("a8_visual_evidence_requested") is False,
          "A5/CPU16 no-capture provenance / warmup/ETW")
    check(type(m.get("git_sha")) is str and len(m["git_sha"])==40,
          "Git HEAD missing")
    dirs=list(root.glob("turns_18mps_300s_seed20261119_rep01"))
    check(len(dirs)==1 and dirs[0].is_dir(),
          "exactly one 30s seed route required")
    return m,dirs[0]


def route_trace(folder:Path,meta:dict):
    data=read_json(folder/"a7_route.json")
    spikes=read_json(folder/"a8_p7_spikes.json")
    check(data.get("schema")=="a7_route_v1"
          and data.get("a8_p7_performance") is True
          and data.get("route")==EXPECTED_ROUTE
          and data.get("seed")==EXPECTED_SEED
          and data.get("duration_s")==30.0
          and data.get("warmup_drawn_frames_requested")==1000
          and type(data.get("warmup_drawn_frames_observed")) is int
          and data["warmup_drawn_frames_observed"]>=1000
          and data.get("capture") is False
          and data.get("screenshots")==0
          and data.get("a8_p5_depth_video") is False
          and data.get("ci_smoke") is False
          and data.get("voxel_threads_requested")==0
          and data.get("frame_count",0)>=600
          and data.get("vsync_mode_actual") is not None
          and all(data.get(g)=="NOT_QUALIFIED" for g in GATES),
          "A7 route source missing / strict gate unexpectedly changed")
    begin,end=data.get("measurement_epoch_begin_s"),data.get("measurement_epoch_end_s")
    check(positive_float(begin) and positive_float(end) and
          29.8<=end-begin<=33.5,"30s route wall-clock window invalid")
    check(spikes.get("schema")=="a8_p7_spikes_v1" and
          spikes.get("seed")==EXPECTED_SEED and
          spikes.get("route")==EXPECTED_ROUTE
          and spikes.get("duration_s")==30.0
          and spikes.get("frame_count")==data["frame_count"]
          and spikes.get("threshold_ms")==BUDGET_MS
          and spikes.get("strict_perf_60")=="NOT_QUALIFIED"
          and positive_float(spikes.get("measurement_epoch_begin_s")) and
          abs(spikes["measurement_epoch_begin_s"]-begin)<.05,
          "P7 spike telemetry provenance")
    rows=spikes.get("events")
    check(isinstance(rows,list) and
          len(rows)+spikes.get("overflow",0)==spikes.get("over_16_7_total")==
          data.get("frame_intervals_over_16_7_ms") and
          type(spikes.get("overflow")) is int and spikes["overflow"]>=0,
          "lost or invented Godot over-budget events")
    prev_t=-1.0
    for row in rows:
        check(isinstance(row,list) and len(row)==3
              and type(row[2]) is int and 1<=row[2]<=data["frame_count"]
              and positive_float(row[0]) and 0<=row[0]<=30.001
              and positive_float(row[1]) and row[1]>BUDGET_MS
              and row[0]>=prev_t,"malformed spike or reversed timestamps")
        prev_t=row[0]
    check(data.get("frame_intervals_over_33_ms",0)<=
          data.get("frame_intervals_over_20_ms",0)<=
          data.get("frame_intervals_over_16_7_ms",0)<=data["frame_count"],
          "threshold counters inconsistent")
    trace=folder/"a7_route.jsonl"
    check(trace.exists() and trace.stat().st_size>1000,"trace missing")
    samples=[]
    for line in trace.read_text(encoding="utf-8-sig").splitlines():
        if not line.strip():continue
        record=json.loads(line)
        if record.get("type")=="sample" and record.get("phase")=="moving":
            t=number(record.get("t_s"))
            check(t is not None and 0<=t<=30.2,"invalid sample time")
            workers=record.get("voxel_workers",{})
            q=workers.get("queued_tasks")
            active=workers.get("active_threads")
            check(type(q) is int and type(active) is int,"voxel workers missing")
            samples.append({
                "t_s":t,"queue":q,"workers_active":active,
                "mesh_blocks":record.get("mesh_blocks"),
                "data_blocks":record.get("data_blocks"),
                "meshed_radial_probes":record.get("meshed_radial_probes"),
                "render_cpu_ms":number(record.get("viewport_render_cpu_ms")),
                "render_gpu_ms":number(record.get("viewport_render_gpu_ms")),
                "physics_ms":number(record.get("physics_ms")),
                "process_ms":number(record.get("process_ms")),
            })
    check(len(samples)>=25 and len(samples)<=32,
          "missing 1Hz streaming telemetry from 30s route")
    return data,spikes,samples


def display_events(folder:Path,route:dict,etw:dict):
    check(etw.get("presentation_status")=="ETW_ALIGNED" and
          etw.get("etw_scope")=="full_route" and
          etw.get("gpu_tracking_requested") is True and
          etw.get("etw_events_lost") in (None,0)
          and etw.get("etw_buffers_lost") in (None,0)
          and positive_float(etw.get("timestamp_adjustment_seconds")),
          "full-window ETW with tracked GPU and no confirmed loss required")
    status=read_json(folder/"a7_presentmon_status.json")
    check(status.get("collection_started") is True and
          status.get("exit_code")==0 and status.get("gpu_tracking_requested") is True
          and status.get("csv_exists") is True and
          status.get("csv_bytes",0)>1024 and
          status.get("capture_requested_duration_s")==0,
          "collector exit/CSV/gpu/scope invalid")
    start,end=route["measurement_epoch_begin_s"],route["measurement_epoch_end_s"]
    offset=etw["timestamp_adjustment_seconds"]
    main={}
    dropped=0
    present_modes=collections.Counter()
    columns=("FrameTime","CPUBusy","GPUTime","DisplayLatency","DisplayedTime")
    timings={k:[] for k in columns}
    full=[]
    with open_presentmon_csv(folder) as source:
        reader=csv.DictReader(source)
        header=set(reader.fieldnames or [])
        check(set(columns)|{"CPUStartDateTime","SwapChainAddress"} <= header,
              "PresentMon v2 required CSV fields absent")
        for row in reader:
            t=epoch(row.get("CPUStartDateTime"))
            if t is None:continue
            t+=offset
            if t<start or t>end:continue
            latency=number(row.get("DisplayLatency"))
            if latency is None or latency<0:
                dropped+=1
                continue
            chain=(row.get("SwapChainAddress") or "unknown").strip()
            # This is CPU-start + ETW-reported latency, not an observed photon
            # and not an exact pair with the Godot _process callback.
            display_t=t+latency/1000.0
            full.append((display_t,chain,t,row))
            present_modes[str(row.get("PresentMode","unknown"))]+=1
            for key in columns:
                v=number(row.get(key))
                if v is not None and v>=0:
                    timings[key].append(v)
    check(len(full)>=400 and
          len(timings["GPUTime"])>=len(full)*.8 and
          len(timings["FrameTime"])>=len(full)*.8,
          "GPU timings missing or too few displayed ETW rows")
    bychain=collections.defaultdict(list)
    for display_t,chain,t,row in full:bychain[chain].append((display_t,t,row))
    # Refuse to combine cadence from different swap chains. The dominant
    # chain must contribute >=90% of displayed game process rows.
    chain,entries=max(bychain.items(),key=lambda kv:len(kv[1]))
    check(len(entries)>=len(full)*.90,
          "multiple swap chains: cannot attribute dominant game presentation")
    entries.sort(key=lambda x:x[0])
    last=None
    intervals=[]
    interval_events=[]
    invalid=0
    for displayed_t,started_t,row in entries:
        if last is not None:
            gap=(displayed_t-last)*1000.0
            if not math.isfinite(gap) or gap<=0:
                invalid+=1
            else:
                intervals.append(gap)
                if gap>BUDGET_MS:
                    interval_events.append({
                        "display_epoch_s":round(displayed_t,6),
                        "t_route_s":round(displayed_t-start,6),
                        "interval_ms":round(gap,4),
                        "gpu_work_ms":number(row.get("GPUTime")),
                        "cpu_busy_ms":number(row.get("CPUBusy")),
                        "frame_time_ms":number(row.get("FrameTime")),
                        "present_mode":row.get("PresentMode"),
                    })
        last=displayed_t
    check(len(intervals)>=400 and invalid<=len(entries)*.03,
          "not enough monotonic, same-swapchain display changes")
    return {
        "presented_main_swapchain":chain,
        "main_swapchain_percent":round(100*len(entries)/len(full),3),
        "displayed_rows":len(full),"dropped_rows":dropped,
        "nonmonotonic_or_zero_delta":invalid,
        "present_mode_counts":dict(present_modes),
        "display_intervals_ms":intervals,
        "display_latency_ms":timings["DisplayLatency"],
        "cpu_frame_time_ms":timings["FrameTime"],
        "cpu_busy_ms":timings["CPUBusy"],
        "gpu_work_ms":timings["GPUTime"],
        "displayed_time_ms":timings["DisplayedTime"],
        "over_budget_display_events":interval_events,
    }


def correlate(samples:list[dict],events:list[dict],route_start:float):
    # 1Hz worker probes are context, not a per-frame attribution. Intervals
    # can come from VSync, OS scheduling, GPU, CPU, DWM or other external causes.
    times=[s["t_s"] for s in samples]
    output=[]
    for item in sorted(events,key=lambda e:e["interval_ms"],reverse=True)[:30]:
        t=item["t_route_s"]
        index=bisect.bisect_left(times,t)
        neighbors=[samples[i] for i in (index-1,index) if 0<=i<len(samples)]
        nearest=min(neighbors,key=lambda s:abs(s["t_s"]-t)) if neighbors else None
        output.append({
            **item,
            "nearest_1hz_worker":nearest if nearest and abs(nearest["t_s"]-t)<=1.1 else None,
            "proven_causal_subsystem":None,
            "attribution":"HYPOTHESIS_ONLY_1HZ_SAMPLE_NOT_PER_FRAME_CAUSATION",
        })
    return output


def audit(root:Path) -> dict:
    manifest,folder=find_arm(root)
    route,spikes,samples=route_trace(folder,manifest)
    etw=analyze_run(folder)
    result={
        "schema":SCHEMA,
        "source_git_sha":manifest["git_sha"],
        "baseline_checkpoint":A5_SHA,
        "gpu_expected":"NVIDIA GeForce GTX 1050 Ti",
        "seed":EXPECTED_SEED,
        "route":EXPECTED_ROUTE,
        "speed_mps":18.0,
        "duration_s":30,
        "warmup_drawn_frames":route["warmup_drawn_frames_observed"],
        "raw_presentmon_sha256":None,
        "presentmon_etw_status":etw["presentation_status"],
        "presentmon_etw_reason":etw.get("reason"),
        "etw_events_lost":etw.get("etw_events_lost"),
        "etw_buffers_lost":etw.get("etw_buffers_lost"),
        "etw_loss_counters_explicit_zero":etw.get("etw_events_lost")==0 and
            etw.get("etw_buffers_lost")==0,
        "etw_window_coverage_s":etw.get("window_coverage_s"),
        "etw_timestamp_alignment_method":etw.get("timestamp_alignment_method"),
        "godot_frame_count":route["frame_count"],
        "godot_frame_start_ms":{
            "p50_ms":route["frame_start_p50_ms"],
            "p95_ms":route["frame_start_p95_ms"],
            "p99_ms":route["frame_start_p99_ms"],
            "p999_ms":route["frame_start_p999_ms"],
            "max_ms":route["frame_start_max_ms"],
            "over_16_7_ms":route["frame_intervals_over_16_7_ms"],
            "over_20_ms":route["frame_intervals_over_20_ms"],
            "over_33_ms":route["frame_intervals_over_33_ms"],
        },
        "godot_spike_event_count":len(spikes["events"]),
        "godot_spike_overflow":spikes["overflow"],
        "voxel_1hz_sample_count":len(samples),
        "voxel_worker_queue_peak":max(x["queue"] for x in samples),
        "voxel_worker_active_peak":max(x["workers_active"] for x in samples),
        "mesh_blocks_peak":max(x["mesh_blocks"] for x in samples),
        "frame_presentation_cadence":None,
        "presentmon_cpu_busy":None,
        "presentmon_gpu_work":None,
        "presentmon_cpu_frame_time":None,
        "presentmon_display_latency":None,
        "presentmon_displayed_time":None,
        "display_event_outliers_top_30":[],
        "automatic_causal_attribution":False,
        "full_60fps_contract_verified":False,
        "strict_perf_60":"NOT_QUALIFIED",
        "strict_stream_18":"NOT_QUALIFIED",
        "strict_view_130":"NOT_QUALIFIED",
        "strict_edit_100":"NOT_QUALIFIED",
        "engineering_conclusion":"NOT_MEASURED_FULL_GPU_PRESENT",
        "limitations":[
            "30s and one seed/route is a diagnostic pilot; contractual 3 seeds / 3 repetitions not attempted",
            "ETW/display changes and DisplayLatency do not identify the application cause of missed display cycles",
            "GPUTime is GPU work, not complete presented frame time",
            "Godot frame-start intervals are callback cadence, not display times",
            "Correlation with 1Hz VoxelEngine stats is not proof of mesher/worker cause",
            "Without video the 130m pixels, rock-water simultaneous publication and EDIT-100 remain unqualified",
            "Presentation timestamps are from Windows ETW, not actual display panel photons",
            "ETW and runtime instrumentation can perturb frame timing; an A/B must use the same load",
        ],
    }
    if etw["presentation_status"]=="ETW_ALIGNED":
        measured=display_events(folder,route,etw)
        gaps=measured["display_intervals_ms"]
        result["frame_presentation_cadence"]={
            **stats(gaps),**histogram(gaps),
            "fraction_over_16_7":round(sum(v>BUDGET_MS for v in gaps)/len(gaps),6),
            "time_over_budget_ms":round(sum(max(0,v-BUDGET_MS) for v in gaps),3),
            "largest_consecutive_over_budget_sequence":longest_sequence(gaps,BUDGET_MS),
            "main_swapchain":measured["presented_main_swapchain"],
            "main_swapchain_percent":measured["main_swapchain_percent"],
            "etw_displayed_rows":measured["displayed_rows"],
            "etw_dropped_rows":measured["dropped_rows"],
            "present_mode_counts":measured["present_mode_counts"],
        }
        for label,key in (("presentmon_cpu_busy","cpu_busy_ms"),
                          ("presentmon_gpu_work","gpu_work_ms"),
                          ("presentmon_cpu_frame_time","cpu_frame_time_ms"),
                          ("presentmon_display_latency","display_latency_ms"),
                          ("presentmon_displayed_time","displayed_time_ms")):
            result[label]=stats(measured[key])
        result["display_event_outliers_top_30"]=correlate(
            samples,measured["over_budget_display_events"],
            route["measurement_epoch_begin_s"])
        result["engineering_conclusion"]=(
            "PRESENTATION_OUTLIERS_OBSERVED_CAUSE_UNATTRIBUTED"
            if result["frame_presentation_cadence"]["over_16_7_ms"]>0 else
            "NO_PRESENTATION_OUTLIERS_IN_ONE_ETW_PILOT_NOT_QUALIFIED"
        )
    else:
        result["engineering_conclusion"]="ETW_NOT_QUALIFIED_NO_DISPLAY_ASSERTION"
    return result


def longest_sequence(values:list[float],limit:float) -> int:
    current=best=0
    for v in values:
        if v>limit: current+=1;best=max(best,current)
        else: current=0
    return best


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("pilot",type=Path)
    parser.add_argument("--output",type=Path)
    args=parser.parse_args()
    report=audit(args.pilot)
    path=args.output or args.pilot/"a8_p7_present_report.json"
    if path.exists():raise SystemExit("A8_P7_NO_OVERWRITE: "+str(path))
    path.write_text(json.dumps(report,indent=2,ensure_ascii=False),encoding="utf-8")
    print("A8_P7_PRESENTATION_DIAGNOSTIC "+json.dumps({
        "ETW":report["presentmon_etw_status"],
        "display_p99":(report["frame_presentation_cadence"] or {}).get("p99_ms"),
        "display_max":(report["frame_presentation_cadence"] or {}).get("max_ms"),
        "display_over_16_7":(report["frame_presentation_cadence"] or {}).get("over_16_7_ms"),
        "strict":"NOT_QUALIFIED"}))


if __name__=="__main__":main()
