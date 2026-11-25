#!/usr/bin/env python3
"""Fail closed on A8-P6 source-pixel silhouette SDF triangulation.

Actual source green->blue transitions are frozen in a SHA-bound fixture;
the CPU-only native SDF oracle is independent of video depth.
"""
import argparse,json,math
from pathlib import Path

SHA="d553f73d1e94b279da972773a80972f94718791f14387a68b0ce4c1a05e449cb"
CLASSES=("SDF_INSIDE_120_STABLE","SDF_OUTSIDE_140_STABLE",
         "SDF_TEMPORAL_OR_BOUNDARY_UNKNOWN")
GATES=("strict_perf_60","strict_stream_18","strict_view_130","strict_edit_100")

def check(c,m):
    if not c:raise ValueError("A8_P6_SILHOUETTE_REJECTED "+m)

def validate(d,fixture):
    check(d.get("schema")=="a8_p6_11_silhouette_sdf_oracle_v1"
          and fixture.get("schema")=="a8_p6_silhouette_targets_v1"
          and d.get("video_sha256")==fixture.get("source_depth_video_sha256")==SHA
          and d.get("seed")==fixture.get("seed")==20261119,
          "video/seed provenance")
    check(d.get("event_count")==fixture.get("event_count")==11
          and len(d.get("events",[]))==len(fixture.get("events",[]))==11,
          "11 frozen events")
    check(d.get("source_event_fixture")==
          "res://tests/fixtures/a8_p6_silhouette_targets.json"
          and d.get("rendered_depth_is_only_from_source_video") is True
          and d.get("SDF_does_not_measure_mesh_publication") is True
          and d.get("temporal_gap_is_estimated_at_60hz") is True
          and d.get("camera_pose_reconstructed_not_recorded") is True,
          "source limitations")
    check(all(d.get(g)=="NOT_QUALIFIED" for g in GATES)
          and d.get("automatic_acceptance") is False,
          "no strict gate is qualified")
    counts={k:0 for k in CLASSES}
    for i,(item,original) in enumerate(zip(d["events"],fixture["events"])):
        check(item.get("source_video_frame")==original.get("original_video_frame")
              and item.get("video_pts_s")==original.get("video_pts_s")
              and item.get("route_t_s")==original.get("route_t_s")
              and item.get("pixel_1080")==original.get("pixel_1080")
              and item.get("before_rgb")==original.get("before_rgb")
              and item.get("after_rgb")==original.get("after_rgb")
              and item.get("source")=="GENERATOR_EXPECTED_NOT_GPU_MESH",
              "frozen source pixel #"+str(i))
        cm=[item.get(k) for k in (
            "sdf_prev_horizontal_cm","sdf_at_event_horizontal_cm",
            "sdf_next_horizontal_cm")]
        check(all(type(x) is int and -1<=x<=32050 for x in cm),
              "SDF centimeters missing or invalid")
        stable=all(v>=0 for v in cm) and max(cm)-min(cm)<=800
        name=("SDF_TEMPORAL_OR_BOUNDARY_UNKNOWN" if not stable else
              "SDF_INSIDE_120_STABLE" if cm[1]<12000 else
              "SDF_OUTSIDE_140_STABLE" if cm[1]>14000 else
              "SDF_TEMPORAL_OR_BOUNDARY_UNKNOWN")
        check(item.get("classification")==name,"SDF categorization #"+str(i))
        counts[name]+=1
    check(d.get("counts")==counts,"triage counts do not match 11 rays")
    return counts

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("report",type=Path)
    ap.add_argument("fixture",type=Path)
    args=ap.parse_args()
    data=json.loads(args.report.read_text(encoding="utf-8-sig"))
    fixture=json.loads(args.fixture.read_text(encoding="utf-8-sig"))
    counts=validate(data,fixture)
    print("A8_P6_SILHOUETTE_SOURCE_AND_ORACLE_VALIDATED "+json.dumps(counts))

if __name__=="__main__":main()
