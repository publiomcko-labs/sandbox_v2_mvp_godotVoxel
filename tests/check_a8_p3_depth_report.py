"""A8-P3: static frozen-pixel source and fail-closed synthetic SDF depth tests."""
from __future__ import annotations

import copy
import json
import math
import sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/"scripts"))
from a8_p3_depth_report import triage, HASH, FRAME_IDS, TIMES, CLASSES

fixture=json.loads((root/"godot/tests/fixtures/a8_p3_video_pixel_targets.json").read_text())
assert fixture["source_video_sha256"]==HASH
assert fixture["event_count"]==5 and fixture["ray_samples_per_event"]==12
assert fixture["screen_px"]==[1920,1080]
assert fixture["route"]=="turns_18mps_300s" and fixture["seed"]==20261119
assert [e["after_frame"] for e in fixture["events"]]==list(FRAME_IDS)
assert [e["route_t_s"] for e in fixture["events"]]==list(TIMES)
for e in fixture["events"]:
    assert len(e["pixels_px"])==12
    assert len({tuple(p) for p in e["pixels_px"]})==12
    assert all(0<=x<1920 and 0<=y<1080 for x,y in e["pixels_px"])
    assert 0 < e["changed_sky_to_terrain_pixels_downscaled"] < 960*540

# Generated ray data is synthetic and tests only auditing; it does NOT
# represent the original video's actual pixel depths.
events=[]
grand=dict.fromkeys(CLASSES,0)
for ev in fixture["events"]:
    t=ev["route_t_s"]
    pos=[round(18*min(t,20),3),22.0,round(18+18*max(0,t-20),3)]
    counts=dict.fromkeys(CLASSES,0)
    samples=[]
    for j,pixel in enumerate(ev["pixels_px"]):
        dist=(100.0,160.0,130.0,None)[j%4]
        cls=("SDF_INSIDE_130","SDF_OUTSIDE_130",
             "SDF_BORDERLINE_130","UNKNOWN_NO_SDF_HIT")[j%4]
        row={"pixel_1080":pixel,"classification":cls,
             "raycast_distance_m":None if dist is None else math.hypot(dist,20),
             "ground_horizontal_m":dist,
             "ground_hit_xyz":None if dist is None else [pos[0]+dist,2.0,pos[2]],
             "ground_expected_lod3_block_xz":None if dist is None else
                 [math.floor((pos[0]+dist)/128),math.floor(pos[2]/128)]}
        counts[cls]+=1
        grand[cls]+=1
        samples.append(row)
    events.append({"video_after_frame":ev["after_frame"],"route_t_s":t,
                   "player_position_xyz":pos,"lod3_span_m":128,
                   "ray_samples":samples,"classification_counts":counts})
sample={
    "schema":"a8_p3_procedural_depth_oracle_v1","source_video_sha256":HASH,
    "route":"turns_18mps_300s","world_seed":20261119,"screen":[1920,1080],
    "sampled_pixel_count":60,"event_count":5,
    "sdf_raycast_stride_m":0.5,"horizontal_boundary_m":130.0,
    "classification_margin_m":1.0,
    "oracle":"INDEPENDENT_GENERATOR_SDF_APPROX_NOT_RENDERED_MESH",
    "rendered_pixel_depth_measured":False,
    "mesh_publication_timing_measured":False,
    "automatic_acceptance":False,"counts":grand,"events":events,
    "strict_perf_60":"NOT_QUALIFIED","strict_stream_18":"NOT_QUALIFIED",
    "strict_view_130":"NOT_QUALIFIED","strict_edit_100":"NOT_QUALIFIED",
}
result=triage(sample)
assert result["sampled_counts"]["SDF_INSIDE_130"]==15
assert result["sampled_counts"]["SDF_OUTSIDE_130"]==15
assert result["sampled_counts"]["SDF_BORDERLINE_130"]==15
assert result["sampled_counts"]["UNKNOWN_NO_SDF_HIT"]==15
assert result["automatic_acceptance"] is False
assert result["strict_view_130"]=="NOT_QUALIFIED"

def reject(modify):
    bad=copy.deepcopy(sample)
    modify(bad)
    try:triage(bad)
    except ValueError:return
    raise AssertionError("accepted invalid A8-P3 source/geometry/gates")

reject(lambda x:x.__setitem__("rendered_pixel_depth_measured",True))
reject(lambda x:x.__setitem__("automatic_acceptance",True))
reject(lambda x:x.__setitem__("strict_view_130","PASS"))
reject(lambda x:x.__setitem__("source_video_sha256","different_video"))
reject(lambda x:x["events"][0].__setitem__("route_t_s",3.500))
reject(lambda x:x["events"][0]["ray_samples"][0].__setitem__("ground_horizontal_m",50))
reject(lambda x:x["events"][0]["ray_samples"][0].__setitem__("classification","SDF_OUTSIDE_130"))
reject(lambda x:x["events"][0]["ray_samples"][0].__setitem__("ground_expected_lod3_block_xz",[999,0]))
reject(lambda x:x["events"][0]["ray_samples"][0].__setitem__("pixel_1080",[-1,300]))
reject(lambda x:x["events"][0]["ray_samples"].pop())
reject(lambda x:x["counts"].__setitem__("SDF_INSIDE_130",16))
oracle=(root/"godot/tests/a8_p3_depth_oracle.gd").read_text()
assert "TerrainSDF.build_generator(SEED)" in oracle
assert "camera.project_ray_normal" in oracle
assert "generator.raycast_sdf_approx(" in oracle
assert "STRIDE_M := 0.5" in oracle
assert '"mesh_publication_timing_measured":false' in oracle
assert '"strict_view_130":"NOT_QUALIFIED"' in oracle
print("A8_P3_PIXEL_SOURCE_AND_SDF_DEPTH_FAIL_CLOSED_PASS")
