param(
    [string] $PresentMonExe,
    [int] $Seed = 20261119,
    [ValidateRange(20,120)] [int] $Warmup = 45,
    [switch] $FastSmoke,
    [switch] $EtwStressProbe,
    [switch] $EtwWindowProbe,
    [switch] $DisplayOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runner = Join-Path $root 'scripts/a7-run-windows.ps1'
$reporter = Join-Path $root 'scripts/a7_streaming_present_report.py'
$etwGuard = Join-Path $root 'scripts/a7-etw-session-guard.ps1'
$presentMonHash = 'B2A706BC6AD475749E3B7E3409263AA1E6906D45BDCF993F6DBC0F660188F1AF'
if (([int][bool]$FastSmoke + [int][bool]$EtwStressProbe + [int][bool]$EtwWindowProbe) -gt 1) {
    throw 'A7_ETW_DIAGNOSTIC_MODES_MUTUALLY_EXCLUSIVE'
}
if (-not $PresentMonExe -or -not (Test-Path -LiteralPath $PresentMonExe)) {
    throw 'A7_PRESENTMON_REQUIRED: verified Intel PresentMon 2.6.0 standalone exe is mandatory for the paired stress diagnostics'
}
if ((Get-FileHash -LiteralPath $PresentMonExe -Algorithm SHA256).Hash -ne $presentMonHash) {
    throw 'A7_PRESENTMON_HASH_MISMATCH: external executable does not match the pinned release'
}
if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'A7_STREAMING_REQUIRES_INTERACTIVE_DESKTOP (Session 0 is not acceptable)'
}
# PresentMon ETW requires Performance Log Users membership or elevation. Do NOT
# elevate the GitHub Actions runner; its workflows should remain unprivileged.
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
$perfLogUsersSid = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-559')
$etwAuthorized = [bool]($principal.IsInRole($perfLogUsersSid) -or
    $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))
if (-not $etwAuthorized) {
    Write-Warning 'A7_ETW_ACCESS_UNAVAILABLE: runner token lacks Performance Log Users; presentation metrics will be NOT_MEASURED (no implicit elevation).'
} else {
    # Validate/recover stale A7 sessions BEFORE launching Godot. Never touch
    # other ETW namespaces and never stop a live PresentMon collector.
    & $etwGuard -Mode Preflight -PresentMonExe $PresentMonExe
}
$gpu = @(Get-CimInstance Win32_VideoController | ForEach-Object Name)
if ($env:COMPUTERNAME -ne 'DESKTOP-SAFGO15' -or -not ($gpu -contains 'NVIDIA GeForce GTX 1050 Ti')) {
    throw 'A7_STREAMING_HOST_MISMATCH: A7 baseline requires DESKTOP-SAFGO15 and NVIDIA GTX 1050 Ti'
}

