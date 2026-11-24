#!/usr/bin/env python3
"""Metric depth pilot, frame-stamp decoding and host-clock ETW diagnostics.

A sampled match to live SDF is not proof of complete brush correctness.
No exact join to a Windows presentation event or physical HID is claimed.
"""
import argparse
import csv
import datetime as dt
import json
import math
import re
import statistics
import subprocess
from pathlib import Path
from a7_video_timeline import locate_video, read_json
from a8_p8_edit_report import sha

def require(condition, reason):
    if not condition:
        raise ValueError(reason)

def parse_wall_as_utc(value):
    m=re.fullmatch(r"(\d{4})-(\d{1,2})-(\d{1,2})[ T](\d{1,2}):(\d{1,2}):(\d{1,2})(?:\.(\d{1,9}))?",value.strip())
    if not m:
        raise ValueError("unrecognized ETW wall timestamp")
    parts=[int(x) for x in m.groups()[:6]]
    us=int((m.group(7) or "").ljust(6,"0")[:6])
    return dt.datetime(*parts,microsecond=us,tzinfo=dt.timezone.utc).timestamp()

def align_clock(raw, capture_start, host_offset):
    require(type(host_offset) in (int,float) and math.isfinite(host_offset) and abs(host_offset)<=50400,"missing/invalid source host UTC offset")
    require(raw and all(math.isfinite(x) for x in raw),"missing ETW clock")
    # Only known source-host conventions: UTC, local, or twice-applied local.
    # Require a unique hypothesis anchored to collector launch, never analyst timezone.
    choices=sorted(set((0,-host_offset,-2*host_offset)))
    matches=[s for s in choices if -0.25<=min(raw)+s-capture_start<=3.0]
    require(len(matches)==1,"ETW launch-clock alignment unresolved")
    return matches[0]

def decode_stamp(values):
    if len(values)!=14 or values[0]<210 or values[-1]>45:
        return None
    if any(45<v<210 for v in values[1:-1]):
        return None
    return sum((1<<i) for i,v in enumerate(values[1:-1]) if v>=210)

def interpolate(gray, points):
    if not points[0][0]<=gray<=points[-1][0]:
        return None
    for (a,x),(b,y) in zip(points,points[1:]):
        if a<=gray<=b:
            return x+(gray-a)*(y-x)/(b-a)
    return None

def classify_depth(values, probes, tolerance=0.45):
    # Exclude the center crosshair. Only distinguishable, finite rays count.
    eligible=[]
    for i,(observed,p) in enumerate(zip(values,probes)):
        a,b=p["before_m"],p["after_m"]
        if i==4 or a is None or b is None or abs(a-b)<=2*tolerance:
            continue
        eligible.append((observed,a,b))
    if len(eligible)<2:
        return "INSUFFICIENT_SEPARATION",len(eligible)
    if any(x is None for x,_,_ in eligible):
        return "UNKNOWN_DEPTH",len(eligible)
    if all(abs(x-b)<=tolerance and abs(x-a)>tolerance for x,a,b in eligible):
        return "POST_EDIT_DEPTH_MATCH",len(eligible)
    if all(abs(x-a)<=tolerance and abs(x-b)>tolerance for x,a,b in eligible):
        return "PRE_EDIT_DEPTH_MATCH",len(eligible)
    return "MIXED_OR_UNCERTAIN",len(eligible)

def decode_region(video,ffmpeg,crop,w,h):
    blob=subprocess.run([ffmpeg,"-v","error","-nostdin","-i",str(video),"-map","0:v:0","-vf",crop,"-fps_mode","passthrough","-pix_fmt","gray","-f","rawvideo","pipe:1"],capture_output=True,check=True,timeout=600).stdout
    require(len(blob)%(w*h)==0,"incomplete decoded region")
    return blob

def median_patch(blob,base,w,x,y):
    return statistics.median(blob[base+(y+j)*w+x+i] for j in range(-1,2) for i in range(-1,2))

