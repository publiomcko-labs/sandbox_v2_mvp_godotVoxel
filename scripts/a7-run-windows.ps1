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
    [double] $Duration = 0,
    [switch] $Full,
    [switch] $Capture,
    [switch] $CiSmoke,
    [switch] $VsyncOff,
    [ValidateRange(0,48)] [int] $VoxelThreads = 0,
    [switch] $ResourceTelemetry,
    [string] $PresentMonExe = '',
    [switch] $PresentMonNoGpu
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
if ($PresentMonExe -and ($CiSmoke -or $Full -or $Capture -or $VoxelThreads -ne 0)) {
    throw 'A7 PresentMon ETW is restricted to non-headless isolated timed routes with automatic voxel threads and no screenshot readback'
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
    resource_diagnostic=[bool]($VsyncOff -or $VoxelThreads -ne 0 -or $ResourceTelemetry)
    vsync_off_requested=[bool]$VsyncOff
    voxel_threads_requested=$VoxelThreads
    process_cpu_sampling=[bool]$ResourceTelemetry
    presentmon_requested=[bool]$PresentMonExe
    presentmon_gpu_tracking_requested=[bool]($PresentMonExe -and -not $PresentMonNoGpu)
    target_resolution='1920x1080'; target_speed_mps=18.0
    requested_view_distance_m=192; visual_radius_target_m=130
    mesh_block_voxels=16; lod_count=4; lod_distance=48
    seeds=@($runSeeds); repeats=$reps; scenarios=@($scenarios)
    warmup_s=$Warmup; duration_override_s=$Duration
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
                if ($Duration -gt 0) { $argsList += "--duration=$Duration" }
            }
            if ($Capture) { $argsList += '--capture' }
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
                    $pmTimedSeconds = [int][Math]::Ceiling($Warmup + $Duration + 8.0)
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
                    $pmStatus.collection_started = [bool]$pmProcess.Start()
                    Write-Host "A7_PRESENTMON_START pid=$($p.Id) session=$pmSession started=$($pmStatus.collection_started) output=$pmCsv"
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
            } else {
                $p.WaitForExit()
            }
            if ($PresentMonExe) {
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
