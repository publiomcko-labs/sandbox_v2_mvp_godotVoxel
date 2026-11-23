"""A7.4 fast repeat: warmup is rendered-frame counted and recorded in provenance."""
from pathlib import Path
root=Path(__file__).resolve().parents[1]
gd=(root/"godot/tests/a74_pilot.gd").read_text(encoding="utf-8")
one=(root/"scripts/a74-pilot-windows.ps1").read_text(encoding="utf-8")
batch=(root/"scripts/a74-batch-windows.ps1").read_text(encoding="utf-8")
review=(root/"scripts/a74_geometry_pilot.py").read_text(encoding="utf-8")
assert 'Engine.get_frames_drawn() - initial_drawn' in gd
assert 'rendered >= warmup_frames' in gd
assert 'warmup_frames_observed' in gd
assert 'a74_ready.json' in gd and 'a74_capture_start.flag' in gd
assert gd.index('a74_reference.json') < gd.index('a74_ready.json')
assert gd.index('a74_capture_start.flag') < gd.index('for i in range(4):')
assert "[int] $WarmupFrames = 1000" in batch
assert "'-WarmupFrames',[string]$WarmupFrames" in batch
assert "'a74_ready.json'" in batch
assert 'a74_ready.json' in one and 'a74_capture_start.flag' in one
assert one.index('$game = Start-Process') < one.index('$recording.Start()')
assert one.index('a74_ready.json') < one.index('$recording.Start()')
assert 'warmup_frames_observed' in one and 'recording_started_after_warmup' in one
assert 'ready.get("warmup_frames_observed", 0) < warmup_target' in review
assert 'manifest.get("recording_started_after_warmup") is not True' in review
assert '"edit_100_gate": "NOT_QUALIFIED"' in review
print("A74_RENDERED_1000_FRAME_WARMUP_CONTRACT_PASS")
