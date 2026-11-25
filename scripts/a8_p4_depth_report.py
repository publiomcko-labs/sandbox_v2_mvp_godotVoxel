#!/usr/bin/env python3
"""A8-P4: validate actual GPU opaque-depth photographs vs independent SDF.

No claim of full-screen, continuous STREAM-18, multi-seed, water/rock or
performance qualification. 1000 drawn warmup frames and near/far depth
calibration MUST be present. Unexpected/corrupt evidence fails closed.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import math
import struct
from pathlib import Path

SCHEMA="a8_p4_opaque_depth_evidence_v1"
WIDTH,HEIGHT=1920,1080
COLUMNS=(240,480,720,960,1200,1440,1680)
ROWS=(280,400,520,640,760)
DEPTH_CLASSES=("DEPTH_INSIDE_130","DEPTH_BORDERLINE_130",
               "DEPTH_OUTSIDE_130","DEPTH_NO_OPAQUE_HIT","DEPTH_INVALID_COLOR")
SDF_CLASSES=("SDF_INSIDE_130","SDF_BORDERLINE_130","SDF_OUTSIDE_130","SDF_NO_HIT")
EXPECTED_SOURCE="A5_CPU16_GL_COMPATIBILITY"


def require(condition: bool, message: str):
    if not condition:
        raise ValueError("A8_P4_REJECTED "+message)


def finite(v):
    return type(v) in (int,float) and math.isfinite(v)


def inspect_png(path: Path) -> dict:
    require(path.is_file(), "missing PNG "+path.name)
    with path.open("rb") as fd:
        header=fd.read(24)
        require(len(header)==24 and header[:8]==b"\x89PNG\r\n\x1a\n" and
                header[12:16]==b"IHDR", "not PNG "+path.name)
        width,height=struct.unpack(">II",header[16:24])
        require((width,height)==(WIDTH,HEIGHT),"wrong PNG size "+path.name)
        h=hashlib.sha256()
        h.update(header)
        for block in iter(lambda:fd.read(1<<20),b""):
            h.update(block)
    return {"name":path.name,"bytes":path.stat().st_size,"sha256":h.hexdigest()}


def analyze(root: Path, expected: dict | None = None) -> dict:
    evidence=json.loads((root/"a8_p4_depth_evidence.json").read_text(encoding="utf-8-sig")) if expected is None else expected
    d=evidence
    require(isinstance(d,dict) and d.get("schema")==SCHEMA,"schema")
    require(d.get("source_baseline")==EXPECTED_SOURCE and d.get("world_seed")==20261119,"A5 world/seed")
    require(d.get("camera_origin_xyz")==[192.0,22.0,18.0],"camera location")
    require(d.get("renderer")=="gl_compatibility" and d.get("driver")=="opengl3","GPU Compatibility only")
    require(d.get("capture_size_px")==[WIDTH,HEIGHT],"capture resolution")
    require(d.get("warmup_frames_requested")==1000 and type(d.get("warmup_frames_observed")) is int and
            d["warmup_frames_observed"]>=1000 and finite(d.get("warmup_elapsed_s")) and d["warmup_elapsed_s"]>0,
            "not 1000 drawn warmup frames")
    require(d.get("headings")==8 and d.get("pixels_per_heading")==len(COLUMNS)*len(ROWS),"8x35 sampling")
    require(d.get("horizontal_radius_m")==130.0 and d.get("margin_m")==1.0,"130m threshold")
    require(d.get("ground_reference")=="SDF_RAYCAST_EXPECTED_NOT_MESH" and
            d.get("raster_reference")=="POST_OPAQUE_REAL_GL_DEPTH_TEXTURE_UNPROJECTED",
            "independent ground/depth sources")
    require(d.get("rocks_water_hidden_during_capture") is True and
            d.get("hud_hidden") is True and
            d.get("screenshot_readback_perf_invalid") is True and
            d.get("stationary_probe_only_no_continuous_18mps_video") is True and
            d.get("opaque_depth_not_object_identity") is True and
            d.get("sample_coverage_not_full_screen_guarantee") is True,
            "disclosure of capture limits")
    for gate in ("perf_60","stream_18","view_130","edit_100"):
        require(d.get(gate)=="NOT_QUALIFIED",gate+" strict gate")
    require(d.get("automatic_acceptance") is False,"no automatic PASS")
    calibrations=d.get("calibrations")
    require(isinstance(calibrations,list) and len(calibrations)==2,"two depth calibrations")
    required_files={}
    for i,(distance,colour) in enumerate(((25.0,"DEPTH_INSIDE_130"),(165.0,"DEPTH_OUTSIDE_130"))):
        item=calibrations[i]
        require(isinstance(item,dict) and item.get("panel_camera_distance_m")==distance and
                item.get("observed_center_category")==colour and
                item.get("expected_center_category")==colour and
                item.get("passed") is True and
                item.get("png")==f"a8p4_calibration_{int(distance):03d}m.png",
                "depth calibration failure or fabricated calibration order")
        rgb=item.get("pixel_rgb")
        require(isinstance(rgb,list) and len(rgb)==3 and all(finite(x) for x in rgb),
                "depth calibration lacks actual RGB")
        required_files[item["png"]]=inspect_png(root/item["png"])

    shots=d.get("observations")
    require(isinstance(shots,list) and len(shots)==8,"eight heading observations")
    expected_total=matched_total=missed_total=0
    counts_by_heading=[]
    for i,row in enumerate(shots):
        require(isinstance(row,dict) and row.get("heading_index")==i and
                row.get("yaw_deg")==-45.0*i and
                row.get("player_xyz")==[192.0,22.0,18.0] and
                row.get("camera_pitch_deg")==-22.0 and
                finite(row.get("camera_fov_deg")) and abs(row["camera_fov_deg"]-75)<0.001,
                "heading position/yaw/FOV")
        require(row.get("sample_count")==35 and isinstance(row.get("samples"),list) and
                len(row["samples"])==35,"35 independent rays per heading")
        name1=f"a8p4_heading_{i:02d}_rgb.png"
        name2=f"a8p4_heading_{i:02d}_depth.png"
        require(row.get("rgb_image")==name1 and row.get("depth_image")==name2,"heading image identity")
        for name in (name1,name2):
            require(name not in required_files,"duplicate screenshot")
            required_files[name]=inspect_png(root/name)
        counters={key:0 for key in DEPTH_CLASSES}
        seen=set()
        inside=matched=missed=0
        for sample in row["samples"]:
            xy=sample.get("pixel_1080")
            require(isinstance(xy,list) and len(xy)==2 and
                    type(xy[0]) is int and type(xy[1]) is int and
                    xy[0] in COLUMNS and xy[1] in ROWS and
                    tuple(xy) not in seen,"frozen pixel center")
            seen.add(tuple(xy))
            sdf=sample.get("sdf_category")
            depth=sample.get("rendered_depth_category")
            require(sdf in SDF_CLASSES and depth in DEPTH_CLASSES,"pixel labels")
            rgb=sample.get("rgb_depth")
            require(isinstance(rgb,list) and len(rgb)==3 and
                    all(finite(x) and 0.0<=x<=1.0 for x in rgb),"RGB readback")
            require(isinstance(sample.get("sampled_agreement"),bool),"agreement flag")
            require(sample["sampled_agreement"] ==
                    (sdf=="SDF_INSIDE_130" and depth=="DEPTH_INSIDE_130"),"agreement mismatch")
            h=sample.get("sdf_horizontal_m")
            if sdf=="SDF_NO_HIT":
                require(h is None,"SDF_NO_HIT must not invent distance")
            else:
                require(finite(h) and 0<=h<=320.2,"SDF horizontal meters")
                label=("SDF_INSIDE_130" if h<129.0 else
                       "SDF_OUTSIDE_130" if h>131.0 else "SDF_BORDERLINE_130")
                require(sdf==label,"SDF 130m label not consistent")
            if sdf=="SDF_INSIDE_130":
                inside+=1
                if depth=="DEPTH_INSIDE_130":
                    matched+=1
                else:
                    missed+=1
            counters[depth]+=1
        require(len(seen)==35,"missing frozen pixels")
        require(row.get("observed_depth_categories")==counters,"category counters")
        require(row.get("expected_ground_inside_130_sampled")==inside and
                row.get("expected_ground_inside_and_depth_inside")==matched and
                row.get("expected_ground_inside_but_depth_not_inside")==missed and
                matched+missed==inside,"per-heading comparison counts")
        expected_total+=inside
        matched_total+=matched
        missed_total+=missed
        counts_by_heading.append({
            "heading_index":i,
            "expected_sdf_inside_130":inside,
            "actual_depth_inside_at_expected_pixels":matched,
            "actual_depth_not_inside_at_expected_pixels":missed,
            "depth_categories":counters
        })
    require(d.get("ground_expected_inside_130_samples")==expected_total and
            d.get("ground_expected_inside_and_depth_inside")==matched_total and
            d.get("ground_expected_inside_but_depth_not_inside")==missed_total and
            matched_total+missed_total==expected_total,"global comparison counts")
    require(expected_total>0,"no evaluable expected terrain inside 130m")
    require(len(required_files)==18,"eight normal/depth pairs plus two calibrations")
    result={
        "schema":"a8_p4_130m_depth_review_v1",
        "world":"A5_CPU16_GL_COMPATIBILITY",
        "headings":8,"depth_calibration":"PASSED_25M_AND_165M",
        "warmup_drawn_frames":d["warmup_frames_observed"],
        "sampled_pixels":280,"expected_ground_inside_130":expected_total,
        "expected_ground_matched_with_rendered_depth":matched_total,
        "expected_ground_not_matched_with_rendered_depth":missed_total,
        "headings_evidence":counts_by_heading,
        "pngs":list(required_files.values()),
        "assessment":"SAMPLED_RENDERED_DEPTH_MISMATCH_OBSERVED" if missed_total else
                     "NO_MISMATCH_ON_SAMPLED_GROUND_ONLY",
        "continuous_18mps_qualified":False,
        "pixel_coverage_360_full_screen_qualified":False,
        "water_and_rocks_qualified":False,
        "full_gpu_present_qualified":False,
        "rendered_depth_is_opaque_scene_not_terrain_object_id":True,
        "sampled_depth_color_has_passed_known_distance_calibration":True,
        "view_130":"NOT_QUALIFIED","stream_18":"NOT_QUALIFIED",
        "perf_60":"NOT_QUALIFIED","edit_100":"NOT_QUALIFIED",
        "automatic_acceptance":False,
        "limits":[
            "Static 8 headings and 35 pixels per heading, not complete 360-degree temporal continuity",
            "Opaque depth does not identify the terrain mesh or other depth-writing 3D objects",
            "Ground SDF is expected pre-edit terrain, not ground truth depth from rasterized mesh",
            "Readback/overlays cause substantial GPU workload, excluded from FPS/present comparison",
            "No rocks/water/HUD are present in evidence arm",
            "Renderer depth unprojection must pass 25m/165m calibration on target GTX1050Ti",
        ]
    }
    return result


def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("folder",type=Path)
    args=ap.parse_args()
    result=analyze(args.folder)
    target=args.folder/"a8_p4_review.json"
    if target.exists():
        raise FileExistsError("Refusing to overwrite review")
    target.write_text(json.dumps(result,indent=2,ensure_ascii=False),encoding="utf-8")
    print("A8_P4_DEPTH_REVIEW "+json.dumps({
        "calibrated":True,"expected_130":result["expected_ground_inside_130"],
        "matched":result["expected_ground_matched_with_rendered_depth"],
        "mismatched":result["expected_ground_not_matched_with_rendered_depth"],
        "headings":8,"gates":"NOT_QUALIFIED"},ensure_ascii=False))


if __name__=="__main__":
    main()
