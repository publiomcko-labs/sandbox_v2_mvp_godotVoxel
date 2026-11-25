#!/usr/bin/env python3
"""P8.2 calibrated local depth + independent CSG; fail closed on ambiguity."""
import argparse,collections,csv,json,math,statistics,subprocess
from pathlib import Path
from a7_video_timeline import locate_video,read_json
from a8_p8_edit_report import sha
from a8_p81_depth_report import decode_region,decode_stamp,median_patch,interpolate,parse_wall_as_utc,align_clock
from a8_p82_csg_oracle import evaluate

def require(ok,why):
    if not ok:raise ValueError(why)

def stable_group(indices,pts,samples,max_span_ms=34.0):
    if not indices:return "MISSING"
    if indices!=list(range(indices[0],indices[-1]+1)):
        return "NONCONTIGUOUS_ID"
    if (pts[indices[-1]]-pts[indices[0]])*1000>max_span_ms+1e-6:
        return "PERSISTENT_ID"
    if any(max(col)-min(col)>2 for col in zip(*samples)):
        return "CONFLICTING_DEPTH"
    return "STABLE"

def calibrate(points,png_points):
    require(len(points)==len(png_points)==7,"seven panels required")
    require(all(b-a>=5 and y>x for (a,x),(b,y) in zip(points,points[1:])),"nonmonotonic calibration")
    residual=max(abs(interpolate(g,[points[i-1],points[i+1]])-d) for i,(g,d) in enumerate(points) if 0<i<len(points)-1)
    step=max((y-x)/(b-a) for (a,x),(b,y) in zip(points,points[1:]))
    video_delta=max(abs(a-b) for (a,_),b in zip(points,png_points))*step
    budget=residual+step/2+video_delta
    return {"cross_validation_max_m":residual,"max_quantization_step_m":step,"png_video_delta_bound_m":video_delta,"estimated_error_budget_m":budget,"target_0_10m_met":budget<=0.10}

def geometry_class(observed,refs,tol):
    pairs=[(x,r["oracle_before_m"],r["oracle_after_m"]) for i,(x,r) in enumerate(zip(observed,refs)) if i!=4 and r["status"]=="PREDICTED" and abs(r["oracle_before_m"]-r["oracle_after_m"])>2*tol]
    if len(pairs)<2:return "INSUFFICIENT_INDEPENDENT_RAYS"
    if any(x is None for x,_,_ in pairs):return "UNKNOWN_DEPTH"
    if all(abs(x-b)<=tol and abs(x-a)>tol for x,a,b in pairs):return "CSG_POST_MATCH"
    if all(abs(x-a)<=tol and abs(x-b)>tol for x,a,b in pairs):return "CSG_PRE_MATCH"
    return "MIXED_OR_UNCERTAIN"

