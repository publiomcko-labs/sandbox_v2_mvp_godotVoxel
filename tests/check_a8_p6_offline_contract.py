"""A8-P6 CI: native 60Hz SDF format and offline video fail-closed contracts.

Synthetic fixtures validate parser/invariants only; no source MKV or real
GPU depth is available on the CPU-only GitHub runner.
"""
import copy
import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"scripts"))
from a8_p6_oracle_report import validate,EXPECTED_PIXELS
from a8_p6_offline_review import (category,route_time,matching_grid_index,
    confidence_reason,verify_source,SCHEMA,GREEN,BLUE,RED,UNKNOWN)

d={
    "schema":"a8_p6_sdf_60hz_v1","seed":20261119,
    "route":"turns_18mps_300s","duration_s":30,
    "fixed_fps":60,"frame_count":1800,
    "source":"A5_CPU16_PROCEDURAL_GENERATOR_RECONSTRUCTION",
    "screen_px":[1920,1080],
    "camera_fov_vertical_deg":75.0,"camera_pitch_deg":-22.0,
    "camera_raycast_stride_m":0.5,"max_ray_m":320.0,
    "pixel_grid_px":EXPECTED_PIXELS,
    "distance_units":"horizontal_centimeters","no_hit_sentinel":-1,
    "rays_cm":[[8000,11000,13500,6000,10000,-1,14000] for _ in range(1800)],
    "valid_sdf_hit_count":10800,"no_sdf_hit_count":1800,
    "source_video_not_provided_to_cpu_ci":True,
    "this_oracle_does_not_measure_rendered_mesh_or_pixels":True,
    "grid_time_can_differ_from_video_capture_pts":True,
    "strict_perf_60":"NOT_QUALIFIED",
    "strict_stream_18":"NOT_QUALIFIED",
    "strict_view_130":"NOT_QUALIFIED",
    "strict_edit_100":"NOT_QUALIFIED",
    "automatic_acceptance":False
}
assert validate(d)["fixed_rays"]==12600
def reject(edit):
    v=copy.deepcopy(d)
    edit(v)
    try:validate(v)
    except ValueError:return
    raise AssertionError("accepted invalid A8-P6 SDF fixture")
reject(lambda x:x["rays_cm"].pop())
reject(lambda x:x["rays_cm"][500].pop())
reject(lambda x:x["rays_cm"][0].__setitem__(0,999999))
reject(lambda x:x["rays_cm"][0].__setitem__(0,80.0))
reject(lambda x:x.__setitem__("strict_view_130","PASS"))
reject(lambda x:x.__setitem__("automatic_acceptance",True))
reject(lambda x:x.__setitem__("camera_pitch_deg",10.0))
reject(lambda x:x.__setitem__("pixel_grid_px",[[200,300]]))
reject(lambda x:x.__setitem__("source_video_not_provided_to_cpu_ci",False))
reject(lambda x:x.__setitem__("valid_sdf_hit_count",11100))

assert category(2,251,1)==GREEN
assert category(255,1,1)==RED
assert category(1,1,245)==BLUE
assert category(123,123,123)==UNKNOWN
markers=[{"video_pts_s":20.033+i} for i in range(31)]
assert abs(route_time(24.533,markers)-4.5)<1e-6
assert route_time(19.0,markers)<0
assert route_time(50.033,markers)==30.0
assert matching_grid_index(0.0)==0
assert matching_grid_index(10.0)==600
assert matching_grid_index(30.0)==1799
pts=[float(i)/60 for i in range(2000)]
assert confidence_reason(5.1,306,pts,305,100,1800)=="MAPPED_WITH_CONSERVATIVE_10M_MARGIN"
assert confidence_reason(20.01,1201,pts,1200,100,1800)=="TURN_POSE_UNCERTAIN"
assert confidence_reason(19.999,1200,pts,1199,100,1800)=="TURN_POSE_UNCERTAIN"
assert confidence_reason(5.0,300,pts,299,100,1800)=="HUD_MARKER_BOUNDARY"
dup=pts[:];dup[306]=dup[305]
assert confidence_reason(5.1,306,dup,305,100,1800)=="DUPLICATE_VIDEO_PTS"
assert confidence_reason(30.0,1799,pts,1798,100,1800)=="UNMAPPED_END_WINDOW"

runtime=(Path(__file__).resolve().parents[1]/"godot/tests/a8_p6_sdf_frame_oracle.gd").read_text()
assert 'const FRAME_COUNT := FPS * DURATION_S' in runtime
assert 'TerrainSDF.build_generator(SEED)' in runtime
assert 'generator.raycast_sdf_approx' in runtime
assert 'source_video_not_provided_to_cpu_ci' in runtime
assert 'automatic_acceptance":false' in runtime
script=(Path(__file__).resolve().parents[1]/"scripts/a8_p6_offline_review.py").read_text()
for anchor in ("POTENTIAL_MISSING_INSIDE_120","DUPLICATE_VIDEO_PTS",
               "UNMAPPED_END_WINDOW","GREEN","depth\\","all_frames.csv",
               "NOT_QUALIFIED"):
    if anchor!="depth\\":assert anchor in script,anchor
assert "documentation" not in SCHEMA
print("A8_P6_OFFLINE_FRAMES_AND_INDEPENDENT_SDF_FAIL_CLOSED_CONTRACT_PASS")
