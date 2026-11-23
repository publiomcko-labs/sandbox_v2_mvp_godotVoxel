param(
    [ValidateSet(
        'stationary_180s','straight_18mps_600s','turns_18mps_300s',
        'out_and_back_18mps_300s','shoreline_180s','cave_180s',
        'rocks_water_180s','edit_idle_100','edit_moving_100',
        'boundary_edit_100','reopen_save'
    )]
    [string] $Scenario = 'out_and_back_18mps_300s',
    [int[]] $Seeds = @(20261119, 20261120, 20261121),
    [ValidateRange(1,10)] [int] $Repeats = 3,
    [double] $Warmup = 45,
    [ValidateRange(0,10000)] [int] $WarmupFrames = 0,
    [switch] $A8VisualEvidence,
    [double] $Duration = 0,
    [switch] $Full,
    [switch] $Capture,
    [ValidateRange(0,300)] [double] $ScreenshotIntervalSeconds = 30.0,
    [switch] $EditNoStills,
    [switch] $VisualSurfaceFollow,
    [switch] $CiSmoke,
    [switch] $VsyncOff,
    [ValidateRange(0,48)] [int] $VoxelThreads = 0,
    [switch] $ResourceTelemetry,
    [string] $PresentMonExe = '',
    [switch] $PresentMonNoGpu,
    [switch] $EvidenceOnlyPresentMon,
    [ValidateRange(0,600)] [double] $PresentMonStartDelaySeconds = 0,
    [ValidateRange(0,600)] [double] $PresentMonCaptureSeconds = 0
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = Join-Path $root '.tools/godot.exe'
$project = Join-Path $root 'godot'
$dll = Join-Path $project 'bin/sandbox_native.windows.template_debug.x86_64.dll'
if (-not (Test-Path $exe) -or -not (Test-Path $dll)) {
    throw 'A7 requires pinned Godot + A3 native DLL (bootstrap-windows.ps1 -SkipDownload)'
}
if ($PresentMonExe -and (-not (Test-Path -LiteralPath $PresentMonExe))) { throw "A7 PresentMon executable missing: $PresentMonExe" }
if ($PresentMonNoGpu -and -not $PresentMonExe) { throw 'A7_NO_GPU_ETW_REQUIRES_PRESENTMON' }
if ($EvidenceOnlyPresentMon -and (-not $PresentMonExe -or -not $Capture -or $Scenario -notin @('edit_idle_100','edit_moving_100','boundary_edit_100'))) {
    throw 'A7_EDIT_PRESENTMON_REQUIRES_EXPLICIT_CAPTURE_AND_EDIT_SCENARIO'
}
if ($PresentMonStartDelaySeconds -gt 0 -or $PresentMonCaptureSeconds -gt 0) {
    if (-not $PresentMonExe -or -not $ResourceTelemetry -or $PresentMonStartDelaySeconds -le 0 -or $PresentMonCaptureSeconds -le 0) {
        throw 'A7_ETW_SLICE_REQUIRES_PRESENTMON_RESOURCE_TELEMETRY_DELAY_AND_CAPTURE_DURATION'
    }
    if ($PresentMonStartDelaySeconds + $PresentMonCaptureSeconds -gt $Warmup + $Duration - 5) {
        throw 'A7_ETW_SLICE_OUTSIDE_REQUESTED_GAME_RUNTIME'
    }
}
if ($PresentMonExe -and ($CiSmoke -or $Full -or ($Capture -and -not $EvidenceOnlyPresentMon) -or $VoxelThreads -ne 0)) {
    throw 'A7 PresentMon ETW is restricted to isolated timed routes or explicit non-performance edit evidence'
}
if ($A8VisualEvidence -and (-not $Capture -or $WarmupFrames -ne 1000 -or $Full -or $CiSmoke -or
    $PresentMonExe -or $VsyncOff -or $VoxelThreads -ne 0 -or $Duration -lt 10 -or $Duration -gt 90 -or
    $Scenario -notin @('straight_18mps_600s','turns_18mps_300s','out_and_back_18mps_300s'))) {
    throw 'A8_VISUAL_EVIDENCE_REQUIRES_SEPARATE_CAPTURE_1000_FRAMES_NORMAL_VSYNC'
}
if ($WarmupFrames -gt 0 -and ($Full -or $CiSmoke -or ($Capture -and -not $A8VisualEvidence) -or $PresentMonExe -or
    $Scenario -notin @('straight_18mps_600s','turns_18mps_300s','out_and_back_18mps_300s'))) {
    throw 'A8_FRAME_WARMUP_RESTRICTED_TO_REAL_GPU_UNRECORDED_SHORT_ROUTE'
}
if ($VisualSurfaceFollow -and (-not $Capture -or $CiSmoke -or $Scenario -notin @('shoreline_180s','rocks_water_180s'))) {
    throw 'A7_VISUAL_SURFACE_FOLLOW_REQUIRES_EXPLICIT_SHORELINE_OR_ROCKS_EVIDENCE_MODE'
}
if ($EditNoStills -and (-not $Capture -or $Scenario -notin @('edit_idle_100','edit_moving_100','boundary_edit_100'))) {
    throw 'A7_EDIT_NO_STILLS_REQUIRES_EVIDENCE_CAPTURE'
}
if ($Capture -and $Full) {
    throw 'A7 refuses screenshot overhead inside comparable full performance campaign; use a separate -Capture evidence run'
}
if ($CiSmoke -and ($Full -or $Capture)) {
    throw 'Headless CI is only a short integration smoke'
}
if ($Seeds.Count -lt 1 -or (@($Seeds | Select-Object -Unique)).Count -ne $Seeds.Count) {
    throw 'A7 requires at least one unique seed'
}
$routes = @('stationary_180s','straight_18mps_600s','turns_18mps_300s',
            'out_and_back_18mps_300s','shoreline_180s','cave_180s','rocks_water_180s')
$edits = @('edit_idle_100','edit_moving_100','boundary_edit_100')
if (($VsyncOff -or $VoxelThreads -ne 0 -or $ResourceTelemetry) -and ($Full -or $CiSmoke)) {
    throw 'A7 resource diagnostics are isolated; strict Full and headless smoke remain unchanged'
}
if (($VsyncOff -or $VoxelThreads -ne 0 -or $ResourceTelemetry) -and ($edits -contains $Scenario -or $Scenario -eq 'reopen_save')) {
    throw 'A7 resource diagnostics only support timed route scenarios'
}
if ($Full -and ($Seeds.Count -lt 3 -or $Repeats -lt 3)) {
    throw 'A7 Full requires >=3 seeds and >=3 repeats per route; no silent workload downgrade'
}
if ($Full -and $Duration -ne 0) {
    throw 'A7 Full requires full canonical scenario durations'
}
$scenarios = if ($Full) { $routes + $edits } else { @($Scenario) }
$runSeeds = if ($Full) { $Seeds } else { @($Seeds[0]) }
$reps = if ($Full) { $Repeats } else { 1 }
if ($CiSmoke) { $Warmup = 0.3; $Duration = 1.5 }

$cache = Join-Path $project '.godot'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $cache 'extension_list.cfg'),
    "res://sandbox_native.gdextension" + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($false))
)
$rootOutput = if ($env:A7_CAMPAIGN_DIR) { $env:A7_CAMPAIGN_DIR } else {
    Join-Path $root ('reports/generated/a7/campaign-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID")
}
if ($CiSmoke -and (Test-Path $rootOutput)) {
    Remove-Item -LiteralPath $rootOutput -Recurse -Force
}
New-Item -ItemType Directory -Path $rootOutput -Force | Out-Null
$head = 'unknown'
try {
    $head = (& git -C $root rev-parse HEAD 2>$null).Trim()
} catch { }
$adapter = @()
try {
    $adapter = @(Get-CimInstance Win32_VideoController |
        Select-Object Name, DriverVersion, VideoProcessor, AdapterRAM)
} catch { }
$manifest = [ordered]@{
    schema='a7_campaign_v1'; started_utc=[DateTime]::UtcNow.ToString('o')
    git_sha=$head; baseline_checkpoint='0c3fee959576d0a1faec9ceecffb4b132a65558b'
    baseline='A5 CPU16 GL Compatibility'; full=[bool]$Full
    ci_smoke=[bool]$CiSmoke; capture=[bool]$Capture
    screenshot_interval_s=$ScreenshotIntervalSeconds
    edit_no_stills=[bool]$EditNoStills
    visual_surface_follow=[bool]$VisualSurfaceFollow
    resource_diagnostic=[bool]($VsyncOff -or $VoxelThreads -ne 0 -or $ResourceTelemetry)
    vsync_off_requested=[bool]$VsyncOff
    voxel_threads_requested=$VoxelThreads
    process_cpu_sampling=[bool]$ResourceTelemetry
    presentmon_requested=[bool]$PresentMonExe
    evidence_only_presentmon=[bool]$EvidenceOnlyPresentMon
    presentmon_gpu_tracking_requested=[bool]($PresentMonExe -and -not $PresentMonNoGpu)
    presentmon_start_delay_s=$PresentMonStartDelaySeconds
    presentmon_capture_duration_s=$PresentMonCaptureSeconds
    target_resolution='1920x1080'; target_speed_mps=18.0
    requested_view_distance_m=192; visual_radius_target_m=130
    mesh_block_voxels=16; lod_count=4; lod_distance=48
    seeds=@($runSeeds); repeats=$reps; scenarios=@($scenarios)
    warmup_s=$Warmup; warmup_frames_requested=$WarmupFrames; a8_visual_evidence_requested=[bool]$A8VisualEvidence; duration_override_s=$Duration
    windows_version=[Environment]::OSVersion.VersionString
    cpu=$env:PROCESSOR_IDENTIFIER; gpu=@($adapter)
    notes='Main-game A5 is unmodified; CI and frame intervals cannot prove full GPU+present, pixels or EDIT-100.'
}
($manifest | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath (Join-Path $rootOutput 'manifest.json') -Encoding UTF8
$quotedProject = '"' + $project + '"'
$expected = 0
foreach ($name in $scenarios) {
    if ($name -eq 'reopen_save') {
        if ($Full) { throw 'Reopen functional integration is separately gated by A3-A5; Full only includes timed routes and edits' }
        $reopenScripts = @('a3-smoke-windows.ps1','a4-smoke-windows.ps1','a5-smoke-windows.ps1')
        foreach ($script in $reopenScripts) {
            & (Join-Path $root "scripts/$script")
            $scriptSucceeded = $?
            if (-not $scriptSucceeded -or ($LASTEXITCODE -and $LASTEXITCODE -ne 0)) {
                throw "A7_REOPEN_REGRESSION_FAIL $script"
            }
        }
        $reopenResult = [ordered]@{
            schema='a7_reopen_v1'; scenario='reopen_save'
            seed=20261119; passed=$true; checks=@($reopenScripts)
            completed_utc=[DateTime]::UtcNow.ToString('o')
            note='Functional A3/A4/A5 reopen smoke only; does not qualify graphical pixels or persistence for other seeds.'
        }
        ($reopenResult | ConvertTo-Json -Depth 6) |
            Set-Content -LiteralPath (Join-Path $rootOutput 'a7_reopen.json') -Encoding UTF8
        $expected++
        Write-Host 'A7_REOPEN_FUNCTIONAL_SMOKES_PASS (fixed seed 20261119; report=a7_reopen.json)'
        continue
    }
    foreach ($seed in $runSeeds) {
        for ($r = 1; $r -le $reps; $r++) {
            $folder = Join-Path $rootOutput ('{0}_seed{1}_rep{2:D2}' -f $name,$seed,$r)
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            $env:A7_OUTPUT_DIR = $folder
            $env:A3_SAVE_PATH = Join-Path $folder 'world.sqlite'
            $env:A4_ROCK_STATE_PATH = Join-Path $folder 'rocks.json'
            $isEdit = $edits -contains $name
            $script = if ($isEdit) { 'res://tests/a7_edit_runner.gd' } else { 'res://tests/a7_route_runner.gd' }
            $argsList = @()
            if ($CiSmoke) {
                $argsList += '--headless'
            } else {
                $argsList += @('--rendering-method','gl_compatibility','--rendering-driver','opengl3')
                if ($VsyncOff) { $argsList += '--disable-vsync' }
            }
            $argsList += @('--path',$quotedProject,'--script',$script,'--')
            if ($isEdit) {
                $count = if ($CiSmoke) { 2 } else { 100 }
                $editWarmup = if ($CiSmoke) { 10.0 } else { $Warmup }
                $argsList += @("--scenario=$name","--seed=$seed","--warmup=$editWarmup","--count=$count")
            } else {
                $argsList += @("--route=$name","--seed=$seed","--warmup=$Warmup")
                if ($WarmupFrames -gt 0) { $argsList += "--warmup-frames=$WarmupFrames" }
                if ($A8VisualEvidence) { $argsList += '--a8-visual-evidence' }
                if ($Duration -gt 0) { $argsList += "--duration=$Duration" }
            }
            if ($Capture) { $argsList += '--capture' }
            if (-not $isEdit -and $VisualSurfaceFollow) { $argsList += '--visual-surface-follow' }
            if ($isEdit -and $EditNoStills) { $argsList += '--no-stills' }
            if (-not $isEdit -and $Capture) { $argsList += "--screenshot-interval-s=$ScreenshotIntervalSeconds" }
            if ($CiSmoke) { $argsList += '--ci-smoke' }
            if (-not $isEdit) {
                if ($VsyncOff) { $argsList += '--vsync-off' }
                if ($VoxelThreads -gt 0) { $argsList += "--voxel-threads=$VoxelThreads" }
            }
            Write-Host "A7_START scenario=$name seed=$seed rep=$r/$reps output=$folder"
            # Windows PowerShell 5.1 can return a Process without an exit-code
            # handle when Start-Process uses -NoNewWindow -PassThru.
            # Explicit .NET startup preserves the process handle and ExitCode.
            $startInfo = New-Object System.Diagnostics.ProcessStartInfo
            $startInfo.FileName = $exe
            $startInfo.Arguments = ($argsList -join ' ')
            $startInfo.WorkingDirectory = $root
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $false
            $p = New-Object System.Diagnostics.Process
            $p.StartInfo = $startInfo
            if (-not $p.Start()) {
                throw "A7_RUN_START_FAIL scenario=$name seed=$seed rep=$r"
            }
            $gameTimer = [System.Diagnostics.Stopwatch]::StartNew()
            # Preserve the focus failure until the owned PresentMon collector
            # has fully stopped/flushed the CSV. Throwing from the watchdog
            # previously skipped collector cleanup and locked ZIP archiving.
            $foregroundFailure = $null
            if ($Capture -and -not $CiSmoke) {
                # Desktop Duplication records whatever is in the foreground.
                # The A7.2 capture of 2026-11-23 only saw 68/100 color
                # changes because an unrelated desktop window obscured Godot.
                # Pin the real game window to foreground before warmup/edits.
                if (-not ('A7NativeFocus' -as [type])) {
                    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class A7NativeFocus {
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
"@
                }
                $deadline = [DateTime]::UtcNow.AddSeconds(15)
                $windowReady = $false
                while ([DateTime]::UtcNow -lt $deadline -and -not $p.HasExited) {
                    $p.Refresh()
                    $handle = $p.MainWindowHandle
                    if ($handle -ne [IntPtr]::Zero) {
                        [void][A7NativeFocus]::ShowWindowAsync($handle,9)
                        [void][A7NativeFocus]::SetForegroundWindow($handle)
                        Start-Sleep -Milliseconds 200
                        [uint32]$frontPid = 0
                        [void][A7NativeFocus]::GetWindowThreadProcessId(
                            [A7NativeFocus]::GetForegroundWindow(),[ref]$frontPid)
                        if ($frontPid -eq $p.Id) {
                            $windowReady = $true
                            break
                        }
                    }
                    Start-Sleep -Milliseconds 250
                }
                if (-not $windowReady) {
                    try { if (-not $p.HasExited) { $p.Kill() } } catch {}
                    throw "A7_EVIDENCE_GAME_FOREGROUND_REQUIRED scenario=$name pid=$($p.Id): cannot verify unobstructed capture; close other windows and run in interactive desktop"
                }
                $foregroundStatus = [ordered]@{
                    schema='a7_foreground_v1'
                    game_pid=$p.Id
                    foreground_pid=$frontPid
                    foreground_verified_epoch_s=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0
                    verified=$true
                    note='Foreground PID verified at startup only. Occlusion later still requires independent video review.'
                }
                # This is an OrderedDictionary. Use real entries (not
                # PowerShell extended properties) so ConvertTo-Json preserves
                # the status and strict-mode mutation is reliable in PS 5.1.
                $foregroundStatus['continuity_verified'] = $false
                $foregroundStatus['continuous_check_interval_ms'] = 200
                $foregroundStatus['checks'] = 0
                $foregroundStatus['foreground_loss_detected'] = $false
                $foregroundStatus | ConvertTo-Json -Depth 4 |
                    Set-Content -LiteralPath (Join-Path $folder 'a7_foreground.json') -Encoding UTF8
                Write-Host "A7_EVIDENCE_GAME_FOREGROUND_CONFIRMED pid=$($p.Id) continuous_watchdog=True"
            }
            $pmProcess = $null
            $pmCsv = Join-Path $folder 'a7_presentmon.csv'
            $pmStatusPath = Join-Path $folder 'a7_presentmon_status.json'
            $pmStatus = [ordered]@{
                schema='a7_presentmon_status_v1'
                requested=[bool]$PresentMonExe
                process_id=$p.Id
                etw_session_name=$null
                presentmon_csv_format='v2_metrics'
                gpu_tracking_requested=(-not [bool]$PresentMonNoGpu)
                capture_start_delay_s=$PresentMonStartDelaySeconds
                capture_requested_duration_s=$PresentMonCaptureSeconds
                capture_started_epoch_s=$null
                capture_window_end_epoch_s=$null
                etw_events_lost=$null
                etw_buffers_lost=$null
                stderr_path=(Join-Path $folder 'a7_presentmon_stderr.txt')
                collection_started=$false
                exit_code=$null
                csv_exists=$false
                csv_bytes=0
                capture_error=$null
                note='Raw ETW CSV, not independently verified end-to-end photon or world-pixel correctness.'
            }
            if ($PresentMonExe) {
                try {
                    # PresentMon 2.6.0 exits 6 when the default ETW session name is already in use.
                    # Each capture owns a unique session and must never stop an unrelated session.
                    $pmSession = ('A7_' + $p.Id + '_' + [guid]::NewGuid().ToString('N'))
                    $pmStatus.etw_session_name = $pmSession
                    # --timed starts when PresentMon begins recording, soon after the game.
                    # Godot runs for warmup+duration. A small bounded drain window lets
                    # PresentMon finish and flush ETW rather than killing it prematurely.
                    # The previous +45s timer with a 15s join always killed valid captures
                    # if --terminate_on_proc_exit did not close the collector immediately.
                    $pmTimedSeconds = if ($PresentMonCaptureSeconds -gt 0) {
                        [int][Math]::Ceiling($PresentMonCaptureSeconds)
                    } elseif ($isEdit -and $EvidenceOnlyPresentMon) {
                        # 100 scripted edits at 10Hz plus startup. PresentMon
                        # will terminate early on game PID exit if appropriate.
                        [int][Math]::Ceiling($Warmup + 30.0)
                    } else {
                        [int][Math]::Ceiling($Warmup + $Duration + 8.0)
                    }
                    $pmStatus.collector_timeout_s = $pmTimedSeconds
                    $pmArgs = '--session_name ' + $pmSession + ' --process_id ' + $p.Id + ' --v2_metrics --date_time --output_file "' + $pmCsv + '" --no_console_stats --terminate_on_proc_exit --terminate_after_timed --timed ' + $pmTimedSeconds
                    # Diagnostic arm only: compare ETW display capture without
                    # verbose per-frame GPU tracking. Never represent missing
                    # GPUTime as GPU performance qualification.
                    if ($PresentMonNoGpu) { $pmArgs += ' --no_track_gpu' }
                    $pmStart = New-Object System.Diagnostics.ProcessStartInfo
                    $pmStart.FileName = $PresentMonExe
                    $pmStart.Arguments = $pmArgs
                    $pmStart.WorkingDirectory = $folder
                    $pmStart.UseShellExecute = $false
                    $pmStart.CreateNoWindow = $true
                    $pmStart.RedirectStandardError = $true
                    $pmProcess = New-Object System.Diagnostics.Process
                    $pmProcess.StartInfo = $pmStart
                    if ($PresentMonStartDelaySeconds -le 0) {
                        $pmStatus.collection_started = [bool]$pmProcess.Start()
                        if ($pmStatus.collection_started) {
                            $pmStatus.capture_started_epoch_s = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
                            $pmStatus.capture_window_end_epoch_s = $pmStatus.capture_started_epoch_s + $pmTimedSeconds
                        }
                        Write-Host "A7_PRESENTMON_START pid=$($p.Id) session=$pmSession started=$($pmStatus.collection_started) output=$pmCsv"
                    } else {
                        Write-Host "A7_PRESENTMON_DEFERRED pid=$($p.Id) delay_s=$PresentMonStartDelaySeconds duration_s=$pmTimedSeconds"
                    }
                } catch {
                    $pmStatus.capture_error=$_.Exception.Message
                    Write-Warning "A7_PRESENTMON_CAPTURE_WARNING: $($pmStatus.capture_error)"
                }
            }
            if ($ResourceTelemetry) {
                $readings = New-Object 'System.Collections.Generic.List[object]'
                $startUtc = [DateTime]::UtcNow
                $prevUtc = $startUtc
                $prevCpu = 0.0
                $logical = [Math]::Max(1, [Environment]::ProcessorCount)
                while (-not $p.WaitForExit(1000)) {
                    # Start a bounded ETW sample during an otherwise full-length
                    # Godot route. PowerShell's monitoring loop continues to collect
                    # the same process telemetry before, during and after the sample.
                    if ($PresentMonExe -and $PresentMonStartDelaySeconds -gt 0 -and
                        $null -ne $pmProcess -and -not $pmStatus.collection_started -and
                        -not $pmStatus.capture_error -and
                        $gameTimer.Elapsed.TotalSeconds -ge $PresentMonStartDelaySeconds) {
                        try {
                            $pmStatus.collection_started = [bool]$pmProcess.Start()
                            if ($pmStatus.collection_started) {
                                $pmStatus.capture_started_epoch_s = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
                                $pmStatus.capture_window_end_epoch_s = $pmStatus.capture_started_epoch_s + $pmTimedSeconds
                            } else {
                                $pmStatus.capture_error = 'PRESENTMON_DEFERRED_START_FALSE'
                            }
                            Write-Host "A7_PRESENTMON_SLICE_START pid=$($p.Id) started=$($pmStatus.collection_started) elapsed_s=$([Math]::Round($gameTimer.Elapsed.TotalSeconds,2)) duration_s=$pmTimedSeconds"
                        } catch {
                            $pmStatus.capture_error = $_.Exception.Message
                            Write-Warning "A7_PRESENTMON_SLICE_START_WARNING $($pmStatus.capture_error)"
                        }
                    }
                    try {
                        $p.Refresh()
                        $nowUtc = [DateTime]::UtcNow
                        $elapsed = ($nowUtc - $prevUtc).TotalSeconds
                        $cpuNow = $p.TotalProcessorTime.TotalSeconds
                        if ($elapsed -gt 0) {
                            $cores = [Math]::Max(0.0, ($cpuNow - $prevCpu) / $elapsed)
                            $readings.Add([pscustomobject]@{
                                t_s=[Math]::Round(($nowUtc - $startUtc).TotalSeconds,3)
                                cpu_equivalent_cores=[Math]::Round($cores,3)
                                cpu_pct_machine=[Math]::Round(100.0*$cores/$logical,2)
                                process_threads=$p.Threads.Count
                                working_set_mb=[Math]::Round($p.WorkingSet64/1MB,1)
                            })
                        }
                        $prevUtc = $nowUtc
                        $prevCpu = $cpuNow
                    } catch {
                        Write-Warning "A7_RESOURCE_SAMPLE_WARNING: $($_.Exception.Message)"
                    }
                }
                $p.WaitForExit()
                # Save the array as a single JSON input: Windows PowerShell 5.1
                # differs from PowerShell 7 in pipeline array unrolling.
                $snapshot = $readings.ToArray()
                $cpuSamplesPath = Join-Path $folder 'a7_process_resources.json'
                ConvertTo-Json -InputObject $snapshot -Depth 4 |
                    Set-Content -LiteralPath $cpuSamplesPath -Encoding UTF8
                $cpuTotal = 0.0
                $coresTotal = 0.0
                $memoryPeak = 0.0
                foreach ($reading in $snapshot) {
                    $cpuTotal += [double]$reading.cpu_pct_machine
                    $coresTotal += [double]$reading.cpu_equivalent_cores
                    $memoryPeak = [Math]::Max($memoryPeak,[double]$reading.working_set_mb)
                }
                $count = $snapshot.Length
                $cpuMean = $null
                $coresMean = $null
                $workingPeak = $null
                if ($count -gt 0) {
                    $cpuMean = [Math]::Round($cpuTotal/$count,2)
                    $coresMean = [Math]::Round($coresTotal/$count,2)
                    $workingPeak = [Math]::Round($memoryPeak,1)
                }
                $resourceSummary = [ordered]@{
                    schema='a7_process_resource_summary_v1'
                    sample_count=$count
                    cpu_pct_machine_avg=$cpuMean
                    cpu_equivalent_cores_avg=$coresMean
                    working_set_peak_mb=$workingPeak
                    sampling_interval_target_ms=1000
                    note='Process CPU and working set samples; not an app CPU+GPU+present frame trace.'
                }
                $resourceSummaryPath = Join-Path $folder 'a7_process_resource_summary.json'
                $resourceSummary | ConvertTo-Json -Depth 4 |
                    Set-Content -LiteralPath $resourceSummaryPath -Encoding UTF8
                Write-Host "A7_RESOURCE_TELEMETRY_WRITTEN samples=$count path=$resourceSummaryPath"
            } elseif ($Capture -and -not $CiSmoke) {
                # Enforce foreground continuity throughout warmup and edit.
                # The old check covered only startup. In boundary_edit_100 the
                # browser obscured all 100 video markers after startup.
                # Detect focus loss promptly and stop, rather than recording
                # private desktop content or presenting invalid visual evidence.
                while (-not $p.WaitForExit(200)) {
                    [uint32]$watchForegroundPid = 0
                    [void][A7NativeFocus]::GetWindowThreadProcessId(
                        [A7NativeFocus]::GetForegroundWindow(),[ref]$watchForegroundPid)
                    $foregroundStatus.checks = [int]$foregroundStatus.checks + 1
                    if ($watchForegroundPid -ne $p.Id) {
                        # The foreground PID changes legitimately when Godot
                        # exits, sometimes before WaitForExit(200) notices.
                        # boundary_edit_100 20261123-140948 produced 100/100
                        # synced markers; the browser returned only AFTER the
                        # final edit and A7_EDIT_REPORT_OK. Distinguish normal
                        # completion from genuine occlusion, without weakening
                        # the watchdog during the actual edit workload.
                        $reportName = if ($isEdit) { 'a7_edits.json' } else { 'a7_route.json' }
                        $endReportPath = Join-Path $folder $reportName
                        $completedWorkload = $false
                        if (Test-Path -LiteralPath $endReportPath -PathType Leaf) {
                            try {
                                $endReport = Get-Content -LiteralPath $endReportPath -Raw | ConvertFrom-Json
                                if ($isEdit) {
                                    $completedWorkload = (
                                        $endReport.schema -eq 'a7_edit_v1' -and
                                        $endReport.scenario -eq $name -and
                                        $endReport.seed -eq $seed -and
                                        $endReport.requested_count -eq 100 -and
                                        $endReport.accepted_count -eq 100 -and
                                        $endReport.all_accepted -eq $true -and
                                        $endReport.sqlite_saved -eq $true -and
                                        $endReport.edit_100_gate -eq 'NOT_QUALIFIED'
                                    )
                                } else {
                                    $completedWorkload = (
                                        $endReport.schema -eq 'a7_route_v1' -and
                                        $endReport.route -eq $name -and
                                        $endReport.seed -eq $seed -and
                                        $endReport.frame_count -gt 0 -and
                                        $endReport.perf_60_full_present_gate -eq 'NOT_QUALIFIED'
                                    )
                                }
                            } catch {
                                # An incomplete report is never evidence of a
                                # legitimate end-of-run focus transfer.
                                $completedWorkload = $false
                            }
                        }
                        if ($completedWorkload -and $p.WaitForExit(1500)) {
                            $p.Refresh()
                            if ($p.ExitCode -eq 0) {
                                $foregroundStatus['exit_focus_transfer_accepted'] = $true
                                $foregroundStatus['exit_foreground_pid'] = [int]$watchForegroundPid
                                $foregroundStatus['exit_epoch_s'] = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0
                                $foregroundStatus['note'] = 'Godot retained foreground during watched workload; complete report and successful process exit observed before accepting normal end-of-run focus transfer. Pixel review still required.'
                                Write-Host "A7_EVIDENCE_NORMAL_EXIT_FOCUS_TRANSFER game=$($p.Id) foreground=$watchForegroundPid report=$reportName"
                                break
                            }
                        }
                        $foregroundStatus.foreground_loss_detected = $true
                        $foregroundStatus.verified = $false
                        $foregroundStatus.foreground_pid = [int]$watchForegroundPid
                        $foregroundStatus.lost_epoch_s = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0
                        $foregroundStatus | ConvertTo-Json -Depth 4 |
                            Set-Content -LiteralPath (Join-Path $folder 'a7_foreground.json') -Encoding UTF8
                        Write-Warning "A7_EVIDENCE_FOREGROUND_LOST game=$($p.Id) actual=$watchForegroundPid"
                        $foregroundFailure = 'A7_EVIDENCE_FOREGROUND_LOST: another process assumed focus before verified normal completion; campaign invalid'
                        try { if (-not $p.HasExited) { $p.Kill(); $p.WaitForExit() } } catch {}
                        break # Always finalize PresentMon before propagating failure
                    }
                }
                if (-not $foregroundFailure) {
                    $foregroundStatus.continuity_verified = $true
                    $foregroundStatus.completed_epoch_s = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()/1000.0
                    $foregroundStatus | ConvertTo-Json -Depth 4 |
                        Set-Content -LiteralPath (Join-Path $folder 'a7_foreground.json') -Encoding UTF8
                    Write-Host "A7_EVIDENCE_FOREGROUND_CONTINUITY_CONFIRMED checks=$($foregroundStatus.checks)"
                }
            } else {
                $p.WaitForExit()
            }
            if ($PresentMonExe) {
                if ($null -ne $pmProcess -and -not $pmStatus.collection_started) {
                    if (-not $pmStatus.capture_error) { $pmStatus.capture_error = 'PRESENTMON_DEFERRED_NEVER_STARTED' }
                    $pmProcess.Dispose()
                }
                if ($null -ne $pmProcess -and $pmStatus.collection_started) {
                    try {
                        # Allow the finite PresentMon timer to expire and ETW output to flush.
                        # Retain fail-closed behavior if even the bounded deadline fails.
                        if (-not $pmProcess.WaitForExit(30000)) {
                            # Stop only this child collector, not unrelated ETW sessions.
                            $pmProcess.Kill()
                            $pmProcess.WaitForExit()
                            $pmStatus.capture_error='PRESENTMON_GRACEFUL_TIMEOUT_AFTER_30S'
                        }
                        $pmProcess.Refresh()
                        $pmStatus.exit_code=$pmProcess.ExitCode
                        $stderrText = $pmProcess.StandardError.ReadToEnd()
                        [System.IO.File]::WriteAllText([string]$pmStatus.stderr_path,$stderrText)
                        $lostEvents = [regex]::Match($stderrText, 'warning:\s*(\d+)\s+ETW events were lost', 'IgnoreCase')
                        if ($lostEvents.Success) { $pmStatus.etw_events_lost = [long]$lostEvents.Groups[1].Value }
                        $lostBuffers = [regex]::Match($stderrText, 'warning:\s*(\d+)\s+ETW buffers were lost', 'IgnoreCase')
                        if ($lostBuffers.Success) { $pmStatus.etw_buffers_lost = [long]$lostBuffers.Groups[1].Value }
                        if (-not [string]::IsNullOrWhiteSpace($stderrText)) {
                            Write-Warning "A7_PRESENTMON_STDERR: $($stderrText.Trim())"
                        }
                    } catch {
                        $pmStatus.capture_error=$_.Exception.Message
                    } finally {
                        $pmProcess.Dispose()
                    }
                }
                $pmStatus.csv_exists=Test-Path -LiteralPath $pmCsv
                if ($pmStatus.csv_exists) {
                    $pmStatus.csv_bytes=(Get-Item -LiteralPath $pmCsv).Length
                }
                $pmStatus | ConvertTo-Json -Depth 5 |
                    Set-Content -LiteralPath $pmStatusPath -Encoding UTF8
                Write-Host "A7_PRESENTMON_STATUS exit=$($pmStatus.exit_code) csv_bytes=$($pmStatus.csv_bytes) gpu_tracking=$($pmStatus.gpu_tracking_requested) etw_events_lost=$($pmStatus.etw_events_lost)"
            }
            $p.Refresh()
            $exitCode = $p.ExitCode
            $p.Dispose()
            if ($foregroundFailure) {
                # This runs after the PresentMon status/CSV flush. The outer
                # recorder wrapper can now archive all failure diagnostics.
                throw $foregroundFailure
            }
            if ($exitCode -ne 0) {
                throw "A7_RUN_FAIL scenario=$name seed=$seed rep=$r code=$exitCode"
            }
            $summary = Join-Path $folder ($(if ($isEdit) { 'a7_edits.json' } else { 'a7_route.json' }))
            if (-not (Test-Path $summary)) { throw "A7 missing report $summary" }
            $data = Get-Content -LiteralPath $summary -Raw | ConvertFrom-Json
            if ($data.seed -ne $seed -or $data.ci_smoke -ne [bool]$CiSmoke) {
                throw "A7 report provenance mismatch: $summary"
            }
            if ($isEdit) {
                if ($data.schema -ne 'a7_edit_v1' -or $data.requested_count -ne $count -or
                    $data.edit_100_gate -ne 'NOT_QUALIFIED') {
                    throw "A7 invalid edit report: $summary"
                }
            } else {
                if ($data.schema -ne 'a7_route_v1' -or $data.frame_count -le 0 -or
                    $data.perf_60_full_present_gate -ne 'NOT_QUALIFIED') {
                    throw "A7 invalid route report: $summary"
                }
            }
            $expected++
            Write-Host "A7_RUN_RECORDED scenario=$name seed=$seed rep=$r strict_gates=NOT_QUALIFIED"
        }
    }
}
Write-Host "A7_CAMPAIGN_DONE=$rootOutput reports=$expected"
& python (Join-Path $root 'scripts/a7_report.py') $rootOutput
if ($LASTEXITCODE -ne 0) { throw 'A7 REPORT compiler failed' }
Write-Host 'A7_NO_AUTOMATIC_ACCEPTANCE: graphics, depth pixels and full CPU+GPU+present require independent evidence.'