def audit(root,ffmpeg,ffprobe):
    manifest=read_json(root/"visual_evidence_manifest.json")
    require(manifest.get("a8_p81_depth_requested") is True and manifest.get("video_capture_valid_container") is True and manifest.get("presentmon_capture_valid") is True and manifest.get("game_run_succeeded") is True,"invalid acquisition manifest")
    traces=list((root/"game").rglob("a7_edits.jsonl"))
    require(len(traces)==1,"one edit trace required")
    folder=traces[0].parent
    rows=[json.loads(l) for l in traces[0].read_text(encoding="utf-8-sig").splitlines() if l.strip()]
    meta=rows[0]
    require(meta.get("a8_p81_depth") is True and meta.get("warmup_drawn_frames")==1000 and not meta.get("in_engine_stills_enabled"),"invalid depth provenance")
    edits=[r for r in rows if r.get("type")=="edit"]
    require([e["index"] for e in edits]==list(range(12)) and all(e.get("accepted") for e in edits),"12 ordered accepted edits required")
    require(read_json(folder/"a7_foreground.json").get("continuity_verified") is True,"foreground continuity not verified")
    calibration=meta["depth_calibration"]
    require(len(calibration)==7,"missing seven depth panels")
    points=[]
    for cal in calibration:
        # Decode PNG through the same grayscale conversion used for video.
        png=folder/cal["file"]
        sample=decode_region(png,ffmpeg,"crop=8:8:956:512",8,8)
        require(len(sample)==64,"invalid calibration PNG")
        points.append((statistics.median(sample),float(cal["distance_m"])))
    require(all(b-a>=5 and y>x for (a,x),(b,y) in zip(points,points[1:])),"nonmonotonic depth calibration")
    # Cross-validation checks curvature between calibration points.
    residuals=[abs(interpolate(g,[points[i-1],points[i+1]])-d) for i,(g,d) in enumerate(points) if 0<i<len(points)-1]
    require(max(residuals)<=0.35,"depth calibration interpolation uncertainty too large")
    # Conservative quantization/compression margin, not a guaranteed mesh/SDF bound.
    tolerance=max(0.45,max(residuals)+3*max((y-x)/(b-a) for (a,x),(b,y) in zip(points,points[1:])))
    video=locate_video(root,manifest)
    require(video is not None,"depth video missing")
    pts=[float(x["best_effort_timestamp_time"]) for x in json.loads(subprocess.run([ffprobe,"-v","error","-select_streams","v:0","-show_entries","frame=best_effort_timestamp_time","-of","json",str(video)],capture_output=True,check=True,timeout=600).stdout)["frames"]]
    require(all(math.isfinite(x) for x in pts) and all(b>=a for a,b in zip(pts,pts[1:])),"invalid video PTS")
    stamps=decode_region(video,ffmpeg,"crop=336:24:24:22",336,24)
    depths=decode_region(video,ffmpeg,"crop=80:80:920:500",80,80)
    require(len(stamps)==len(pts)*336*24 and len(depths)==len(pts)*80*80,"video decode count mismatch")
    by_id={}
    for j,t in enumerate(pts):
        base=j*336*24
        values=[median_patch(stamps,base,336,10+i*24,12) for i in range(14)]
        stamp=decode_stamp(values)
        if stamp is not None:
            by_id.setdefault(stamp,[]).append(j)
    etw_status=read_json(folder/"a7_presentmon_status.json")
    require(etw_status.get("exit_code")==0 and not etw_status.get("capture_error") and etw_status.get("etw_events_lost") in (None,0) and etw_status.get("etw_buffers_lost") in (None,0),"ETW error or known loss")
    with (folder/"a7_presentmon.csv").open(encoding="utf-8-sig",newline="") as f:
        etw=list(csv.DictReader(f))
    require(etw and all(int(r["ProcessID"])==etw_status["process_id"] for r in etw),"unexpected ETW PID")
    raw=[parse_wall_as_utc(r["CPUStartDateTime"]) for r in etw]
    shift=align_clock(raw,etw_status["capture_started_epoch_s"],etw_status.get("capture_host_utc_offset_s"))
    displays=[]
    for t,r in zip(raw,etw):
        try:
            latency=float(r["DisplayLatency"])
        except (ValueError,TypeError):
            continue
        if math.isfinite(latency) and latency>=0:
            displays.append(t+shift+latency/1000)
    require(displays and min(displays)<=edits[0]["brush_call_epoch_s"] and max(displays)>=edits[-1]["camera_hold_end_epoch_s"],"ETW does not cover edit observation")
    findings=[]
    for e in edits:
        i=e["index"]
        probes=e["probe_rays"]
        require(len(probes)==9,"nine rays required")
        ids=[f["id"] for f in e["depth_frames"]]
        require(ids==list(range(i*64+2,i*64+2+len(ids))) and len(ids)>0 and ids[-1]<i*64+64,"bad frame ID trace")
        observed=[]
        for f in e["depth_frames"]:
            fid=f["id"]
            pre,post=f["pre_draw_epoch_s"],f["post_draw_epoch_s"]
            require(pre<=post and post>=e["brush_call_epoch_s"] and post<=e["camera_hold_end_epoch_s"],"invalid draw clock")
            for j in by_id.get(fid,[]):
                values=[]
                for p in probes:
                    x,y=map(round,p["pixel"])
                    require(922<=x<=997 and 502<=y<=577,"ray outside ROI")
                    gray=median_patch(depths,j*80*80,80,x-920,y-500)
                    values.append(interpolate(gray,points))
                cls,n=classify_depth(values,probes,tolerance)
                observed.append({"frame_id":fid,"video_frame":j,"pts_s":pts[j],"class":cls,"eligible_rays":n,"observed_m":values,"draw_completion_proxy_ms":round((post-e["brush_call_epoch_s"])*1000,3)})
        matches=[o for o in observed if o["class"]=="POST_EDIT_DEPTH_MATCH"]
        first=min(matches,key=lambda o:o["frame_id"]) if matches else None
        findings.append({"index":i,"add":e["add"],"first_sampled_depth_match":first,"observations":observed,"first_correct_presented_pixel_ms":None})
    report={"schema":"a8_p81_depth_v1","video_sha256":sha(video),"trace_sha256":sha(traces[0]),"etw_csv_sha256":sha(folder/"a7_presentmon.csv"),"depth_calibration":points,"calibration_cv_max_m":max(residuals),"diagnostic_tolerance_m":tolerance,"host_utc_offset_s":etw_status["capture_host_utc_offset_s"],"etw_clock_shift_s":shift,"etw_loss_explicit_zero":etw_status.get("etw_events_lost")==0 and etw_status.get("etw_buffers_lost")==0,"edits":findings,"strict_edit_100":"NOT_QUALIFIED","limitations":["Depth is opaque scene, not terrain identity; live SDF not independent brush oracle","Frame ID associates sampled video with Godot draw proxy, not exact ETW present event","Lossy video and SDF/mesh tolerance; missing frames cannot establish earliest correct frame","Scripted input; not HID"]}
    (root/"a8_p81_depth_report.json").write_text(json.dumps(report,indent=2),encoding="utf-8")
    return report

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("campaign",type=Path)
    p.add_argument("--ffmpeg",required=True)
    p.add_argument("--ffprobe",required=True)
    a=p.parse_args()
    r=audit(a.campaign,a.ffmpeg,a.ffprobe)
    print("A8_P81_DEPTH_DIAGNOSTIC "+json.dumps({"edits":len(r["edits"]),"sampled_matches":sum(e["first_sampled_depth_match"] is not None for e in r["edits"]),"strict":r["strict_edit_100"]}))
