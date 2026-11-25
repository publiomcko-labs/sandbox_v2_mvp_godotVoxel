# A8-P8.2 — geometry stability and precision

Source: original P8.1 ZIP, independently decoded 5148 frames with FFmpeg, compared to trace using original calibration. Last legacy stamp excluded (persisted outside observation); conflicting duplicates excluded. Distinct remaining classes: edit 7: 1 PRE, 19 MIXED; edit 9: 10 POST, 8 MIXED; edit 11: 1 PRE, 19 MIXED. No confirmed mesh rollback. Old evidence lacks pre-brush voxel lattice and cannot validate new encoding.

New arm: local 8m depth window centered on brush range, no-hit/out-of-range sentinel, seven panel video+PNG calibration stamps before warmup, estimated error budget target <=0.10m. No claim before GPU calibration. Explicit invalidation of edit IDs, raw frame counts, rejection of noncontiguous/persistent/conflicting IDs or repeated engine counters. 1000 drawn warmup, 12 same edits. No readback during measured edits. Pre/post integer lattice captured outside timing, offline trilinear CSG union/min and subtraction/max independent of native brush, baseline ray consistency check and local bound rejection. Post lattice used only for comparison, never for prediction. Separate 0.45m minimum geometry-model tolerance, not sensor precision. ETW source clock still validated, no exact present ID association.

CPU-only regression verifies sphere union/removal, baseline mismatch, ambiguous frames, calibration and fail-closed classification. Run GPU only after CI review:
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a8-p8-edit-windows.ps1" -Precision
```
Output a8_p82_depth_evidence.zip. No baseline A5/CPU16 change, no merge, no strict EDIT-100 promotion. New evidence is needed solely for new encoding and pre/post lattice; not a repetition of old RGB/depth capture.
