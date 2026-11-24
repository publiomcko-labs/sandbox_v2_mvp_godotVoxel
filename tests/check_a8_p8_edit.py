import sys
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"scripts"))
from a8_p8_edit_report import geometry_changed
assert geometry_changed([{"before_m":2,"after_m":2}]*9)==0
assert geometry_changed([{"before_m":2,"after_m":3}]*9)==9
assert geometry_changed([{"before_m":None,"after_m":3}]*9)==9
for rays in ([],[{"before_m":float("nan"),"after_m":3}]*9,[{"before_m":-1,"after_m":2}]*9):
    try: geometry_changed(rays)
    except ValueError: pass
    else: raise AssertionError("invalid reference accepted")
root=Path(__file__).resolve().parents[1]
src=(root/"godot/tests/a7_edit_runner.gd").read_text()
assert 'range(1000)' in src and '350000' in src and 'count!=12' in src
assert 'LIVE_SDF_REFERENCE_NOT_RENDERED_DEPTH' in src
report=(root/"scripts/a8_p8_edit_report.py").read_text()
assert '"first_correct_presented_pixel_ms":None' in report
assert '"strict_edit_100":"NOT_QUALIFIED"' in report
print("A8_P8_REFERENCE_AND_FAIL_CLOSED_CONTRACT_PASS")
