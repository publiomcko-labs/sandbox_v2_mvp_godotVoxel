#!/usr/bin/env python3
"""A8-P5: CPU-only synchronized video-depth versus expected-terrain samples.

Only one decoded NVENC frame per HUD second, not every game-presented frame.
An observed red/blue/invalid depth where SDF expects terrain <125m is a
candidate, NOT an automatically proven visible streaming hole. No strict PASS.
"""
from __future__ import annotations
import argparse
import hashlib
import json
import math
import subprocess
from pathlib import Path
from a7_video_timeline import locate_video

SCHEMA="a8_p5_dynamic_depth_review_v1"
PIXELS=tuple((x,y) for y in (280,400,520,640,760)
                     for x in (240,480,720,960,1200,1440,1680))
N=30
WIDTH,HEIGHT=1920,1080
FRAME_BYTES=WIDTH*HEIGHT*3
SDF_CLASSES=("SDF_INSIDE_125","SDF_BOUNDARY_125_135",
             "SDF_OUTSIDE_135","SDF_NO_HIT")
DEPTH_CLASSES=("DEPTH_INSIDE_130","DEPTH_BORDERLINE_130",
               "DEPTH_OUTSIDE_130","DEPTH_NO_OPAQUE_HIT","DEPTH_INVALID_COLOR")


def check(ok,why):
    if not ok: raise ValueError("A8_P5_INVALID "+why)


