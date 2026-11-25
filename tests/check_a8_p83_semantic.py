import sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/"scripts"))
from a8_p83_semantic_report import pixel_class,patch_sample,calibration,pre_class,evaluate_frame,group_state,select_rays
for rgb,label in [((250,8,8),"ROCK"),((8,8,250),"WATER"),((7,250,250),"NO_HIT"),((250,250,7),"OUT_OF_RANGE"),((250,7,250),"UNKNOWN"),((132,130,134),"TERRAIN"),((150,30,30),"AMBIGUOUS")]:
    assert pixel_class(rgb)==label
assert patch_sample(bytes([250,8,8]*9),0,3,1,1)==("ROCK",None)
assert patch_sample(bytes([250,8,8]*8+[100,100,100]),0,3,1,1)==("AMBIGUOUS",None)
assert patch_sample(bytes([100,100,100]*9),0,3,1,1)==("TERRAIN",100)
s=[{"distance":i*.45,"gray":[20+20*i]*4,"png_gray":20+20*i} for i in range(11)]
assert calibration(s)[1]["target_0_10m_met"]
s[3]["gray"]=[89]*4
assert not calibration(s)[1]["target_0_10m_met"]
assert pre_class([("ROCK",None)]*3,10,.45)=="OCCLUDED"
assert pre_class([("WATER",None)]*3,10,.45)=="OCCLUDED"
assert pre_class([("TERRAIN",10)]*3,10,.45)=="VERIFIED"
assert pre_class([("UNKNOWN",None)]*3,10,.45)=="UNVERIFIED"
assert pre_class([("TERRAIN",10),("ROCK",None)],10,.45)=="UNVERIFIED"
refs=[{"status":"PREDICTED","oracle_before_m":10,"oracle_after_m":12}]*4
idx=list(range(4));base={i:"VERIFIED" for i in idx}
def check(samples,label,b=base):
    assert evaluate_frame(samples,refs,idx,b,.45)[0]==label
check([("TERRAIN",12)]*3+[("ROCK",None)],"CSG_POST_MATCH")
check([("TERRAIN",12)]*2+[("WATER",None)]*2,"CSG_POST_MATCH")
check([("TERRAIN",12)]+[("ROCK",None)]*3,"OCCLUDED_OR_INSUFFICIENT_COVERAGE")
check([("TERRAIN",12)]*3+[("AMBIGUOUS",None)],"INCOMPLETE_TERRAIN_EVIDENCE")
check([("TERRAIN",12)]*3+[("TERRAIN",10)],"MIXED_OR_UNCERTAIN")
check([("TERRAIN",12)]*3+[("TERRAIN",12)],"PRE_DEPTH_UNVERIFIED",{**base,3:"UNVERIFIED"})
check([("TERRAIN",12)]*4,"INCOMPLETE_TERRAIN_EVIDENCE",{**base,3:"OCCLUDED"})
assert group_state([0,1],[0,.016],[[("ROCK",None)],[("TERRAIN",50)]])=="CONFLICTING_MASK"
assert group_state([0,1],[0,.016],[[("TERRAIN",50)],[("TERRAIN",54)]])=="CONFLICTING_DEPTH"
assert group_state([0,1],[0,.016],[[("TERRAIN",50)],[("TERRAIN",51)]])=="STABLE"
assert group_state([0,1],[0,.1],[[("ROCK",None)],[("ROCK",None)]])=="PERSISTENT_ID"
assert select_rays(refs,[{"pixel":[960,540]},{"pixel":[944,540]},{"pixel":[976,540]},{"pixel":[960,556]}],.45)==[1,2,3]
shader=(root/"godot/shaders/a8_p83_semantic_depth.gdshader").read_text()
assert "hint_screen_texture" in shader and "hint_depth_texture" in shader and "local_m / 5.0" in shader
runner=(root/"godot/tests/a7_edit_runner.gd").read_text()
assert 'terrain.material=preload("res://tests/a8_p83_object_tags.gd").make(Color.GREEN)' in runner
assert "for dy in [-32,-16,0,16,32]" in runner
for p,color in [("a4_rocks_instancer.gd","RED"),("a4_rock_body.gd","RED"),("a5_water.gd","BLUE")]:
    assert "tags.active()" in (root/"godot/scripts"/p).read_text() and "Color."+color in (root/"godot/scripts"/p).read_text()
print("A8_P83_SEMANTIC_OCCLUSION_CALIBRATION_FAIL_CLOSED_PASS")
