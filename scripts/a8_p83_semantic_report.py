#!/usr/bin/env python3
"""Semantic depth diagnostic. Mask and metric samples share one video frame.
Never qualify EDIT-100 on incomplete rays, uncertain masks or ETW proxies.
"""
import argparse,collections,csv,json,math,statistics,subprocess
from pathlib import Path
from a7_video_timeline import locate_video,read_json
from a8_p8_edit_report import sha
from a8_p81_depth_report import decode_region,decode_stamp,median_patch,interpolate,parse_wall_as_utc,align_clock
from a8_p82_csg_oracle import evaluate
from a8_p82_depth_report import require

MASKS={"ROCK","WATER","NO_HIT","OUT_OF_RANGE","UNKNOWN","TERRAIN"}
OCCLUDERS={"ROCK","WATER"}
ROI_X,ROI_Y,W,H=908,488,104,104

def pixel_class(rgb):
    r,g,b=rgb
    if r>170 and g<85 and b<85:return "ROCK"
    if b>170 and r<85 and g<85:return "WATER"
    if g>170 and b>170 and r<85:return "NO_HIT"
    if r>170 and g>170 and b<85:return "OUT_OF_RANGE"
    if r>170 and b>170 and g<85:return "UNKNOWN"
    if max(rgb)-min(rgb)<=12 and 5<min(rgb) and max(rgb)<250:return "TERRAIN"
    return "AMBIGUOUS"

def patch_sample(blob,base,width,x,y):
    colors=[tuple(blob[base+3*((y+dy)*width+x+dx):base+3*((y+dy)*width+x+dx)+3]) for dy in (-1,0,1) for dx in (-1,0,1)]
    labels=[pixel_class(c) for c in colors]
    if len(set(labels))!=1:return ("AMBIGUOUS",None)
    kind=labels[0]
    return (kind,statistics.median(sum(c)/3 for c in colors) if kind=="TERRAIN" else None)

def decode_rgb(path,ffmpeg,crop):
    return subprocess.run([ffmpeg,"-v","error","-i",str(path),"-map","0:v:0","-vf",crop,"-fps_mode","passthrough","-pix_fmt","rgb24","-f","rawvideo","-"],capture_output=True,check=True,timeout=600).stdout

def calibration(samples):
    """Eleven distinct distances; alternate train and independent holdout.
    Holdout error across every captured panel frame, plus half a code step
    and the worst PNG/video discrepancy; conservative empirical budget.
    """
    require(len(samples)==11,"eleven depth panels required")
    train=[(statistics.median(s["gray"]),s["distance"]) for s in samples[::2]]
    require(all(b-a>=5 and y>x for (a,x),(b,y) in zip(train,train[1:])),"nonmonotonic calibration")
    step=max((y-x)/(b-a) for (a,x),(b,y) in zip(train,train[1:]))
    errors=[]
    for s in samples[1::2]:
        for g in s["gray"]:
            d=interpolate(g,train)
            require(d is not None,"holdout outside calibration")
            errors.append(abs(d-s["distance"]))
    discrepancy=max(abs(g-s["png_gray"])*step for s in samples for g in s["gray"])
    budget=max(errors)+step/2+discrepancy
    return train,{"fit_panels":6,"holdout_panels":5,"holdout_samples":len(errors),"holdout_max_m":max(errors),"max_quantization_step_m":step,"png_video_delta_bound_m":discrepancy,"estimated_error_budget_m":budget,"target_0_10m_met":budget<=0.10}

def select_rays(refs,probes,tol):
    return [i for i,(r,p) in enumerate(zip(refs,probes)) if (abs(p["pixel"][0]-960)>3 or abs(p["pixel"][1]-540)>3) and r["status"]=="PREDICTED" and abs(r["oracle_before_m"]-r["oracle_after_m"])>2*tol]

