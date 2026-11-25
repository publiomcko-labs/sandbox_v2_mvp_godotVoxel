#!/usr/bin/env python3
"""Re-decode original P8.1 video, retain old calibration, de-duplicate stamps.
Legacy final stamp was held beyond observation and is excluded entirely.
Never interpret an incompatible class as mesh failure.
"""
import argparse,collections,json,math,subprocess
from pathlib import Path
from a7_video_timeline import locate_video,read_json
from a8_p8_edit_report import sha
from a8_p81_depth_report import decode_region,decode_stamp,median_patch,interpolate,classify_depth

def audit(root,ffmpeg,ffprobe):
    old=read_json(root/"a8_p81_depth_report.json")
    manifest=read_json(root/"visual_evidence_manifest.json")
    traces=list((root/"game").rglob("a7_edits.jsonl"))
    if len(traces)!=1:raise ValueError("one trace required")
    trace=traces[0]
    video=locate_video(root,manifest)
    if video is None or sha(video)!=old["video_sha256"] or sha(trace)!=old["trace_sha256"]:
        raise ValueError("legacy provenance mismatch")
    edits=[r for r in (json.loads(l) for l in trace.read_text(encoding="utf-8-sig").splitlines() if l.strip()) if r.get("type")=="edit"]
    if [e["index"] for e in edits]!=list(range(12)):raise ValueError("invalid edit order")
    pts=[float(x["best_effort_timestamp_time"]) for x in json.loads(subprocess.run([ffprobe,"-v","error","-select_streams","v:0","-show_entries","frame=best_effort_timestamp_time","-of","json",str(video)],capture_output=True,check=True,timeout=600).stdout)["frames"]]
    if not pts or not all(math.isfinite(x) for x in pts) or not all(a<=b for a,b in zip(pts,pts[1:])):raise ValueError("invalid PTS")
    stamps=decode_region(video,ffmpeg,"crop=336:24:24:22",336,24)
    depth=decode_region(video,ffmpeg,"crop=80:80:920:500",80,80)
    if len(stamps)!=len(pts)*8064 or len(depth)!=len(pts)*6400:raise ValueError("frame count mismatch")
    by_id=collections.defaultdict(list)
    for j in range(len(pts)):
        stamp=decode_stamp([median_patch(stamps,j*8064,336,10+i*24,12) for i in range(14)])
        if stamp is not None:by_id[stamp].append(j)
    results=[]
    for e in edits:
        frames=[]
        for f in e["depth_frames"]:
            ix=by_id[f["id"]]
            if not ix:continue
            cs=[]
            for j in ix:
                observed=[]
                for p in e["probe_rays"]:
                    x,y=map(round,p["pixel"])
                    if not 921<=x<=998 or not 501<=y<=578:raise ValueError("out-of-bounds probe")
                    observed.append(interpolate(median_patch(depth,j*6400,80,x-920,y-500),old["depth_calibration"]))
                cls,_=classify_depth(observed,e["probe_rays"],old["diagnostic_tolerance_m"])
                cs.append(cls)
            frames.append({"id":f["id"],"draw_proxy_ms":round((f["post_draw_epoch_s"]-e["brush_call_epoch_s"])*1000,3),"observations":len(ix),"span_ms":round((pts[ix[-1]]-pts[ix[0]])*1000,3),"class_counts":dict(collections.Counter(cs)),"first":cs[0],"last_stamp_excluded":f==e["depth_frames"][-1],"ambiguous":len(set(cs))>1})
        usable=[r for r in frames if not r["last_stamp_excluded"] and not r["ambiguous"]]
        results.append({"edit":e["index"]+1,"ids":len(frames),"observations":sum(r["observations"] for r in frames),"ambiguous_ids":sum(r["ambiguous"] for r in frames),"usable_classes":dict(collections.Counter(r["first"] for r in usable)),"frames":frames})
    return {"schema":"a8_p82_legacy_offline_audit_v1","video_sha256":sha(video),"trace_sha256":sha(trace),"decoded_frames":len(pts),"calibration_tolerance_m":old["diagnostic_tolerance_m"],"edits":results,"strict_edit_100":"NOT_QUALIFIED"}

if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("campaign",type=Path);p.add_argument("--ffmpeg",required=True);p.add_argument("--ffprobe",required=True);p.add_argument("--output",required=True,type=Path);a=p.parse_args()
    result=audit(a.campaign,a.ffmpeg,a.ffprobe)
    with a.output.open("x",encoding="utf-8") as f:json.dump(result,f,indent=2)