def audit(root,ffmpeg,ffprobe):
    manifest=read_json(root/"visual_evidence_manifest.json")
    require(all(manifest.get(k) is True for k in ("a8_p82_precision_requested","video_capture_valid_container","presentmon_capture_valid","game_run_succeeded")),"invalid acquisition")
    traces=list((root/"game").rglob("a7_edits.jsonl"))
    require(len(traces)==1,"one edit trace required")
    folder=traces[0].parent
    rows=[json.loads(l) for l in traces[0].read_text(encoding="utf-8-sig").splitlines() if l.strip()]
    meta=rows[0];edits=[r for r in rows if r.get("type")=="edit"]
    require(meta.get("a8_p82_precision") is True and meta.get("warmup_drawn_frames")==1000 and not meta.get("in_engine_stills_enabled") and meta.get("radius_m")==1.5,"invalid runtime provenance")
    require([e["index"] for e in edits]==list(range(12)) and all(e.get("accepted") for e in edits),"12 accepted edits required")
    require(read_json(folder/"a7_foreground.json").get("continuity_verified") is True,"foreground unverified")
    video=locate_video(root,manifest);require(video is not None,"video missing")
    pts=[float(x["best_effort_timestamp_time"]) for x in json.loads(subprocess.run([ffprobe,"-v","error","-select_streams","v:0","-show_entries","frame=best_effort_timestamp_time","-of","json",str(video)],capture_output=True,check=True,timeout=600).stdout)["frames"]]
    require(pts and all(math.isfinite(v) for v in pts) and all(b>=a for a,b in zip(pts,pts[1:])),"invalid PTS")
    stamps=decode_region(video,ffmpeg,"crop=336:24:24:22",336,24)
    depth=decode_region(video,ffmpeg,"crop=80:80:920:500",80,80)
    require(len(stamps)==len(pts)*8064 and len(depth)==len(pts)*6400,"decoded frame count mismatch")
    def gray(j,x,y):
        require(921<=x<=998 and 501<=y<=578,"pixel outside ROI")
        return median_patch(depth,j*6400,80,x-920,y-500)
    by_id=collections.defaultdict(list)
    for j in range(len(pts)):
        ident=decode_stamp([median_patch(stamps,j*8064,336,10+i*24,12) for i in range(14)])
        if ident is not None:by_id[ident].append(j)
    points=[];png_points=[]
    for k,c in enumerate(meta["depth_calibration"]):
        require(c["stamp_id"]==3900+k and c["range_start_m"]==9.0,"invalid calibration metadata")
        ids=by_id[c["stamp_id"]]
        require(len(ids)>=2 and ids==list(range(ids[0],ids[-1]+1)),"calibration video stamp missing or noncontiguous")
        # Discard first captured panel transition; require remaining values stable.
        gs=[gray(j,960,516) for j in ids[1:]]
        require(max(gs)-min(gs)<=2,"calibration panel unstable")
        png=decode_region(folder/c["file"],ffmpeg,"crop=8:8:956:512",8,8)
        require(len(png)==64,"bad calibration PNG")
        points.append((statistics.median(gs),float(c["distance_m"])-9))
        png_points.append(statistics.median(png))
    cal=calibrate(points,png_points)
    # Depth precision is separate from trilinear SDF/meshing model tolerance.
    tol=max(0.45,cal["estimated_error_budget_m"])
    status=read_json(folder/"a7_presentmon_status.json")
    require(status.get("exit_code")==0 and not status.get("capture_error") and status.get("etw_events_lost") in (None,0) and status.get("etw_buffers_lost") in (None,0),"ETW error")
    with (folder/"a7_presentmon.csv").open(encoding="utf-8-sig",newline="") as f:etw=list(csv.DictReader(f))
    require(etw and all(int(r["ProcessID"])==status["process_id"] for r in etw),"invalid ETW PID")
    raw=[parse_wall_as_utc(r["CPUStartDateTime"]) for r in etw]
    shift=align_clock(raw,status["capture_started_epoch_s"],status.get("capture_host_utc_offset_s"))
    displayed=[]
    for t,r in zip(raw,etw):
        try:l=float(r["DisplayLatency"])
        except (ValueError,TypeError):continue
        if math.isfinite(l) and l>=0:displayed.append(t+shift+l/1000)
    require(displayed and min(displayed)<=edits[0]["brush_call_epoch_s"] and max(displayed)>=edits[-1]["camera_hold_end_epoch_s"],"ETW observation coverage missing")
    result=[]
    for e in edits:
        require(len(e["probe_rays"])==9 and e["stamp_invalidated_epoch_s"]>=e["camera_hold_end_epoch_s"],"invalid observation trace")
        oracle=evaluate(e,meta["radius_m"])
        frames=e["depth_frames"];ids=[f["id"] for f in frames]
        require(ids==list(range(e["index"]*64+2,e["index"]*64+2+len(ids))) and ids and ids[-1]<e["index"]*64+64,"bad frame IDs")
        counters=collections.Counter(f["drawn_frame"] for f in frames)
        out=[]
        for f in frames:
            ident=f["id"];indices=by_id[ident]
            values=[[gray(j,*map(round,p["pixel"])) for p in e["probe_rays"]] for j in indices]
            state=stable_group(indices,pts,values)
            if counters[f["drawn_frame"]]!=1:state="DUPLICATE_ENGINE_COUNTER"
            require(f["pre_draw_epoch_s"]<=f["post_draw_epoch_s"]<=e["camera_hold_end_epoch_s"] and f["post_draw_ticks_us"]>=e["brush_call_ticks_us"],"invalid draw timestamp")
            obs=None;cls=None
            if state=="STABLE":
                obs=[]
                for g in values[0]:
                    x=interpolate(g,points)
                    obs.append(None if x is None else x+e["depth_range_start_m"])
                cls=geometry_class(obs,oracle["rays"],tol)
                if not cal["target_0_10m_met"]:cls="CALIBRATION_TARGET_UNMET"
            out.append({"id":ident,"video_count":len(indices),"group_status":state,"class":cls,"observed_m":obs,"draw_proxy_ms":(f["post_draw_ticks_us"]-e["brush_call_ticks_us"])/1000})
        matches=[x for x in out if x["class"]=="CSG_POST_MATCH"]
        result.append({"index":e["index"],"add":e["add"],"oracle":oracle,"frames":out,"first_sampled_csg_match":matches[0] if matches else None,"first_correct_presented_pixel_ms":None})
    report={"schema":"a8_p82_depth_v1","video_sha256":sha(video),"trace_sha256":sha(traces[0]),"etw_csv_sha256":sha(folder/"a7_presentmon.csv"),"decoded_video_frames":len(pts),"calibration":cal,"calibration_points":points,"geometry_model_tolerance_m":tol,"etw_clock_shift_s":shift,"edits":result,"strict_edit_100":"NOT_QUALIFIED","limitations":["Estimated calibration budget, not a global depth error bound","Independent CSG predicts from pre-brush local lattice; not native brush equivalence nor exact mesh topology","No exact ETW/frame-ID join or HID-to-photon timing","Missing, conflicting and persistent IDs excluded; no interpolation outside calibration range"]}
    (root/"a8_p82_depth_report.json").write_text(json.dumps(report,indent=2,allow_nan=False),encoding="utf-8")
    return report

if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("campaign",type=Path);p.add_argument("--ffmpeg",required=True);p.add_argument("--ffprobe",required=True);a=p.parse_args()
    r=audit(a.campaign,a.ffmpeg,a.ffprobe)
    print("A8_P82 "+json.dumps({"calibration":r["calibration"],"sampled_matches":sum(e["first_sampled_csg_match"] is not None for e in r["edits"]),"strict":r["strict_edit_100"]}))