# A5/CPU16 unchanged; same seed, automatic VoxelEngine worker count,
# all telemetry enabled in both arms. Higher sustained streaming stress.
$routes = @(
    [pscustomobject]@{name='straight_18mps_600s'; duration=300},
    [pscustomobject]@{name='turns_18mps_300s'; duration=180},
    [pscustomobject]@{name='rocks_water_180s'; duration=180},
    [pscustomobject]@{name='shoreline_180s'; duration=180}
)
if ($FastSmoke) {
    $routes = @([pscustomobject]@{name='shoreline_180s'; duration=30})
    $Warmup = 20
} elseif ($EtwStressProbe) {
    # Probe a sustained 45s warmup / 90s route on one VSync arm. Never
    # launch all eight routes until at least this display trace is usable.
    $routes = @([pscustomobject]@{name='shoreline_180s'; duration=90})
    $Warmup = 45
} elseif ($EtwWindowProbe) {
    # Full 90s route, but PresentMon starts 60s after Godot launch and
    # captures just 30s during the measured motion; avoids 135s ETW sessions.
    # This sample is PARTIAL; it must never qualify the full A7 acceptance gate.
    $routes = @([pscustomobject]@{name='shoreline_180s'; duration=90})
    $Warmup = 45
}
$campaign = Join-Path $root ('reports/generated/a7-streaming-present/campaign-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID")
New-Item -ItemType Directory -Force -Path $campaign | Out-Null
$previous = $env:A7_CAMPAIGN_DIR
$manifest = [ordered]@{
    schema='a7_streaming_present_manifest_v1'
    git_sha=(& git -C $root rev-parse HEAD).Trim()
    baseline='A5 CPU16 GL Compatibility, VoxelEngine automatic workers'
    presentmon_version='2.6.0'
    presentmon_sha256=$presentMonHash.ToLowerInvariant()
    presentmon_etw_permission_available=$etwAuthorized
    presentmon_collection_requested=$etwAuthorized
    etw_stress_probe=[bool]$EtwStressProbe
    etw_window_probe=[bool]$EtwWindowProbe
    display_only=[bool]$DisplayOnly
    presentmon_permission_note='No GitHub runner elevation; grant Performance Log Users membership manually and refresh logon token to enable ETW.'
    display_target='1920x1080 window'
    gpu_expected='NVIDIA GeForce GTX 1050 Ti'
    speed_mps=18
    warmup_s=$Warmup
    seed=$Seed
    routes=@($routes)
    process_telemetry_sample_period_s=1
    diagnostics='identical Godot and process telemetry for both VSync arms; display-only ETW disables GPUTime metrics and must not be compared to full ETW as equivalent instrumentation'
    strict_acceptance='NOT_QUALIFIED'
    runs=@()
}
$seq=0
$routeIndex=0
try {
    foreach ($route in $routes) {
        # Alternate which arm runs first by route, without changing the game.
        $arms = if ($FastSmoke -or $EtwStressProbe -or $EtwWindowProbe) { @('on') } elseif ($routeIndex % 2 -eq 0) { @('on','off') } else { @('off','on') }
        $routeIndex++
        foreach ($arm in $arms) {
            $seq++
            $label = "s{0:D2}_{1}_{2}" -f $seq,$route.name,("vsync_"+$arm)
            $target = Join-Path $campaign $label
            $env:A7_CAMPAIGN_DIR = $target
            $row = [ordered]@{
                sequence=$seq; directory=$label; profile=("vsync_"+$arm)
                route=$route.name; duration_s=$route.duration
                seed=$Seed; voxel_threads_requested=0
                etw_collection_requested=$etwAuthorized
                gpu_tracking_requested=(-not [bool]$DisplayOnly)
            }
            $manifest.runs += $row
            $manifest | ConvertTo-Json -Depth 8 |
                Set-Content -LiteralPath (Join-Path $campaign 'streaming_manifest.json') -Encoding UTF8
            Write-Host "A7_STREAM_PRESENT_START sequence=$seq profile=$($row.profile) route=$($route.name) seconds=$($route.duration)"
            $params = @{
                Scenario=$route.name
                Seeds=@($Seed)
                Warmup=[double]$Warmup
                Duration=[double]$route.duration
                VsyncOff=($arm -eq 'off')
                ResourceTelemetry=$true
                VoxelThreads=0
                PresentMonExe=$(if ($etwAuthorized) { $PresentMonExe } else { '' })
                PresentMonNoGpu=($DisplayOnly -and $etwAuthorized)
                PresentMonStartDelaySeconds=$(if ($EtwWindowProbe -and $etwAuthorized) {60} else {0})
                PresentMonCaptureSeconds=$(if ($EtwWindowProbe -and $etwAuthorized) {30} else {0})
            }
            $childSucceeded = $false
            try {
                & $runner @params
                $childSucceeded = $?
            } finally {
                if ($etwAuthorized) {
                    # Clean only the session recorded by this child's status;
                    # an exception in the runner must not leave ETW active.
                    $ownedStatus = Get-ChildItem -LiteralPath $target -Recurse -File -Filter 'a7_presentmon_status.json' |
                        Select-Object -First 1
                    if ($null -ne $ownedStatus) {
                        $owned = Get-Content -LiteralPath $ownedStatus.FullName -Raw | ConvertFrom-Json
                        if ($owned.etw_session_name) {
                            & $etwGuard -Mode Postflight -PresentMonExe $PresentMonExe -SessionName $owned.etw_session_name
                        }
                    }
                }
            }
            if (-not $childSucceeded) { throw "A7_STREAMING_CHILD_FAILED $label" }
            $pmStatusPath = Get-ChildItem -LiteralPath $target -Recurse -File -Filter 'a7_presentmon_status.json' |
                Select-Object -First 1
            if ($null -eq $pmStatusPath) {
                if ($etwAuthorized) {
                    throw "A7_ETW_STATUS_MISSING ${label}: ETW enabled but no status; refusing further routes"
                }
                Write-Host "A7_ETW_NOT_MEASURED $label reason=PERFORMANCE_LOG_USERS_PERMISSION_REQUIRED"
            } else {
                $pm = Get-Content -LiteralPath $pmStatusPath.FullName -Raw | ConvertFrom-Json
                if (-not $pm.collection_started -or $pm.exit_code -ne 0 -or $pm.csv_bytes -lt 1024) {
                    if ($etwAuthorized) {
                        throw "A7_ETW_CAPTURE_FAILED_FAST $label exit=$($pm.exit_code) csv_bytes=$($pm.csv_bytes) lost_events=$($pm.etw_events_lost) error=$($pm.capture_error)"
                    }
                    Write-Warning "A7_ETW_NOT_MEASURED $label exit=$($pm.exit_code) csv_bytes=$($pm.csv_bytes) error=$($pm.capture_error)"
                } elseif ($null -ne $pm.etw_events_lost -and [long]$pm.etw_events_lost -gt 0) {
                    # A clean collector exit and a nonzero CSV do not prove a lossless trace.
                    if ($etwAuthorized) {
                        throw "A7_ETW_EVENTS_LOST $label count=$($pm.etw_events_lost): refusing further routes"
                    }
                    Write-Warning "A7_ETW_EVENTS_LOST $label count=$($pm.etw_events_lost)"
                } else {
                    Write-Host "A7_STREAM_PRESENT_CAPTURED $label csv_bytes=$($pm.csv_bytes) etw_session=$($pm.etw_session_name) gpu_tracking=$($pm.gpu_tracking_requested)"
                }
            }
        }
    }
    & python $reporter $campaign
    if ($LASTEXITCODE -ne 0) { throw 'A7_STREAMING_REPORT_FAILED' }
    $comparison = Get-Content -LiteralPath (Join-Path $campaign 'streaming_comparison.json') -Raw | ConvertFrom-Json
    if ($EtwWindowProbe) {
        if ($etwAuthorized -and $comparison.etw_partial_aligned_count -ne $comparison.route_count) {
            throw "A7_ETW_WINDOW_PROBE_NOT_ALIGNED: partial=$($comparison.etw_partial_aligned_count)/$($comparison.route_count)"
        }
        Write-Host "A7_ETW_WINDOW_VALIDATED_PARTIAL=$($comparison.etw_partial_aligned_count)/$($comparison.route_count) full=$($comparison.etw_aligned_count)"
    }
    if (($FastSmoke -or $EtwStressProbe) -and $comparison.etw_aligned_count -ne $comparison.route_count) {
        if ($etwAuthorized) {
            throw "A7_ETW_PROBE_NOT_ALIGNED: $($comparison.etw_aligned_count)/$($comparison.route_count); do not run full campaign"
        }
        Write-Warning "A7_PRESENTMON_PREFLIGHT_NOT_ALIGNED: $($comparison.etw_aligned_count)/$($comparison.route_count); streaming may proceed, but full presentation metric remains NOT_QUALIFIED"
    }
    foreach ($run in $comparison.runs) {
        if ($run.presentation_status -ne 'ETW_ALIGNED' -and
            -not ($EtwWindowProbe -and $run.presentation_status -eq 'ETW_PARTIAL_ALIGNED')) {
            Write-Warning "A7_ETW_NOT_QUALIFIED route=$($run.route) profile=$($run.profile) status=$($run.presentation_status) reason=$($run.reason)"
        }
    }
    Write-Host "A7_STREAMING_CAMPAIGN_DONE=$campaign"
    Write-Host "A7_STREAMING_ETW_ALIGNED=$($comparison.etw_aligned_count)/$($comparison.route_count)"
    Write-Host 'A7_STRICT_GATES_REMAIN_NOT_QUALIFIED'
} finally {
    $env:A7_CAMPAIGN_DIR = $previous
    # Preserve original ETW data in lossless compressed files for GitHub upload.
    # Avoid uploading uncompressed hundreds of MB of frame-level CSV.
    if (Test-Path -LiteralPath $campaign) {
        Get-ChildItem -LiteralPath $campaign -Recurse -Filter 'a7_presentmon.csv' -File | ForEach-Object {
            try {
                Compress-Archive -LiteralPath $_.FullName -DestinationPath ($_.FullName+'.zip') -CompressionLevel Optimal -Force
                Remove-Item -LiteralPath $_.FullName -Force
            } catch {
                Write-Warning "A7_PRESENTMON_ARCHIVE_WARNING $($_.Exception.Message)"
            }
        }
    }
}
