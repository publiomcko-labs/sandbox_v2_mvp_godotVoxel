#!/usr/bin/env python3
"""A8-P3: fail-closed offline report of independently generated SDF ray hits.

The 60 source pixels were selected from original A8-P2 video. Even accurate
generator hits are NOT rendered-depth, voxel mesh publication or proof that
an observed color pop belongs to a specific LOD block.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

SCHEMA = "a8_p3_procedural_depth_oracle_v1"
HASH = "1488b6208f47d62f8c9070cf8896e2af0d97c2cbdf440d1bf7df5377f99f621b"
FRAME_IDS = (1289, 1700, 2112, 2381, 2805)
TIMES = (3.616,10.716,17.816,22.600,29.733)
CLASSES = ("SDF_INSIDE_130","SDF_OUTSIDE_130",
           "SDF_BORDERLINE_130","UNKNOWN_NO_SDF_HIT")


def req(test: bool, message: str):
    if not test:
        raise ValueError("A8_P3_INVALID: "+message)


def finite(v):
    return (type(v) in (int,float) and math.isfinite(v))


def triage(d: dict) -> dict:
    req(isinstance(d,dict) and d.get("schema")==SCHEMA,"schema")
    req(d.get("source_video_sha256")==HASH,"original source video SHA-256")
    req(d.get("route")=="turns_18mps_300s" and d.get("world_seed")==20261119,"route/seed")
    req(d.get("screen")==[1920,1080] and d.get("sampled_pixel_count")==60,"screen/pixel count")
    req(d.get("event_count")==5 and d.get("sdf_raycast_stride_m")==0.5,"event count/stride")
    req(d.get("horizontal_boundary_m")==130.0 and d.get("classification_margin_m")==1.0,"130m threshold/margin")
    req(d.get("oracle")=="INDEPENDENT_GENERATOR_SDF_APPROX_NOT_RENDERED_MESH","oracle source")
    for k in ("rendered_pixel_depth_measured","mesh_publication_timing_measured",
              "automatic_acceptance"):
        req(d.get(k) is False,k+" must remain false")
    for k in ("strict_perf_60","strict_stream_18","strict_view_130","strict_edit_100"):
        req(d.get(k)=="NOT_QUALIFIED",k+" cannot be auto-qualified")
    events=d.get("events")
    req(isinstance(events,list) and len(events)==5,"five event rows")
    grand=dict.fromkeys(CLASSES,0)
    rendered={}
    all_positions=[]
    for idx,event in enumerate(events):
        req(isinstance(event,dict) and event.get("video_after_frame")==FRAME_IDS[idx],"frozen frame reference")
        t=event.get("route_t_s")
        req(finite(t) and abs(t-TIMES[idx])<0.0002,"frozen event clock")
        p=event.get("player_position_xyz")
        req(isinstance(p,list) and len(p)==3 and all(finite(x) for x in p),"player position")
        expected_x=18*min(t,20.0)
        expected_z=18+18*max(0,t-20.0)
        req(abs(p[0]-expected_x)<0.01 and abs(p[1]-22.0)<0.01 and
            abs(p[2]-expected_z)<0.01,"A7 route position")
        req(event.get("lod3_span_m")==128,"LOD3 spatial hypothesis must be 128m")
        target=event.get("ray_samples")
        req(isinstance(target,list) and len(target)==12,"twelve frozen sample rays")
        observed=dict.fromkeys(CLASSES,0)
        unique=set()
        distances=[]
        for row in target:
            req(isinstance(row,dict),"ray sample row")
            pixel=row.get("pixel_1080")
            req(isinstance(pixel,list) and len(pixel)==2 and
                all(type(x) is int for x in pixel) and
                0<=pixel[0]<1920 and 0<=pixel[1]<1080,"pixel xy")
            req(tuple(pixel) not in unique,"duplicate pixel")
            unique.add(tuple(pixel))
            c=row.get("classification")
            req(c in CLASSES,"classification")
            hit=row.get("ground_hit_xyz")
            h=row.get("ground_horizontal_m")
            radial=row.get("raycast_distance_m")
            block=row.get("ground_expected_lod3_block_xz")
            if c=="UNKNOWN_NO_SDF_HIT":
                req(hit is None and h is None and radial is None and block is None,
                    "no-hit must not fabricate depth")
            else:
                req(isinstance(hit,list) and len(hit)==3 and all(finite(x) for x in hit),
                    "procedural SDF hit XYZ")
                req(finite(h) and h>=0 and finite(radial) and radial>=0 and radial<=320,
                    "finite ray distances")
                actual_h=math.hypot(hit[0]-p[0],hit[2]-p[2])
                req(abs(actual_h-h)<=0.01,"hit horizontal distance consistency")
                req(block==[math.floor(hit[0]/128),math.floor(hit[2]/128)],
                    "LOD3 block grid of SDF hit")
                expected=("SDF_INSIDE_130" if h <129 else
                          "SDF_OUTSIDE_130" if h >131 else
                          "SDF_BORDERLINE_130")
                req(c==expected,"130m boundary classification mismatch")
                distances.append(h)
            observed[c]+=1
            grand[c]+=1
        req(event.get("classification_counts")==observed,"per-event counts contradict individual rays")
        result={
            "frame":FRAME_IDS[idx], "t_s":t,
            "camera_xz_m":[p[0],p[2]],
            "sampled":12,"classifications":observed,
            "min_hit_horizontal_m":round(min(distances),3) if distances else None,
            "max_hit_horizontal_m":round(max(distances),3) if distances else None,
            "spatial_inference":(
                "SOME_SAMPLED_SDF_GROUND_INSIDE_130" if observed["SDF_INSIDE_130"] else
                "NO_SAMPLED_INSIDE_130_BUT_UNSAMPLED_PIXELS_UNKNOWN")
        }
        all_positions.append(result)
        rendered[FRAME_IDS[idx]]=observed
    req(d.get("counts")==grand,"global counts contradict event rows")
    conclusion=(
        "EXPECTED_GROUND_INSIDE_130_SAMPLED" if grand["SDF_INSIDE_130"] else
        "SAMPLED_GROUND_NOT_WITHIN_130_UNQUALIFIED")
    return {
        "schema":"a8_p3_procedural_depth_triage_v1",
        "video_sha256":HASH,
        "overall_inference":conclusion,
        "sample_count":60,
        "sampled_counts":grand,
        "event_rows":all_positions,
        "ground_source":"SDF_GENERATOR_APPROX_NOT_RENDERED_DEPTH",
        "depth_is_independent_of_actual_renderer":False,
        "mesh_publication_causally_verified":False,
        "lod3_spatial_correlation_only":True,
        "unsampled_pixels_unknown":True,
        "video_pts_alignment_error_ms_p99":14,
        "strict_perf_60":"NOT_QUALIFIED",
        "strict_stream_18":"NOT_QUALIFIED",
        "strict_view_130":"NOT_QUALIFIED",
        "strict_edit_100":"NOT_QUALIFIED",
        "automatic_acceptance":False,
        "next_decision":"If sampled expected terrain lies within 130m, test actual LOD3 visible/mesh state at five pre-registered event windows. Otherwise retain UNKNOWN for unsampled world geometry, not PASS."
    }


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("input_json",type=Path)
    args=ap.parse_args()
    d=triage(json.loads(args.input_json.read_text(encoding="utf-8-sig")))
    out=args.input_json.with_name("a8_p3_triage.json")
    if out.exists():
        raise FileExistsError("A8-P3 will not overwrite existing triage")
    out.write_text(json.dumps(d,ensure_ascii=False,indent=2),encoding="utf-8")
    print("A8_P3_TRIAGE "+json.dumps({
        "counts":d["sampled_counts"],
        "inference":d["overall_inference"],
        "gates":"NOT_QUALIFIED",
        "events":[(x["frame"],x["classifications"]) for x in d["event_rows"]]
    },ensure_ascii=False))


if __name__=="__main__":
    main()
