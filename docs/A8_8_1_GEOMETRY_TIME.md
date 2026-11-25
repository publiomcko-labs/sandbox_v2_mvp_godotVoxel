# A8-P8.1 — metric depth and temporal diagnostics

A8-P8 original ZIP preserved. 12/12 accepted; false negative due to 100-edit hardcoded completion check. Focus transfer allowed only after matching completed count, completed observation timestamp and normal exit; no weakening for mid-workload loss.

Depth-only follow-up on A5 CPU16, seed 20261119, same 12 edits including index 1 (the undetected RGB addition), 1000 drawn frames warmup. Seven metric depth calibration panels before warmup; actual GL depth sampled via fullscreen overlay; no GPU readback during edits. 12-bit visual frame identifier links decoded video to Godot pre/post-draw timestamps, not directly to ETW. Live SDF reference rays before/after the edit (post-observation sampling to reduce overhead); conservative separation and calibration margin, center crosshair excluded. Source host timezone and collector start anchor constrain the ETW clock hypothesis; no analyst-local timezone assumption. Missing or ambiguous depth samples remain inconclusive. The diagnostic overlay is not a normal RGB frame; costs cannot be treated as PERF-60 results.

Run after CI review:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a8-p8-edit-windows.ps1" -Depth
```
Send a8_p81_depth_evidence.zip or preflight error. No repetition if capture fails without first examining evidence.

Limitations: actual depth compared to live voxel SDF is independent of rasterization but not an independent brush implementation. Full independent edited-field reconstruction, per-present identity and physical input-to-photon not supplied. Calibration and frame stamps require real GPU validation. EDIT-100 stays NOT_QUALIFIED. No engine optimization or merge.
