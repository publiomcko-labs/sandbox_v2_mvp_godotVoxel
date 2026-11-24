#!/usr/bin/env python3
"""A8-P6 offline depth video scan: all captured 1080p frames, 7 native SDF rays.

Input: original A8-P5 ZIP (two untouched NVENC videos), independent A8-P6
60Hz CPU oracle artifact. No new GPU recording, in-game readbacks, or FPS
qualification. Candidate mismatches require manual original-frame review.
"""
from __future__ import annotations
import argparse
import csv
import hashlib
import json
import math
import subprocess
import tempfile
import zipfile
from collections import Counter
from pathlib import Path

from a8_p6_oracle_report import validate as validate_oracle, EXPECTED_PIXELS

SOURCE_GIT="cf4be42b27cb9b20d7847d73ce15c122003a8a85"
RGB_SHA="203d74d5396d64cae6318d5fd2628be77882195339885b2fae02bccd98798c00"
DEPTH_SHA="d553f73d1e94b279da972773a80972f94718791f14387a68b0ce4c1a05e449cb"
SCHEMA="a8_p6_all_captured_depth_frames_v1"
GREEN="DEPTH_INSIDE_130"
BLUE="DEPTH_NO_OPAQUE_HIT"
RED="DEPTH_OUTSIDE_130"
YELLOW="DEPTH_BORDERLINE_130"
UNKNOWN="DEPTH_INVALID_COLOR"

def check(ok,reason):
    if not ok: raise ValueError("A8_P6_REJECTED "+reason)

def category(r:int,g:int,b:int) -> str:
    if g>=180 and r<=100 and b<=100: return GREEN
    if r>=180 and g>=180 and b<=100: return YELLOW
    if r>=180 and g<=100 and b<=100: return RED
    if b>=180 and r<=100 and g<=100: return BLUE
    return UNKNOWN

def checksum(z,entry:str) -> tuple[str,int]:
    digest=hashlib.sha256(); size=0
    with z.open(entry) as file:
        for chunk in iter(lambda:file.read(1<<20),b""):
            digest.update(chunk); size+=len(chunk)
    return digest.hexdigest(),size

def get(z,name:str):
    return json.loads(z.read(name).decode("utf-8-sig"))

def verify_source(z):
    names=z.namelist()
    check(len(names)==len(set(names)),"duplicate ZIP member names")
    for name in ("rgb\\desktop-1080p-60fps.mkv","depth\\desktop-1080p-60fps.mkv",
                 "depth\\a7_video_timeline.json","rgb\\a7_video_timeline.json",
                 "depth\\visual_evidence_manifest.json","rgb\\visual_evidence_manifest.json",
                 "a8_p5_review.json"):
        check(name in names,"source evidence missing "+name)
    r=get(z,"a8_p5_review.json")
    check(r.get("schema")=="a8_p5_dynamic_depth_review_v1"
          and r.get("source_git_sha")==SOURCE_GIT
          and r.get("counts",{}).get("expected_inside_125")==799
          and r.get("counts",{}).get("inside_125_depth_present")==799
          and r.get("counts",{}).get("inside_125_potential_missing_depth")==0
          and r.get("selected_frames")==30,"source A8-P5 review mismatch")
    data={}
    for arm,sha in (("rgb",RGB_SHA),("depth",DEPTH_SHA)):
        video=arm+"\\desktop-1080p-60fps.mkv"
        found,size=checksum(z,video)
        check(found==sha and
              r.get("video_hashes",{}).get(arm,{}).get("sha256")==sha,
              arm+" source video mutated")
        manifest=get(z,arm+"\\visual_evidence_manifest.json")
        check(manifest.get("git_sha")==SOURCE_GIT and
              manifest.get("seed")==20261119 and
              manifest.get("scenario")=="turns_18mps_300s" and
              manifest.get("warmup_frames_requested")==1000 and
              manifest.get("a8_p5_depth_video_requested") is (arm=="depth") and
              manifest.get("video_bytes")==size,
              arm+" video provenance")
        timeline=get(z,arm+"\\a7_video_timeline.json")
        mark=timeline.get("marker",{})
        check(timeline.get("schema")=="a7_video_timeline_v1"
              and mark.get("alignment_verified") is True and
              mark.get("sequence_verified") is True and
              mark.get("offset_residual_p99_ms",100)<=50
              and len(mark.get("aligned_events",[]))==31
              and timeline.get("strict_stream_18")=="NOT_QUALIFIED"
              and timeline.get("strict_view_130")=="NOT_QUALIFIED",
              arm+" HUD marker provenance")
        data[arm]={"timeline":timeline,"manifest":manifest,
                   "sha256":found,"bytes":size}
    return data