def pre_class(samples,expected,tol):
    if not samples:return "UNVERIFIED"
    if all(k=="TERRAIN" and d is not None and abs(d-expected)<=tol for k,d in samples):return "VERIFIED"
    # Only a directly measured, consistently identified geometric occluder
    # can remove a ray; a mixed or unknown mask is never an exclusion.
    if all(k in OCCLUDERS for k,_ in samples):return "OCCLUDED"
    return "UNVERIFIED"

def evaluate_frame(samples,refs,eligible,baseline,tol):
    count=collections.Counter()
    for i in eligible:
        k,d=samples[i];r=refs[i]
        if k in OCCLUDERS:count[k]+=1;continue
        if baseline[i]=="OCCLUDED":count["PRE_OCCLUDED_NOW_UNVERIFIED"]+=1;continue
        if baseline[i]!="VERIFIED":count["PRE_UNVERIFIED"]+=1;continue
        if k!="TERRAIN" or d is None:count["UNKNOWN"]+=1;continue
        a,b=r["oracle_before_m"],r["oracle_after_m"]
        if abs(d-b)<=tol and abs(d-a)>tol:count["POST"]+=1
        elif abs(d-a)<=tol and abs(d-b)>tol:count["PRE"]+=1
        else:count["MISMATCH"]+=1
    visible=sum(count[k] for k in ("POST","PRE","MISMATCH"))
    needed=max(2,math.ceil(len(eligible)/2))
    if len(eligible)<2:label="INSUFFICIENT_INDEPENDENT_RAYS"
    elif count["PRE_UNVERIFIED"] or any(baseline[i]=="UNVERIFIED" for i in eligible):label="PRE_DEPTH_UNVERIFIED"
    elif count["UNKNOWN"] or count["PRE_OCCLUDED_NOW_UNVERIFIED"]:label="INCOMPLETE_TERRAIN_EVIDENCE"
    elif visible<needed:label="OCCLUDED_OR_INSUFFICIENT_COVERAGE"
    elif count["POST"]==visible:label="CSG_POST_MATCH"
    elif count["PRE"]==visible:label="CSG_PRE_MATCH"
    else:label="MIXED_OR_UNCERTAIN"
    return label,dict(count),visible,needed

def group_state(indices,pts,raw):
    if not indices:return "MISSING"
    if indices!=list(range(indices[0],indices[-1]+1)):return "NONCONTIGUOUS_ID"
    if (pts[indices[-1]]-pts[indices[0]])*1000>34.000001:return "PERSISTENT_ID"
    for ray in zip(*raw):
        if len({k for k,_ in ray})!=1:return "CONFLICTING_MASK"
        vals=[v for _,v in ray if v is not None]
        if vals and max(vals)-min(vals)>2:return "CONFLICTING_DEPTH"
    return "STABLE"

