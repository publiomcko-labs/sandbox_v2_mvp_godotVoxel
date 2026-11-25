import sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/"scripts"))
from a8_p82_csg_oracle import Lattice,predict
from a8_p82_depth_report import stable_group,calibrate,geometry_class

def lattice(fn):
    return Lattice({"lo":[-4,-4,-4],"hi":[4,4,4],"order":"zyx_x_fastest","values":[fn(x,y,z) for z in range(-4,5) for y in range(-4,5) for x in range(-4,5)]})

base=lattice(lambda x,y,z:y)
assert abs(base.sample((0.2,0.4,-0.6))-0.4)<1e-9
o=[0.,5.,0.];d=[0.,-1.,0.]
assert abs(base.first_hit(o,d)-5)<1e-5
add=base.csg((0,0,0),1.5,True)
remove=base.csg((0,0,0),1.5,False)
assert abs(add.first_hit(o,d)-3.5)<1e-5
assert abs(remove.first_hit(o,d)-6.5)<1e-5
assert abs(base.at(0,0,0))<1e-9
assert predict({"origin":o,"direction":d,"before_m":5},base,remove,remove)["status"]=="PREDICTED"
assert predict({"origin":o,"direction":d,"before_m":5.9},base,remove,remove)["status"]=="PRE_REFERENCE_MISMATCH"
assert stable_group([0,1],[0,.016],[[10,20],[11,20]])=="STABLE"
assert stable_group([0,2],[0,.016,.032],[[10],[10]])=="NONCONTIGUOUS_ID"
assert stable_group([0,1],[0,.1],[[10],[10]])=="PERSISTENT_ID"
assert stable_group([0,1],[0,.016],[[10],[14]])=="CONFLICTING_DEPTH"
assert stable_group([],[],[])=="MISSING"
pts=[(20+30*i,float(i)) for i in range(7)]
assert calibrate(pts,[p[0] for p in pts])["target_0_10m_met"]
assert not calibrate(pts,[p[0]+5 for p in pts])["target_0_10m_met"]
refs=[{"status":"PREDICTED","oracle_before_m":10,"oracle_after_m":12}]*9
assert geometry_class([12]*9,refs,.45)=="CSG_POST_MATCH"
assert geometry_class([10]*9,refs,.45)=="CSG_PRE_MATCH"
assert geometry_class([None]*9,refs,.45)=="UNKNOWN_DEPTH"
assert geometry_class([11]*9,refs,.45)=="MIXED_OR_UNCERTAIN"
assert "depth.invalidate_stamp()" in (root/"godot/tests/a7_edit_runner.gd").read_text()
assert "range_start_m" in (root/"godot/shaders/a8_p82_metric_depth.gdshader").read_text()
import a8_p82_legacy_audit
assert "PRE_DEPTH_UNVERIFIED" in (root/"scripts/a8_p82_depth_report.py").read_text()
print("A8_P82_CSG_PRECISION_AND_FRAME_ID_CONTRACT_PASS")
