import sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(root/"scripts"))
from a8_p81_depth_report import align_clock,parse_wall_as_utc,decode_stamp,interpolate,classify_depth
assert align_clock([100,101],21700,-10800)==21600
assert align_clock([100,101],10900,-10800)==10800
assert align_clock([100,101],100,-10800)==0
for off in (None,999999):
    try: align_clock([100],100,off)
    except ValueError: pass
    else: raise AssertionError("invalid clock accepted")
assert decode_stamp([255]+[255,0,255]+[0]*9+[0])==5
assert decode_stamp([255]+[127]*12+[0]) is None
assert interpolate(30,[(20,10),(40,20)])==15
assert interpolate(50,[(20,10),(40,20)]) is None
probes=[{"before_m":20,"after_m":18}]*9
assert classify_depth([18]*9,probes)==("POST_EDIT_DEPTH_MATCH",8)
assert classify_depth([20]*9,probes)==("PRE_EDIT_DEPTH_MATCH",8)
assert classify_depth([19]*9,probes)[0]=="MIXED_OR_UNCERTAIN"
assert classify_depth([18]*9,[{"before_m":18.1,"after_m":18}]*9)[0]=="INSUFFICIENT_SEPARATION"
assert classify_depth([None]*9,probes)[0]=="UNKNOWN_DEPTH"
src=(root/"scripts/a7-run-windows.ps1").read_text()
assert "$endReport.requested_count -eq $count" in src
assert "$endReport.a8_p8_observation_end_epoch_s -le $focusObservedEpoch" in src
assert "$p.ExitCode -eq 0" in src
assert "capture_host_utc_offset_s" in src
assert 'hint_depth_texture' in (root/"godot/shaders/a8_p81_metric_depth.gdshader").read_text()
print("A8_P81_DEPTH_AND_CLOCK_FAIL_CLOSED_PASS")
