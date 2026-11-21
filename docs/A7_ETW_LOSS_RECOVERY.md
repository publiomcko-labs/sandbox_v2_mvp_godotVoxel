# A7 — recover an ETW capture lost during long local streaming

This is a measurement-only diagnostic branch based on A5/CPU16. No core game code,
LOD, water, rocks, runtime worker count, strict gate, or A5 baseline is changed.

## Observed failure (2026-11-21)

An elevated Windows local campaign `campaign-20261121-144441-61188` finished
all 8 Godot streaming legs with 8/8 probe hits each, but every PresentMon 2.6.0
collector exited 0 with a missing/zero-length CSV. PresentMon stderr reported,
in execution order, **860404, 5244020, 3391724, 552538, 547087, 3253111,
3266264, and 663400 lost ETW events**. The short 20s warmup + 30s route
previously produced a valid 3000-row ETW CSV. These results show that the
long-running collection is unreliable. The ETW overflow itself is observed;
its underlying cause (consumer CPU saturation, GPU event volume, or another
provider/driver issue) is not yet proven. Do not assume the zero-byte CSV
can be fixed by re-parsing.

PresentMon v2.6.0's underlying realtime ETW session allocates fixed 64 KB
buffers (minimum 256, maximum 1024), and its --no_track_gpu option is a
supported way to isolate the cost of GPU timing capture. Increasing
--set_circular_buffer_size adjusts the in-process present circular buffer,
**not** the ETW session kernel buffer pool; do not confuse the two.

## Short, fail-fast local experiment

From an elevated PowerShell on DESKTOP-SAFGO15, with pinned Godot, native DLL,
Python, and PresentMon 2.6.0 already provisioned:

```powershell
cd C:\Dev\sandbox-a7-etw
git fetch origin fix/a7-etw-loss-probe-20261121
git switch --detach FETCH_HEAD
python .\tests\check_a7_streaming_present.py
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a7-streaming-present-windows.ps1 -PresentMonExe .\PresentMon.exe -EtwStressProbe -DisplayOnly
```

- Runs exactly **one** shoreline_180s route: 45s warmup + 90s measurement,
  VSync on, 18m/s, VoxelEngine automatic workers, same 1 Hz CPU/process probe.
- `-DisplayOnly` passes PresentMon `--no_track_gpu` so GPUTime is **not measured**.
  The display cadence and latency remain targets of this diagnostic.
- The experiment tests whether disabling GPU event collection changes ETW
  loss; it **does not** prove that GPU provider volume is the root cause.
- If the ETW token is authorized but the collector returns empty CSV, fails,
  or reports lost events, the script now **throws immediately**, preserving
  artifacts and stopping any subsequent route. Do not accept a collector's
  exit=0 as proof of a usable trace.
- Pre-existing unprivileged GitHub runner behavior remains fail-closed
  `NOT_MEASURED` without pretending to have ETW.
- An aligned display-only probe has `etw_aligned_count=1`, `route_count=1`,
  and `gpu_work_p99_ms=null`. Strict A7 remains `NOT_QUALIFIED`.
- Re-running the full 8-route campaign is **not** recommended before this
  sustained probe succeeds and its ETW loss counters are zero.

Find the most recent probe and status:

```powershell
$camp = Get-ChildItem '.\reports\generated\a7-streaming-present' -Directory | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Get-ChildItem $camp.FullName -Recurse -File -Filter a7_presentmon_status.json | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json | Select-Object exit_code,csv_bytes,etw_events_lost,etw_buffers_lost,gpu_tracking_requested,capture_error }
if (Test-Path "$($camp.FullName)\streaming_comparison.json") { Get-Content "$($camp.FullName)\streaming_comparison.json" -Raw | ConvertFrom-Json | Select-Object route_count,etw_aligned_count,strict_acceptance }
```

If the display-only probe succeeds, compare against an otherwise identical
90-second full-GPU PresentMon probe with the same command omitting
`-DisplayOnly`. Retain both artifacts; do not conflate their GPUTime fields
or instrumented overhead. If the full-GPU probe remains lossy, explore
bounded ETW capture windows, provider scope, or an alternative GPU trace
collector before pursuing the full campaign.

The A5/CPU16 functional checkpoint and all strict gates remain unchanged.

## Short timed ETW window inside a long gameplay route

The 45s warmup + 90s shoreline `-EtwStressProbe -DisplayOnly` reproduced
`csv_bytes=0` and **394015 ETW events lost**, although PresentMon exited 0.
Therefore GPU tracking alone is not the explanation, and the previous
fail-fast correctly prevented a larger invalid campaign.

New isolation mode keeps the game and all Godot process/resource telemetry
running for the full 45s warmup + 90s measured route, but starts PresentMon
only after **60s of game process uptime**, and asks it to record **30s**.
This is a genuine delayed start of the ETW session, not PresentMon's
`--delay` (which would leave the ETW session active while not recording).

```powershell
cd C:\Dev\sandbox-a7-etw
git fetch origin fix/a7-etw-loss-probe-20261121
git switch --detach FETCH_HEAD
python .\tests\check_a7_streaming_present.py
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\a7-streaming-present-windows.ps1 -PresentMonExe .\PresentMon.exe -EtwWindowProbe -DisplayOnly
```

The capture has the same game route, seed, speed, VSync ON and workers as
the previous failed 90s full-session test, but the GPUTime metric is
unmeasured because this arm uses `--no_track_gpu`.

Results must distinguish:

- `ETW_PARTIAL_ALIGNED=1/1` **only** if collection exited successfully,
  no ETW event or buffer loss was reported, CSV has sufficient valid displayed
  rows, and at least 85% of the bounded 30s subwindow is covered. Full
  `etw_aligned_count` remains `0`.
- `A7_ETW_CAPTURE_FAILED_FAST` / `A7_ETW_EVENTS_LOST`: no valid ETW sample;
  preserve logs and do not repeat the 8-route campaign.
- `ETW_INCOMPLETE`: sample collected but timestamp/display coverage failed.

The metric `gpu_work_p99_ms` is **null** for display-only captures. Strict
A7 PERF-60/STREAM-18/VIEW-130/EDIT-100 gates remain `NOT_QUALIFIED`.
A single subwindow can validate instrument viability, but it cannot
characterize p99 for an entire multi-minute route.