def audit(root,ffmpeg,ffprobe):
    manifest=read_json(root/"visual_evidence_manifest.json")
    require(all(manifest.get(k) is True for k in ("a8_p83_semantic_requested","a8_p82_precision_requested","video_capture_valid_container","presentmon_capture_valid","game_run_succeeded")) and manifest.get("nvenc_cq_requested")==10,"invalid acquisition")
    traces=list((root/"game").rglob("a7_edits.jsonl"))
    require(len(traces)==1,"one edit trace required")
    folder=traces[0].parent
    rows=[json.loads(l) for l in traces[0].read_text(encoding="utf-8-sig").splitlines() if l.strip()]
    meta=rows[0];edits=[r for r in rows if r.get("type")=="edit"]
    require(meta.get("a8_p83_semantic") is True and meta.get("warmup_drawn_frames")==1000 and not meta.get("in_engine_stills_enabled") and meta.get("radius_m")==1.5,"invalid runtime provenance")
    require([e["index"] for e in edits]==list(range(12)) and all(e.get("accepted") for e in edits),"12 accepted edits required")
    require(read_json(folder/"a7_foreground.json").get("continuity_verified") is True,"foreground unverified")
    video=locate_video(root,manifest);require(video is not None,"video missing")
    pts=[float(x["best_effort_timestamp_time"]) for x in json.loads(subprocess.run([ffprobe,"-v","error","-select_streams","v:0","-show_entries","frame=best_effort_timestamp_time","-of","json",str(video)],capture_output=True,check=True,timeout=600).stdout)["frames"]]
    require(pts and all(math.isfinite(v) for v in pts) and all(b>=a for a,b in zip(pts,pts[1:])),"invalid PTS")
    stamps=decode_region(video,ffmpeg,"crop=336:24:24:22",336,24)
    depth=decode_rgb(video,ffmpeg,f"crop={W}:{H}:{ROI_X}:{ROI_Y}")
    require(len(stamps)==len(pts)*8064 and len(depth)==len(pts)*W*H*3,"decoded frame count mismatch")
    def sample(j,x,y):
        require(ROI_X+1<=x<=ROI_X+W-2 and ROI_Y+1<=y<=ROI_Y+H-2,"pixel outside ROI")
        return patch_sample(depth,j*W*H*3,W,x-ROI_X,y-ROI_Y)
    by_id=collections.defaultdict(list)
    for j in range(len(pts)):
        ident=decode_stamp([median_patch(stamps,j*8064,336,10+i*24,12) for i in range(14)])
        if ident is not None:by_id[ident].append(j)
    def panel_indices(c):
        ids=by_id[c["stamp_id"]]
        require(len(ids)>=4 and ids==list(range(ids[0],ids[-1]+1)),"calibration stamp missing or noncontiguous")
        return ids[1:-1]
    def png_sample(c):
        blob=decode_rgb(folder/c["file"],ffmpeg,"crop=8:8:956:512")
        require(len(blob)==192,"bad calibration PNG")
        return patch_sample(blob,0,8,4,4)
    panels=[]
    for k,c in enumerate(meta["depth_calibration"]):
        require(c["stamp_id"]==3900+k and c["range_start_m"]==9.0 and c["pixel"]==[960,516],"bad calibration metadata")
        values=[sample(j,960,516) for j in panel_indices(c)]
        pk,pg=png_sample(c)
        require(pk=="TERRAIN" and all(v[0]=="TERRAIN" for v in values),"terrain mask calibration failed")
        panels.append({"distance":float(c["distance_m"])-9,"gray":[v[1] for v in values],"png_gray":pg})
    points,cal=calibration(panels)
    mask_checks=[]
    for k,c in enumerate(meta["mask_calibration"]):
        label=["ROCK","WATER","UNKNOWN"][k]
        require(c["stamp_id"]==3920+k and c["expected"]==label and c["pixel"]==[960,516],"bad mask calibration metadata")
        values=[sample(j,960,516)[0] for j in panel_indices(c)]
        require(png_sample(c)[0]==label and all(v==label for v in values),"semantic mask calibration failed: "+label)
        mask_checks.append({"class":label,"decoded_samples":len(values),"passed":True})
    require(len(mask_checks)==3,"three mask calibration panels required")
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
        probes=e["probe_rays"]
        require(len(probes)==25 and len({tuple(p["pixel"]) for p in probes})==25 and e["stamp_invalidated_epoch_s"]>=e["camera_hold_end_epoch_s"],"invalid observation trace")
        oracle=evaluate(e,meta["radius_m"])
        refs=oracle["rays"]
        require(len(refs)==25,"CSG ray count mismatch")
        eligible=select_rays(refs,probes,tol)
        def measure(raw):
            vals=[]
            for k,g in raw:
                d=interpolate(g,points) if k=="TERRAIN" else None
                vals.append((k,None if d is None else d+e["depth_range_start_m"]))
            return vals
        def read_frame(j):return [sample(j,*map(round,p["pixel"])) for p in probes]
        pre_ids=by_id[e["index"]*64+1]
        pre_ok=len(pre_ids)>=3 and pre_ids==list(range(pre_ids[0],pre_ids[-1]+1))
        pre=[measure(read_frame(j)) for j in pre_ids[1:-1]] if pre_ok else []
        baseline={i:pre_class([v[i] for v in pre],refs[i]["oracle_before_m"],tol) for i in eligible}
        frames=e["depth_frames"];ids=[f["id"] for f in frames]
        require(ids==list(range(e["index"]*64+2,e["index"]*64+2+len(ids))) and ids and ids[-1]<e["index"]*64+64,"bad frame IDs")
        counters=collections.Counter(f["drawn_frame"] for f in frames)
        out=[]
        for f in frames:
            ident=f["id"];indices=by_id[ident]
            samples=[read_frame(j) for j in indices]
            state=group_state(indices,pts,samples)
            if counters[f["drawn_frame"]]!=1:state="DUPLICATE_ENGINE_COUNTER"
            require(f["pre_draw_epoch_s"]<=f["post_draw_epoch_s"]<=e["camera_hold_end_epoch_s"] and f["post_draw_ticks_us"]>=e["brush_call_ticks_us"],"invalid draw timestamp")
            obs=None;cls=None;candidate=None;counts={};visible=0;needed=max(2,math.ceil(len(eligible)/2))
            if state=="STABLE":
                obs=measure(samples[0])
                candidate,counts,visible,needed=evaluate_frame(obs,refs,eligible,baseline,tol)
                cls=candidate if cal["target_0_10m_met"] else "CALIBRATION_TARGET_UNMET"
            out.append({"id":ident,"video_count":len(indices),"group_status":state,"class":cls,"exploratory_class":candidate,"ray_counts":counts,"visible_eligible":visible,"minimum_visible_eligible":needed,"observations":obs,"draw_proxy_ms":(f["post_draw_ticks_us"]-e["brush_call_ticks_us"])/1000})
        matches=[x for x in out if x["class"]=="CSG_POST_MATCH"]
        exploratory=[x for x in out if x["exploratory_class"]=="CSG_POST_MATCH"]
        result.append({"index":e["index"],"add":e["add"],"oracle":oracle,"eligible_ray_indices":eligible,"pre_depth_status":baseline,"pre_depth_capture_count":len(pre_ids),"frames":out,"first_sampled_csg_match":matches[0] if matches else None,"first_exploratory_match":exploratory[0] if exploratory else None,"first_correct_presented_pixel_ms":None})
    report={"schema":"a8_p83_semantic_v1","video_sha256":sha(video),"trace_sha256":sha(traces[0]),"etw_csv_sha256":sha(folder/"a7_presentmon.csv"),"decoded_video_frames":len(pts),"calibration":cal,"calibration_points":points,"mask_calibration":mask_checks,"geometry_model_tolerance_m":tol,"etw_clock_shift_s":shift,"edits":result,"strict_edit_100":"NOT_QUALIFIED","limitations":["Diagnostic opaque water plane, not normal transparency; all object geometry and physics retained","Empirical calibration budget not a global bound","CSG local lattice model not exact mesh topology","No exact ETW/frame-ID join or HID-to-photon latency","Only directly identified rock/water occlusions excluded; at least half of eligible rays and at least two must remain visible"]}
    (root/"a8_p83_semantic_report.json").write_text(json.dumps(report,indent=2,allow_nan=False),encoding="utf-8")
    return report

if __name__=="__main__":
    p=argparse.ArgumentParser();p.add_argument("campaign",type=Path);p.add_argument("--ffmpeg",required=True);p.add_argument("--ffprobe",required=True);a=p.parse_args()
    r=audit(a.campaign,a.ffmpeg,a.ffprobe)
    print("A8_P83 "+json.dumps({"calibration":r["calibration"],"sampled_matches":sum(e["first_sampled_csg_match"] is not None for e in r["edits"]),"strict":r["strict_edit_100"]}))
