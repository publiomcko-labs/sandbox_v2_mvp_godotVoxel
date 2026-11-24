#!/usr/bin/env python3
"""A8-P8 offline evidence pilot. Never turn RGB candidates into EDIT-100 PASS."""
import argparse, hashlib, json, math, subprocess
from pathlib import Path
from a7_video_timeline import process_video, locate_video, read_json
from a7_pixel_roi_review import compare_pixels, SIDE

def sha(path):
    h=hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda:f.read(1048576),b""): h.update(b)
    return h.hexdigest()

def geometry_changed(rays):
    if len(rays)!=9: raise ValueError("nine reference rays required")
    changed=0
    for ray in rays:
        a,b=ray["before_m"],ray["after_m"]
        for v in (a,b):
            if v is not None and (not isinstance(v,(float,int)) or not math.isfinite(v) or not 0<=v<=100):
                raise ValueError("invalid reference depth")
        changed+=int((a is None)!=(b is None) or (a is not None and b is not None and abs(a-b)>0.1))
    return changed

def audit(root,ffmpeg,ffprobe):
    manifest=read_json(root/"visual_evidence_manifest.json")
    trace=list((root/"game").rglob("a7_edits.jsonl"))
    if len(trace)!=1: raise ValueError("exactly one edit trace required")
    rows=[json.loads(x) for x in trace[0].read_text(encoding="utf-8-sig").splitlines() if x.strip()]
    meta=rows[0]
    if not meta.get("a8_p8_pilot") or meta.get("warmup_drawn_frames")!=1000 or meta.get("in_engine_stills_enabled"):
        raise ValueError("invalid pilot provenance")
    edits=[x for x in rows if x.get("type")=="edit"]
    if [x.get("index") for x in edits]!=list(range(12)) or not all(x.get("accepted") for x in edits):
        raise ValueError("12 accepted ordered edits required")
    fg=list((root/"game").rglob("a7_foreground.json"))
    if len(fg)!=1 or not read_json(fg[0]).get("continuity_verified"):
        raise ValueError("foreground not verified")
    timeline=process_video(root,ffmpeg,ffprobe)
    marker=timeline["marker"]
    marks=marker["aligned_events"]
    if not marker["alignment_verified"] or [m["event_index"] for m in marks]!=list(range(12)):
        raise ValueError("marker alignment unavailable")
    video=locate_video(root,manifest)
    raw=subprocess.run([ffmpeg,"-v","error","-nostdin","-i",str(video),"-map","0:v:0","-vf","crop=240:240:840:420,scale=120:120:flags=area,format=gray","-fps_mode","passthrough","-f","rawvideo","-pix_fmt","gray","pipe:1"],capture_output=True,check=True,timeout=600).stdout
    pts=[float(x["best_effort_timestamp_time"]) for x in json.loads(subprocess.run([ffprobe,"-v","error","-select_streams","v:0","-show_entries","frame=best_effort_timestamp_time","-of","json",str(video)],capture_output=True,check=True,timeout=600).stdout)["frames"]]
    size=SIDE*SIDE
    if len(raw)!=len(pts)*size: raise ValueError("ROI/frame mismatch")
    patch=lambda i: memoryview(raw)[i*size:(i+1)*size]
    findings=[]
    for e,m in zip(edits,marks):
        i=m["video_frame_index"]
        if i<1 or i>=len(pts): raise ValueError("marker outside video")
        if e.get("camera_hold_end_epoch_s",0)-e["brush_call_epoch_s"]<0.35: raise ValueError("short observation")
        if e.get("target_behind_camera") or any(abs(a-b)>16 for a,b in zip(e["target_screen_xy_px"],[960,540])): raise ValueError("invalid ROI target")
        n=geometry_changed(e["probe_rays"])
        candidates=[]
        for j in range(i,len(pts)):
            if pts[j]-pts[i]>0.25: break
            score=compare_pixels(patch(i-1),patch(j))
            if score["localized_candidate"]: candidates.append((pts[j]-pts[i])*1000)
        findings.append({"index":e["index"],"add":e["add"],"native_apply_ms":e["native_apply_ms"],"changed_live_sdf_rays":n,"first_rgb_candidate_after_marker_ms":min(candidates) if candidates else None,"first_correct_presented_pixel_ms":None})
    status=list((root/"game").rglob("a7_presentmon_status.json"))
    csv=list((root/"game").rglob("a7_presentmon.csv"))
    report={"schema":"a8_p8_pilot_v1","video_sha256":sha(video),"trace_sha256":sha(trace[0]),"etw_csv_sha256":sha(csv[0]) if len(csv)==1 else None,"etw_status":read_json(status[0]) if len(status)==1 else None,"alignment_residual_p99_ms":marker["offset_residual_p99_ms"],"edits":findings,"strict_edit_100":"NOT_QUALIFIED","limitations":["Live SDF rays are not independent rendered depth","RGB change is not verified geometry","Marker offset includes unknown presentation delay; no exact ETW frame join","Scripted input, not HID"]}
    (root/"a8_p8_pilot_report.json").write_text(json.dumps(report,indent=2),encoding="utf-8")
    return report

if __name__=="__main__":
    p=argparse.ArgumentParser()
    p.add_argument("campaign",type=Path)
    p.add_argument("--ffmpeg",required=True)
    p.add_argument("--ffprobe",required=True)
    a=p.parse_args()
    print(json.dumps(audit(a.campaign,a.ffmpeg,a.ffprobe)))