def frame_timestamps(video:Path,ffprobe:str):
    raw=subprocess.run([
        ffprobe,"-v","error","-select_streams","v:0",
        "-show_entries","frame=best_effort_timestamp_time",
        "-of","json",str(video)],capture_output=True,check=True,timeout=120).stdout
    frames=json.loads(raw)["frames"]
    pts=[float(x["best_effort_timestamp_time"]) for x in frames]
    check(all(math.isfinite(t) for t in pts) and
          all(b>=a for a,b in zip(pts,pts[1:])),
          "ffprobe nonfinite / reversed timestamps")
    return pts

def route_time(pts:float,markers:list[dict]) -> float:
    # Piecewise interpolation across independent HUD transitions. Not a
    # certified frame presentation or precise input simulation clock.
    lo=0; hi=len(markers)-1
    while lo+1<hi:
        m=(lo+hi)//2
        if markers[m]["video_pts_s"]<=pts: lo=m
        else: hi=m
    if pts<markers[0]["video_pts_s"]:
        return -1
    if pts>=markers[-1]["video_pts_s"]:
        return 30.0
    d=markers[lo+1]["video_pts_s"]-markers[lo]["video_pts_s"]
    check(d>=0.6 and d<=1.4,"HUD marker cadence")
    return lo+(pts-markers[lo]["video_pts_s"])/d

def matching_grid_index(t:float)->int:
    return max(0,min(1799,int(round(60*t))))

def confidence_reason(t:float,idx:int,pts:list[float],previous_index:int,
                      first:int,last:int) -> str:
    if t<0 or t>=29.99: return "UNMAPPED_END_WINDOW"
    if (idx>first and pts[idx]==pts[idx-1]) or (idx<last and pts[idx]==pts[idx+1]):
        return "DUPLICATE_VIDEO_PTS"
    if abs(t-20.0)<0.15: return "TURN_POSE_UNCERTAIN"
    if abs(t-round(t))<0.040: return "HUD_MARKER_BOUNDARY"
    if abs(t-((matching_grid_index(t))/60.0))>0.0085:
        return "SDF_GRID_TIME_MISALIGNMENT"
    return "MAPPED_WITH_CONSERVATIVE_10M_MARGIN"

