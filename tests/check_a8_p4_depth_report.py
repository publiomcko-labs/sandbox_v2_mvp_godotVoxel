"""A8-P4 negative controls: provenance, 1000 warmup, GL depth calibration,
per-pixel/SDF 130m classification, PNG presence, and strict gate fail-closed.
Synthetic PNGs test only report contracts, NOT actual renderer accuracy.
"""
from __future__ import annotations
import copy
import json
import struct
import sys
import tempfile
import zlib
from pathlib import Path

root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/"scripts"))
from a8_p4_depth_report import analyze

def png_bytes(rgb):
    # Valid 1920x1080 24-bit PNG, constant color, built with stdlib.
    w,h=1920,1080
    data=(b"\0"+bytes(rgb)*w)*h
    def chunk(kind,body):
        return (struct.pack(">I",len(body))+kind+body+
                struct.pack(">I",zlib.crc32(kind+body)&0xffffffff))
    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR",struct.pack(">IIBBBBB",w,h,8,2,0,0,0))+
            chunk(b"IDAT",zlib.compress(data,6))+chunk(b"IEND",b""))

with tempfile.TemporaryDirectory() as td:
    d=Path(td)
    calibration=[{
        "panel_camera_distance_m":v,
        "observed_center_category":color,
        "expected_center_category":color,
        "pixel_rgb":rgb,
        "png":f"a8p4_calibration_{int(v):03d}m.png",
        "passed":True
    } for v,color,rgb in ((25.0,"DEPTH_INSIDE_130",[0,1,0]),
                          (165.0,"DEPTH_OUTSIDE_130",[1,0,0]))]
    (d/"a8p4_calibration_025m.png").write_bytes(png_bytes([0,255,0]))
    (d/"a8p4_calibration_165m.png").write_bytes(png_bytes([255,0,0]))
    normal=png_bytes([100,170,90])
    raster=png_bytes([0,255,0])
    observations=[]
    for i in range(8):
        rgb=f"a8p4_heading_{i:02d}_rgb.png"
        depth=f"a8p4_heading_{i:02d}_depth.png"
        (d/rgb).write_bytes(normal)
        (d/depth).write_bytes(raster)
        samples=[]
        counters={v:0 for v in ("DEPTH_INSIDE_130","DEPTH_BORDERLINE_130",
                               "DEPTH_OUTSIDE_130","DEPTH_NO_OPAQUE_HIT",
                               "DEPTH_INVALID_COLOR")}
        matching=missing=0
        for y in (280,400,520,640,760):
            for x in (240,480,720,960,1200,1440,1680):
                # Force a single negative on heading 0 for observed discrepancy.
                category="DEPTH_OUTSIDE_130" if i==0 and x==240 and y==280 else "DEPTH_INSIDE_130"
                matching+=(category=="DEPTH_INSIDE_130")
                missing+=(category!="DEPTH_INSIDE_130")
                counters[category]+=1
                samples.append({
                    "pixel_1080":[x,y],"sdf_category":"SDF_INSIDE_130",
                    "sdf_horizontal_m":80.0,
                    "rendered_depth_category":category,
                    "rgb_depth":[0,1,0] if category=="DEPTH_INSIDE_130" else [1,0,0],
                    "sampled_agreement":category=="DEPTH_INSIDE_130"
                })
        observations.append({
            "heading_index":i,"yaw_deg":-45.0*i,
            "player_xyz":[192.0,22.0,18.0],
            "camera_pitch_deg":-22.0,"camera_fov_deg":75.0,
            "sample_count":35,"samples":samples,
            "rgb_image":rgb,"depth_image":depth,
            "observed_depth_categories":counters,
            "expected_ground_inside_130_sampled":35,
            "depth_inside_130_sampled":matching,
            "expected_ground_inside_and_depth_inside":matching,
            "expected_ground_inside_but_depth_not_inside":missing
        })
    fixture={
        "schema":"a8_p4_opaque_depth_evidence_v1",
        "source_baseline":"A5_CPU16_GL_COMPATIBILITY",
        "world_seed":20261119,"camera_origin_xyz":[192.,22.,18.],
        "warmup_frames_requested":1000,"warmup_frames_observed":1000,
        "warmup_elapsed_s":16.7,"renderer":"gl_compatibility","driver":"opengl3",
        "capture_size_px":[1920,1080],"headings":8,"horizontal_radius_m":130.,
        "margin_m":1.,"pixels_per_heading":35,
        "calibrations":calibration,"observations":observations,
        "ground_expected_inside_130_samples":280,
        "ground_expected_inside_and_depth_inside":279,
        "ground_expected_inside_but_depth_not_inside":1,
        "ground_reference":"SDF_RAYCAST_EXPECTED_NOT_MESH",
        "raster_reference":"POST_OPAQUE_REAL_GL_DEPTH_TEXTURE_UNPROJECTED",
        "rocks_water_hidden_during_capture":True,"hud_hidden":True,
        "screenshot_readback_perf_invalid":True,
        "stationary_probe_only_no_continuous_18mps_video":True,
        "opaque_depth_not_object_identity":True,
        "sample_coverage_not_full_screen_guarantee":True,
        "perf_60":"NOT_QUALIFIED","stream_18":"NOT_QUALIFIED",
        "view_130":"NOT_QUALIFIED","edit_100":"NOT_QUALIFIED",
        "automatic_acceptance":False,
    }
    (d/"a8_p4_depth_evidence.json").write_text(json.dumps(fixture),encoding="utf-8")
    r=analyze(d)
    assert r["assessment"]=="SAMPLED_RENDERED_DEPTH_MISMATCH_OBSERVED"
    assert r["expected_ground_not_matched_with_rendered_depth"]==1
    assert r["expected_ground_matched_with_rendered_depth"]==279
    assert len(r["pngs"])==18 and r["view_130"]=="NOT_QUALIFIED"
    assert r["pixel_coverage_360_full_screen_qualified"] is False
    assert r["automatic_acceptance"] is False

    def reject(change):
        invalid=copy.deepcopy(fixture)
        change(invalid)
        try:
            analyze(d,invalid)
        except ValueError:
            return
        raise AssertionError("A8-P4 accepted invalid source/geometry/pixel gate")

    reject(lambda f:f.__setitem__("warmup_frames_observed",999))
    reject(lambda f:f["calibrations"][1].__setitem__("passed",False))
    reject(lambda f:f.__setitem__("renderer","gl_core"))
    reject(lambda f:f.__setitem__("automatic_acceptance",True))
    reject(lambda f:f.__setitem__("view_130","PASS"))
    reject(lambda f:f["observations"][3].__setitem__("yaw_deg",-180.0))
    reject(lambda f:f["observations"][0]["samples"][0].__setitem__("sdf_horizontal_m",145.0))
    reject(lambda f:f["observations"][0]["samples"][0].__setitem__("sampled_agreement",True))
    reject(lambda f:f["observations"][0]["samples"][0].__setitem__("pixel_1080",[-1,280]))
    reject(lambda f:f["observations"][1]["samples"].pop())
    reject(lambda f:f["observations"][1].__setitem__("expected_ground_inside_but_depth_not_inside",1))
    reject(lambda f:f.__setitem__("rocks_water_hidden_during_capture",False))
    (d/"a8p4_heading_07_depth.png").unlink()
    try:
        analyze(d)
        raise AssertionError("Accepted missing depth PNG")
    except ValueError: pass

