# A8-P7 — encerramento (2026-11-24)

Verdict: DIAGNOSTIC_SATISFACTORY_WITH_LIMITATIONS. No merge or baseline promotion. A5 CPU16 checkpoint 0c3fee959576d0a1faec9ceecffb4b132a65558b preserved. Tested commit e19a456bef0dca475b8a0a4b82c094dbeece4a99. Prior failed collection was superseded by the successful aligned pilot.

Evidence: a8_p7_performance_evidence(1).zip; SHA256 41a08b756d7f87e07ca7290e39baaa2f2c93e759859b631d70077e924ab5c510. Raw nested CSV SHA256 (computed independently after receipt) 084e3788856db3d50673d1db021d6dc0c793a3f7ab6e306ae4155a56c064aadb. Archive not committed.

GTX 1050 Ti, GL Compatibility, VSync ON, seed 20261119, 1000 drawn warmup frames, 30s turns at 18m/s. ETW_ALIGNED, 1799 displayed rows, 1798 intervals, zero recorded dropped rows. Cadence p50/p95/p99/p99.9/max 16.67595/16.72721/16.74962/16.80589/17.61818 ms; 392 intervals >16.7 ms (21.802%), zero >20ms; cumulative excess 8.253ms, longest sequence 3. Godot 1800 frames, p99 18.01ms, max 20.716ms. PresentMon display latency median 47.7354ms; GPUTime p99 23.9648ms is a distinct metric from Godot internal GPU timing and must not be dismissed. No causal attribution established.

Limits: one short pilot; ETW loss counters null (not proven zero), local UTC offset alignment, composed copy GPU GDI mode. No formal full-frame or edit pixel qualification. All four strict gates remain NOT_QUALIFIED. No A8-P7.1 optimization justified by this pilot. Next: A8-P8 independent correct-geometry edit latency evidence, starting with a small controlled pilot; no repeated full A7 campaign.