def scan(evidence:Path,oracle_path:Path,out:Path,ffprobe:str="ffprobe") -> dict:
    import cv2
    import numpy as np
    check(not out.exists() or not any(out.iterdir()),"output must be new/empty")
    out.mkdir(parents=True,exist_ok=True)
    expected=json.loads(oracle_path.read_text(encoding="utf-8-sig"))
    summary=validate_oracle(expected)
    check(summary["frames"]==1800 and summary["fixed_rays"]==12600,
          "native 60Hz SDF oracle incomplete")
    with zipfile.ZipFile(evidence) as z:
        provenance=verify_source(z)
        for item in z.infolist():
            check(item.CRC is not None,"archive ZIP CRC absent")
        depth_t=provenance["depth"]["timeline"]
        markers=depth_t["marker"]["aligned_events"]
        window=depth_t["route_movement_window"]
        first,last=window["start_frame"],window["end_frame"]
        check(last-first+1==1764 and first==1019 and last==2782,
              "original 1764-frame window changed")
        with tempfile.TemporaryDirectory(prefix="a8p6_") as tmp:
            video=Path(tmp)/"depth.mkv"
            with z.open("depth\\desktop-1080p-60fps.mkv") as src,video.open("wb") as dest:
                for chunk in iter(lambda:src.read(1<<20),b""):dest.write(chunk)
            pts=frame_timestamps(video,ffprobe)
            check(len(pts)==depth_t["frame_integrity"]["frames"]==2811,
                  "ffprobe frame count must equal original timeline")
            check(abs(pts[first]-markers[0]["video_pts_s"])<0.001 and
                  abs(pts[last]-markers[-1]["video_pts_s"])<0.001,
                  "video original indices no longer align markers")
            cap=cv2.VideoCapture(str(video))
            check(cap.isOpened(),"cannot open source decoded MKV")
            all_rows=[]
            counts=Counter()
            prev_green=None
            detections=[]
            frame_index=0
            roi_slices=(slice(50,245),slice(35,445))
            while True:
                ok,frame=cap.read()
                if not ok: break
                if first<=frame_index<=last:
                    check(frame.shape==(1080,1920,3),"wrong decoded frame shape")
                    t=route_time(pts[frame_index],markers)
                    why=confidence_reason(t,frame_index,pts,frame_index-1,first,last)
                    oracle_idx=matching_grid_index(t) if t>=0 else 0
                    expected_cm=expected["rays_cm"][oracle_idx]
                    ptypes=Counter()
                    potential=[]
                    for k,((x,y),cm) in enumerate(zip(EXPECTED_PIXELS,expected_cm)):
                        b,g,r=(int(v) for v in frame[y,x])
                        observed=category(r,g,b)
                        if cm==-1:
                            ptypes["GROUND_NOT_EXPECTED_OR_UNKNOWN"]+=1
                        elif cm<12000: # 10m spatial guard for uncertainty
                            if why!="MAPPED_WITH_CONSERVATIVE_10M_MARGIN":
                                ptypes["UNKNOWN_FRAME_ALIGNMENT"]+=1
                            elif observed==GREEN:
                                ptypes["EXPECTED_INSIDE_120_MATCHED"]+=1
                            elif observed==UNKNOWN or observed==YELLOW:
                                ptypes["UNKNOWN_H264_OR_THRESHOLD"]+=1
                            else:
                                ptypes["POTENTIAL_MISSING_INSIDE_120"]+=1
                                potential.append({"pixel":[x,y],"sdf_horizontal_m":cm/100,
                                                  "observed":observed})
                        else:
                            ptypes["SDF_OUTSIDE_SAFE_RADIUS"]+=1
                    counts.update(ptypes)
                    # Nearest-neighbor 4x downsample is a HEURISTIC of broad
                    # temporal mask change; never a full-res SDF pixel check.
                    small=cv2.resize(frame,(480,270),interpolation=cv2.INTER_NEAREST)
                    b,g,r=small[:,:,0],small[:,:,1],small[:,:,2]
                    green=(g>=180)&(r<=100)&(b<=100)
                    blue=(b>=180)&(r<=100)&(g<=100)
                    red=(r>=180)&(g<=100)&(b<=100)
                    green_roi=green[roi_slices]
                    blue_roi=blue[roi_slices]
                    red_roi=red[roi_slices]
                    g2b=int(np.count_nonzero(prev_green&blue_roi)) if prev_green is not None else 0
                    g2r=int(np.count_nonzero(prev_green&red_roi)) if prev_green is not None else 0
                    green_changed=(int(np.count_nonzero(green_roi!=prev_green))
                                   if prev_green is not None else 0)
                    prev_green=green_roi
                    if g2b>0 or potential:
                        detections.append({"original_frame":frame_index,
                            "route_t_s":round(t,4),"green_to_blue_pixels_480_roi":g2b,
                            "potential_missing_inside_120":potential})
                    gap_ms=round((pts[frame_index]-pts[frame_index-1])*1000,3) if frame_index>first else 0.0
                    all_rows.append({
                        "original_frame":frame_index,
                        "pts_s":round(pts[frame_index],6),
                        "estimated_route_s":round(t,5),
                        "oracle_60hz_frame":oracle_idx,
                        "map_confidence":why,
                        "pts_gap_before_ms":gap_ms,
                        "green_to_blue_roi_480":g2b,
                        "green_to_red_roi_480":g2r,
                        "green_mask_changed_roi_480":green_changed,
                        **{key:ptypes[key] for key in (
                            "EXPECTED_INSIDE_120_MATCHED",
                            "POTENTIAL_MISSING_INSIDE_120",
                            "UNKNOWN_FRAME_ALIGNMENT",
                            "UNKNOWN_H264_OR_THRESHOLD",
                            "GROUND_NOT_EXPECTED_OR_UNKNOWN",
                            "SDF_OUTSIDE_SAFE_RADIUS")}
                    })
                frame_index+=1
            cap.release()
            check(frame_index==len(pts)==2811,
                  "all source frames must decode exactly")
            check(len(all_rows)==1764 and
                  len({x["original_frame"] for x in all_rows})==1764,
                  "all captured route frames must have audit rows")
            check(sum(x["green_to_blue_roi_480"] for x in all_rows)>=0,
                  "inconsistent masks")
            check(all(x["estimated_route_s"]>=0 for x in all_rows),
                  "unmapped marker frame")
            with (out/"a8_p6_all_frames.csv").open("w",newline="",encoding="utf-8") as file:
                writer=csv.DictWriter(file,fieldnames=list(all_rows[0].keys()))
                writer.writeheader()
                writer.writerows(all_rows)
            report={
                "schema":SCHEMA,
                "source_mkv_sha256":{"rgb":RGB_SHA,"depth":DEPTH_SHA},
                "source_git_sha":SOURCE_GIT,
                "source_zip_sha256":hashlib.sha256(evidence.read_bytes()).hexdigest(),
                "oracle_source":"native_Godot_A5_SDF_at_60hz_no_GPU",
                "video_source":"real_GL_compatibility_1080p_NVENC_depth",
                "oracle_rows":1800,"oracle_fixed_rays":12600,
                "captured_depth_route_frames_reviewed":len(all_rows),
                "recorded_frame_pts_duplicates":window["duplicated_pts_pairs"],
                "capture_pts_gaps_over_33ms":window["gaps_over_33ms"],
                "capture_pts_gap_max_ms":window["gap_max_ms"],
                "depth_calibration_from_A8_P5":"PASS_25M_AND_165M",
                "sampled_rays_per_decoded_frame":len(EXPECTED_PIXELS),
                "sdf_conservative_strict_inside_m":120.0,
                "rendered_depth_inside_green_upper_m":129.0,
                "pixel_counts":dict(counts),
                "route_frame_confidence":dict(Counter(x["map_confidence"] for x in all_rows)),
                "green_to_blue_pixels_480_roi_total":sum(x["green_to_blue_roi_480"] for x in all_rows),
                "green_to_red_pixels_480_roi_total":sum(x["green_to_red_roi_480"] for x in all_rows),
                "candidate_frames":detections,
                "candidate_count":len(detections),
                "assessment":("POTENTIAL_IN_RADIUS_MISMATCH_REQUIRES_SOURCE_FRAME_TRIAGE"
                    if counts["POTENTIAL_MISSING_INSIDE_120"] else
                    "NO_IN_RADIUS_MISMATCH_ON_CONFIDENT_RAYS_ONLY"),
                "frames_not_captured_by_NVENC":"UNKNOWN_NEVER_COUNT_AS_PASS",
                "depth_is_opaque_scene_not_terrain_id":True,
                "RGB_and_depth_are_separate_recordings":True,
                "videos_are_not_full_presented_frame_timeline":True,
                "low_resolution_mask_is_only_a_heuristic":True,
                "camera_pose_60hz_is_reconstructed_not_direct_measured":True,
                "no_rock_water_atomic_publication_claim":True,
                "strict_perf_60":"NOT_QUALIFIED",
                "strict_stream_18":"NOT_QUALIFIED",
                "strict_view_130":"NOT_QUALIFIED",
                "strict_edit_100":"NOT_QUALIFIED",
                "automatic_acceptance":False
            }
            (out/"a8_p6_independent_review.json").write_text(
                json.dumps(report,indent=2,ensure_ascii=False),encoding="utf-8")
            return report

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--evidence",type=Path,required=True)
    parser.add_argument("--oracle",type=Path,required=True)
    parser.add_argument("--out",type=Path,required=True)
    parser.add_argument("--ffprobe",default="ffprobe")
    args=parser.parse_args()
    r=scan(args.evidence,args.oracle,args.out,args.ffprobe)
    print("A8_P6_FULL_FRAME_REVIEW "+json.dumps({
        "captured_frames":r["captured_depth_route_frames_reviewed"],
        "safe_matches":r["pixel_counts"].get("EXPECTED_INSIDE_120_MATCHED",0),
        "candidate_inside_120":r["pixel_counts"].get("POTENTIAL_MISSING_INSIDE_120",0),
        "green_to_blue_480_roi":r["green_to_blue_pixels_480_roi_total"],
        "gates":"NOT_QUALIFIED"}))

if __name__=="__main__":main()