def load(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def unique(root,name):
    paths=list(root.rglob(name))
    check(len(paths)==1,"Expected one "+name+" in "+str(root))
    return paths[0]


def category(rgb:tuple[int,int,int]) -> str:
    r,g,b=rgb
    # Wide bands tolerate mild 4:2:0 NVENC encoding differences; the
    # source shader is categorical, and ambiguous edge colors are UNKNOWN.
    if g>=180 and r<=100 and b<=100: return "DEPTH_INSIDE_130"
    if r>=180 and g>=180 and b<=100: return "DEPTH_BORDERLINE_130"
    if r>=180 and g<=100 and b<=100: return "DEPTH_OUTSIDE_130"
    if b>=180 and r<=100 and g<=100: return "DEPTH_NO_OPAQUE_HIT"
    return "DEPTH_INVALID_COLOR"


def classify_sample(sdf:dict,observed:str) -> dict:
    check(isinstance(sdf,dict),"SDF sample object")
    xy=sdf.get("pixel_1080")
    check(isinstance(xy,list) and len(xy)==2 and
          all(type(v) is int for v in xy),"SDF pixel XY")
    k=sdf.get("sdf_category")
    dist=sdf.get("sdf_horizontal_m")
    check(k in SDF_CLASSES and observed in DEPTH_CLASSES,"labels")
    if k=="SDF_NO_HIT":
        check(dist is None,"no-hit invented distance")
    else:
        check(type(dist) in (int,float) and math.isfinite(dist) and
              0<=dist<=320.5,"SDF distance")
        expected=("SDF_INSIDE_125" if dist<125 else
                  "SDF_BOUNDARY_125_135" if dist<=135 else "SDF_OUTSIDE_135")
        check(k==expected,"inconsistent 5m boundary classification")
    return {
        "pixel_1080":xy, "sdf_horizontal_m":dist,
        "sdf_category":k, "depth_video_category":observed,
        "risk":(
            "POTENTIAL_MISSING_DEPTH_WITHIN_125"
            if k=="SDF_INSIDE_125" and observed!="DEPTH_INSIDE_130"
            else "SAMPLED_EXPECTED_NEAR_GROUND_PRESENT"
            if k=="SDF_INSIDE_125" else "NO_INSIDE_125_ASSERTION"
        )
    }


def manifest_and_route(root:Path,depth:bool):
    m=load(root/"visual_evidence_manifest.json")
    g=load(root/"game"/"manifest.json")
    r=load(unique(root/"game","a7_route.json"))
    t=load(root/"a7_video_timeline.json")
    check(m.get("schema")=="a7_visual_evidence_manifest_v1" and
          m.get("scenario")=="turns_18mps_300s" and m.get("seed")==20261119 and
          m.get("mode")=="Route" and
          m.get("warmup_frames_requested")==1000 and
          m.get("a8_visual_evidence_requested") is True and
          m.get("a8_p5_depth_video_requested") is depth and
          m.get("game_run_succeeded") is True and
          m.get("video_capture_valid_container") is True and
          m.get("recorder_mode")=="ddagrab_nvenc" and
          m.get("video_capture_region_xywh")==[0,0,1920,1080] and
          m.get("video_fps_requested")==60 and
          m.get("in_engine_screenshot_interval_s")==0 and
          m.get("strict_gates")=="NOT_QUALIFIED","A7 visual manifest")
    check(g.get("baseline_checkpoint")=="0c3fee959576d0a1faec9ceecffb4b132a65558b" and
          g.get("mesh_block_voxels")==16 and g.get("lod_count")==4 and
          g.get("target_speed_mps")==18.0 and g.get("seeds")==[20261119] and
          g.get("capture") is True and
          g.get("warmup_frames_requested")==1000 and
          g.get("a8_p5_depth_video_requested") is depth and
          g.get("full") is False and g.get("repeats")==1,
          "A5 CPU16 provenance")
    check(r.get("schema")=="a7_route_v1" and r.get("route")=="turns_18mps_300s" and
          r.get("seed")==20261119 and r.get("duration_s")==30.0 and
          r.get("a8_visual_evidence") is True and
          r.get("a8_p5_depth_video") is depth and
          r.get("capture") is True and
          r.get("warmup_drawn_frames_requested")==1000 and
          type(r.get("warmup_drawn_frames_observed")) is int and
          r["warmup_drawn_frames_observed"]>=1000 and
          r.get("screenshots")==0 and
          all(r.get(k)=="NOT_QUALIFIED" for k in
              ("perf_60_full_present_gate","stream_18_pixel_gate",
               "view_130_pixel_depth_gate")),"route summary + no inline GPU readbacks")
    if depth:
        cal=r.get("a8_p5_depth_calibrations")
        check(isinstance(cal,list) and len(cal)==2 and
              all(isinstance(x,dict) and x.get("passed") is True and
                  x.get("distance_m")==distance and x.get("observed")==label
                  for x,distance,label in zip(cal,(25.0,165.0),
                      ("DEPTH_INSIDE_130","DEPTH_OUTSIDE_130"))),
              "GPU depth video real calibration")
        check(r.get("a8_p5_sdf_samples") in (30,31),
              "missing 30 ground expectations")
    check(t.get("schema")=="a7_video_timeline_v1" and
          t.get("source_mode")=="Route" and
          t.get("pixel_terrain_correctness_verified") is False and
          t.get("depth_coverage_verified") is False and
          t.get("strict_stream_18")=="NOT_QUALIFIED" and
          t.get("strict_view_130")=="NOT_QUALIFIED",
          "video timeline limits")
    marks=t.get("marker",{})
    aligned=marks.get("aligned_events")
    window=t.get("route_movement_window")
    check(marks.get("sequence_verified") is True and
          marks.get("alignment_verified") is True and
          isinstance(aligned,list) and len(aligned)==31 and
          all(x.get("event_index")==i for i,x in enumerate(aligned)) and
          type(marks.get("offset_residual_p99_ms")) in (int,float) and
          0<=marks["offset_residual_p99_ms"]<=50.0 and
          isinstance(window,dict) and window.get("frames",0)>=1200 and
          28.0<=window.get("elapsed_pts_s",0)<=31.0,
          "HUD markers incomplete or video clock invalid")
    video=locate_video(root,m)
    check(video is not None and video.is_file() and video.stat().st_size==m["video_bytes"] and
          video.stat().st_size>1000000,"video missing or modified")
    trace=[json.loads(line) for line in unique(root/"game","a7_route.jsonl").read_text(encoding="utf-8-sig").splitlines() if line.strip()]
    expectations=[x for x in trace if x.get("type")=="a8_p5_sdf_expectation"]
    check((len(expectations) in (30,31)) if depth else not expectations,
          "unexpected missing/original depth expectation trace")
    return m,g,r,t,aligned,video,expectations


def frame_indices(marks:list[dict]) -> list[tuple[int,int,float]]:
    indices=[]
    used=set()
    for i in range(N):
        curr,nxt=marks[i],marks[i+1]
        here,next_frame=curr["video_frame_index"],nxt["video_frame_index"]
        check(type(here) is int and type(next_frame) is int and
              here+1<next_frame,"missing frames between adjacent sync markers")
        chosen=here+2 if here+2<next_frame else here+1
        dt=marks[i+1]["video_pts_s"]-curr["video_pts_s"]
        check(type(dt) in (int,float) and 0.6<=dt<=1.4,
              "video marker PTS spacing not 1s-ish")
        check(chosen not in used,"duplicate sampling frame index")
        used.add(chosen)
        indices.append((i,chosen,curr["video_pts_s"]))
    return indices


def decode_selected(ffmpeg:str,video:Path,indices:list[tuple[int,int,float]]) -> list[bytes]:
    ordered=[x[1] for x in indices]
    check(ordered==sorted(ordered) and len(set(ordered))==N,"decoder selection order")
    # Select actual frames by original decoder n; NO resampling or frame
    # interpolation. Each 1080p RGB decoded frame is only used in memory.
    filt="select='"+ "+".join(f"eq(n\\,{i})" for i in ordered)+"'"
    cmd=[ffmpeg,"-hide_banner","-loglevel","error","-nostdin",
         "-i",str(video),"-map","0:v:0","-vf",filt,
         "-fps_mode","passthrough","-f","rawvideo","-pix_fmt","rgb24","pipe:1"]
    output=subprocess.run(cmd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                          timeout=600,check=True).stdout
    check(len(output)==N*FRAME_BYTES,
          f"decoded original selection count bytes={len(output)} expected={N*FRAME_BYTES}")
    return [output[i*FRAME_BYTES:(i+1)*FRAME_BYTES] for i in range(N)]


def assess(root:Path,ffmpeg:str,decode:bool=True) -> dict:
    rgb,depth=root/"rgb",root/"depth"
    rm,rg,rr,rt,rx,rv,rs=manifest_and_route(rgb,False)
    dm,dg,dr,dt,dx,dv,ds=manifest_and_route(depth,True)
    check(rm["git_sha"]==dm["git_sha"]==rg["git_sha"]==dg["git_sha"],
          "different Git commits across paired arms")
    check(rm["seed"]==dm["seed"] and rm["duration_override_s"]==dm["duration_override_s"],
          "different routes across arms")
    expectations={}
    for sample in ds:
        i=sample.get("index")
        check(type(i) is int and i not in expectations and 0<=i<=30 and
              sample.get("sample_count")==35 and
              sample.get("ground_source")=="GENERATOR_ONLY_NOT_RENDERED" and
              sample.get("video_synchronization")=="HUD_MARKER_AND_NVENC_PTS_APPROXIMATE",
              "unexpected SDF ground snapshot")
        pos=sample.get("player_xyz")
        t=sample.get("route_t_s")
        check(type(t) in (int,float) and i<=t<i+0.3 and
              isinstance(pos,list) and len(pos)==3 and
              all(type(x) in (int,float) and math.isfinite(x) for x in pos) and
              abs(pos[0]-min(t*18,360))<0.2 and
              abs(pos[2]-(18+max(0,t-20)*18))<0.2,
              "sample route position not canonical")
        pixels=sample.get("samples")
        check(isinstance(pixels,list) and len(pixels)==35 and
              [tuple(x.get("pixel_1080",[])) for x in pixels]==list(PIXELS),
              "incorrect/altered 35 frozen sample grid")
        expectations[i]=sample
    check(all(i in expectations for i in range(N)),
          "missing one or more seconds of moving expected ground evidence")
    selectors=frame_indices(dx)
    raw_frames=decode_selected(ffmpeg,dv,selectors) if decode else []
    records=[]
    counts={"expected_inside_125":0,"inside_125_depth_present":0,
            "inside_125_potential_missing_depth":0,
            "depth_invalid_colors":0,"unknown_outside_required_scope":0}
    for i,selected,_pts in selectors:
        frame=raw_frames[i] if decode else None
        snap=expectations[i]
        compare=[]
        for pixel in snap["samples"]:
            x,y=pixel["pixel_1080"]
            observed=(category(tuple(frame[3*(y*WIDTH+x):3*(y*WIDTH+x)+3]))
                      if decode else "DEPTH_INVALID_COLOR")
            item=classify_sample(pixel,observed)
            compare.append(item)
            counts["depth_invalid_colors"]+=observed=="DEPTH_INVALID_COLOR"
            counts["unknown_outside_required_scope"]+=item["risk"]=="NO_INSIDE_125_ASSERTION"
            if pixel["sdf_category"]=="SDF_INSIDE_125":
                counts["expected_inside_125"]+=1
                if observed=="DEPTH_INSIDE_130":
                    counts["inside_125_depth_present"]+=1
                else:
                    counts["inside_125_potential_missing_depth"]+=1
        records.append({
            "index":i,"video_frame_index":selected,
            "video_marker_pts_s":dx[i]["video_pts_s"],
            "video_marker_alignment_residual_ms":dx[i]["offset_residual_ms"],
            "route_t_s":snap["route_t_s"],
            "player_xyz":snap["player_xyz"],
            "expected_inside_125":snap["expected_inside_125"],
            "potential_missing_depth_pixels":[x for x in compare
                if x["risk"]=="POTENTIAL_MISSING_DEPTH_WITHIN_125"],
            "samples":compare
        })
    check(not decode or counts["expected_inside_125"]>0,
          "no evaluable expected terrain inside 125m")
    hashes={}
    for label,path in (("rgb",rv),("depth",dv)):
        h=hashlib.sha256()
        with path.open("rb") as stream:
            for block in iter(lambda:stream.read(1<<20),b""):h.update(block)
        hashes[label]={"sha256":h.hexdigest(),"bytes":path.stat().st_size}
    return {
        "schema":SCHEMA,"seed":20261119,"route":"turns_18mps_300s",
        "target_speed_mps":18.0,"duration_s":30,
        "warmup_frames_each_arm":1000,
        "source_git_sha":rm["git_sha"],
        "video_hashes":hashes,
        "depth_calibration":dr["a8_p5_depth_calibrations"],
        "synchronized_marker_count_each_arm":31,
        "rgb_video_fps":rt["route_movement_window"]["observed_fps"],
        "depth_video_fps":dt["route_movement_window"]["observed_fps"],
        "rgb_video_gap_over_33ms":rt["route_movement_window"]["gaps_over_33ms"],
        "depth_video_gap_over_33ms":dt["route_movement_window"]["gaps_over_33ms"],
        "depth_marker_residual_p99_ms":dt["marker"]["offset_residual_p99_ms"],
        "selected_frames":N if decode else 0,
        "samples_per_second":35,
        "counts":counts if decode else None,
        "seconds":records,
        "assessment":("POTENTIAL_IN_RADIUS_MISSING_DEPTH_REQUIRES_FRAME_REVIEW"
            if decode and counts["inside_125_potential_missing_depth"]>0 else
            "NO_MISSING_DEPTH_IN_SAMPLED_VIDEO_FRAMES_WITH_CAPTURE_LIMITATIONS"),
        "rgb_video_directly_matches_same_depth_frame":False,
        "actual_terrain_object_id_verified":False,
        "unobserved_frames_and_pixels_qualified":False,
        "rock_water_simultaneous_publication_verified":False,
        "video_is_presentmon_independent":False,
        "fps_measured_without_recorder":False,
        "strict_perf_60":"NOT_QUALIFIED",
        "strict_stream_18":"NOT_QUALIFIED",
        "strict_view_130":"NOT_QUALIFIED",
        "strict_edit_100":"NOT_QUALIFIED",
        "automatic_acceptance":False,
        "limitations":[
            "Depth and RGB are separate deterministic runs; no true same-frame color/depth alignment",
            "H.264 color categories are lossy; any mismatch is a candidate, not a proven temporal hole",
            "Only first decodable frame after each HUD marker, 30 instants from 30s total",
            "Video PTS duplicates and losses can hide transient holes in unobserved frames",
            "SDF ray is independent expected procedural ground, not actual mesh pixel identity",
            "Depth texture records opaque geometry, not transparent water or all rocks",
            "Temporal SDF and depth sample separated by camera travel; ±5m conservative distance margin",
            "External NVENC recording and extra per-second SDF work invalidate canonical FPS comparison"
        ]
    }


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("folder",type=Path)
    ap.add_argument("--ffmpeg",required=True)
    args=ap.parse_args()
    result=assess(args.folder,args.ffmpeg)
    target=args.folder/"a8_p5_review.json"
    check(not target.exists(),"refuse overwrite")
    target.write_text(json.dumps(result,ensure_ascii=False,indent=2),encoding="utf-8")
    print("A8_P5_DYNAMIC_DEPTH_REVIEW "+json.dumps({
        "expected_inside_125":result["counts"]["expected_inside_125"],
        "compatible":result["counts"]["inside_125_depth_present"],
        "candidates":result["counts"]["inside_125_potential_missing_depth"],
        "depth_fps":result["depth_video_fps"],
        "gates":"NOT_QUALIFIED"}))


if __name__=="__main__":
    main()