runner=(root/"godot/tests/a8_p4_depth_capture.gd").read_text(encoding="utf-8")
shader=(root/"godot/shaders/a8_p4_depth_130.gdshader").read_text(encoding="utf-8")
launcher=(root/"scripts/a8-p4-depth-windows.ps1").read_text(encoding="utf-8")
assert "hint_depth_texture" in shader
assert "CURRENT_RENDERER == RENDERER_COMPATIBILITY" in shader
assert "INV_VIEW_MATRIX * INV_PROJECTION_MATRIX" in shader
assert "depth_draw_never, depth_test_disabled" in shader
assert 'var _warmup_observed := 0' in runner
assert "Engine.get_frames_drawn()-initial_frames" in runner
assert "A8_P4_OUTPUT_DIR" in runner and "A3_SAVE_PATH" in launcher
assert "real Compatibility OpenGL3 GPU renderer required" in runner
assert "25.0, 165.0" in runner
assert "get_texture().get_image()" in runner
assert "A8_P4_REQUIRES_INTERACTIVE_REAL_OPENGL_DESKTOP_NOT_RUNNER" in launcher
assert "WaitForExit(180000)" in launcher
print("A8_P4_CALIBRATED_DEPTH_AND_PIXEL_CONTRACT_FAIL_CLOSED_PASS")
