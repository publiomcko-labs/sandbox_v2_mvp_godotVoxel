# A8-P8.3 — semantic depth and occlusion correction

P8.2 evidence: 12/12 native edits, 3656 CSG sign comparisons without disagreement. The previous empirical sensor budget was 0.1245934574 m, above the 0.10 m target. The saved promoted rock x1565_y731_z781 ended at (15.6164,6.2583,8.1086), 0.659 m from edit 9 center (15.5,6.9000,8.2); final position is not a per-frame trajectory. P8.2 video has no object identity. It cannot establish occlusion or rollback conclusively.

P8.3 diagnostic-only scene tags: terrain green, static and promoted rocks red, the geometric water plane blue. Same scene geometry, native instancer, physics, persistence and edit schedule. Opaque water in this arm intentionally changes alpha visibility; this is a geometric mask, not normal RGB. The fullscreen shader reads screen tag and opaque depth at the same pixel. Terrain encodes radial depth over a local 5 m interval; red/blue/cyan/yellow/magenta mark rock/water/no hit/out of range/unknown. Unknown/mixed color is not an occluder. Calibration uses eleven terrain panels (six fit and five held out), three semantic panels, PNG/video comparison, per-capture error and quantization margin; NVENC CQ10 rather than CQ18. No readback during edit measurement. All 25 ray samples and raw classification counts retained; CSG eligibility independent of observed masks. Only known rock/water excluded; at least half of eligible rays, minimum two, must remain visible. Mixed or unresolved rays cannot qualify. PRE baseline checked before edit; no silent exclusion of mismatch. No automatic optimizations or promotion.

CI CPU/headless validates parser, mask and calibration arithmetic and CSG contracts; GPU shader and precision require interactive real-GPU validation. One 12-edit campaign with 1000 drawn warmup frames, no repetition on failure. Commands from the experimental branch:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\scripts\a8-p8-edit-windows.ps1" -Semantic
```

Output a8_p83_semantic_evidence.zip. Strict EDIT-100 remains NOT_QUALIFIED even if sample checks pass; exact ETW-to-frame identity is not provided.
