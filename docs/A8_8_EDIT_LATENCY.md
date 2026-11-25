# A8-P8 — edit latency diagnostic pilot

Branch isolated from A8-P7 closure. A5/CPU16 world unchanged. 12 scripted brush calls (8 idle locations, 4 boundary locations), alternating add/remove, 1.5s spacing, 1000 drawn warmup frames, camera settles for 12 draws and holds >=350ms after each call. External NVENC and PID-bound PresentMon; no synchronous screenshot readback. Nine live SDF rays before/after are diagnostic, NOT an independent geometry oracle. CPU offline report hashes evidence, verifies marker sequence and target ROI, reports candidate RGB changes relative to marker, and preserves NOT_QUALIFIED. No absolute first-correct-pixel latency or exact ETW/video frame join is claimed. This is the first acquisition pilot; independent rendered depth and calibrated frame identity remain future work. Video overhead disqualifies PERF-60 comparisons. No full A7 battery.

Run only after CI review, in interactive PowerShell on reference GPU with installed runtime and verified PresentMon 2.6.0:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a8-p8-edit-windows.ps1"
```

Keep Godot foreground, close private windows before recording. Send a8_p8_edit_evidence.zip or exact preflight error. No merge or gate promotion.
