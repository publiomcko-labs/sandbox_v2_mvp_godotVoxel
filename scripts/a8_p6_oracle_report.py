#!/usr/bin/env python3
"""Fail-closed A8-P6 native CPU SDF oracle validation.

The oracle reconstructs expected procedural ground at 60Hz; it NEVER
measures actual GPU pixel, mesh publication or true presented-frame cadence.
"""
import argparse
import json
import math
from pathlib import Path

EXPECTED_PIXELS=[[240,400],[960,400],[1680,400],
                 [480,640],[960,640],[1440,640],[960,760]]
GATES=("strict_perf_60","strict_stream_18","strict_view_130","strict_edit_100")
SCHEMA="a8_p6_sdf_60hz_v1"

def check(cond,reason):
    if not cond: raise ValueError("A8_P6_ORACLE_REJECTED "+reason)

def validate(d:dict) -> dict:
    check(isinstance(d,dict) and d.get("schema")==SCHEMA,"schema")
    check(d.get("seed")==20261119 and d.get("route")=="turns_18mps_300s"
          and d.get("duration_s")==30 and d.get("frame_count")==1800
          and d.get("fixed_fps")==60,"fixed route and 60Hz grid")
    check(d.get("source")=="A5_CPU16_PROCEDURAL_GENERATOR_RECONSTRUCTION"
          and d.get("screen_px")==[1920,1080]
          and d.get("camera_fov_vertical_deg")==75.0
          and d.get("camera_pitch_deg")==-22.0
          and d.get("camera_raycast_stride_m")==0.5
          and d.get("max_ray_m")==320.0
          and d.get("pixel_grid_px")==EXPECTED_PIXELS
          and d.get("distance_units")=="horizontal_centimeters"
          and d.get("no_hit_sentinel")==-1,"provenance and geometry")
    check(d.get("source_video_not_provided_to_cpu_ci") is True
          and d.get("this_oracle_does_not_measure_rendered_mesh_or_pixels") is True
          and d.get("grid_time_can_differ_from_video_capture_pts") is True,
          "must retain oracle limitations")
    check(all(d.get(g)=="NOT_QUALIFIED" for g in GATES)
          and d.get("automatic_acceptance") is False,
          "strict gates may never auto-pass")
    rays=d.get("rays_cm")
    check(isinstance(rays,list) and len(rays)==1800,"all 1800 timepoints")
    hits=nohits=0
    for i,row in enumerate(rays):
        check(isinstance(row,list) and len(row)==7,"seven samples at frame "+str(i))
        for cm in row:
            check(type(cm) is int and (cm==-1 or 0<=cm<=32050),
                  "non-integer, out-of-range SDF at "+str(i))
            if cm==-1: nohits+=1
            else: hits+=1
    check(d.get("valid_sdf_hit_count")==hits and
          d.get("no_sdf_hit_count")==nohits and hits>0
          and hits+nohits==12600,"ray counts and ground presence")
    return {"schema":"a8_p6_oracle_validation_v1","frames":1800,
            "fixed_rays":12600,"valid_ground_hits":hits,
            "no_hits":nohits,"gates":"NOT_QUALIFIED"}

def main():
    p=argparse.ArgumentParser()
    p.add_argument("oracle",type=Path)
    args=p.parse_args()
    result=validate(json.loads(args.oracle.read_text(encoding="utf-8-sig")))
    print("A8_P6_EXPECTED_SDF_VALIDATED "+json.dumps(result,sort_keys=True))

if __name__=="__main__":main()
