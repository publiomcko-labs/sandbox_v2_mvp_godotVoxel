param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Route','Edit')]
    [string] $Mode,
    [ValidateSet('stationary_180s','straight_18mps_600s','turns_18mps_300s',
        'out_and_back_18mps_300s','shoreline_180s','cave_180s',
        'rocks_water_180s','edit_idle_100','edit_moving_100','boundary_edit_100')]
    [string] $Scenario = 'shoreline_180s',
    [int] $Seed = 20261119,
    [ValidateRange(0,180)] [double] $Warmup = 20,
    [ValidateRange(1,600)] [double] $Duration = 30,
    [string] $FfmpegExe = '',
    [string] $PresentMonExe = '',
    [switch] $SkipVideo,
    [switch] $NoStills
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runner = Join-Path $PSScriptRoot 'a7-run-windows.ps1'
$etwGuard = Join-Path $PSScriptRoot 'a7-etw-session-guard.ps1'
$routes = @('stationary_180s','straight_18mps_600s','turns_18mps_300s',
    'out_and_back_18mps_300s','shoreline_180s','cave_180s','rocks_water_180s')
$edits = @('edit_idle_100','edit_moving_100','boundary_edit_100')
if ($NoStills -and -not $SkipVideo) {
    throw 'A7_EVIDENCE_NO_STILLS_ONLY_WITH_SKIP_VIDEO: external video mode already disables Godot readbacks'
}
if (($Mode -eq 'Route' -and $routes -notcontains $Scenario) -or
    ($Mode -eq 'Edit' -and $edits -notcontains $Scenario)) {
    throw 'A7_EVIDENCE_MODE_SCENARIO_MISMATCH'
}
if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'A7_EVIDENCE_REQUIRES_INTERACTIVE_DESKTOP'
}
Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if ($screen.Width -lt 1920 -or $screen.Height -lt 1080 -or
    $screen.X -ne 0 -or $screen.Y -ne 0) {
    throw "A7_EVIDENCE_REQUIRES_MIN_1920X1080_AT_ORIGIN current=$($screen.X),$($screen.Y),$($screen.Width)x$($screen.Height)"
}
Write-Host "A7_EVIDENCE_WINDOW_CROP=1920x1080 monitor=$($screen.Width)x$($screen.Height) desktop_resolution_unchanged=True"

$ff = $null
$ffhash = $null
$presentMonPath = $null
$presentMonHash = 'B2A706BC6AD475749E3B7E3409263AA1E6906D45BDCF993F6DBC0F660188F1AF'
if ($PresentMonExe) {
    if ($Mode -ne 'Edit') {
        throw 'A7_EVIDENCE_ETW_ONLY_SUPPORTED_FOR_EDIT'
    }
    if (-not (Test-Path -LiteralPath $PresentMonExe -PathType Leaf)) {
        throw 'A7_EVIDENCE_PRESENTMON_NOT_FOUND'
    }
    $presentMonPath = (Resolve-Path -LiteralPath $PresentMonExe).Path
    if ((Get-FileHash -LiteralPath $presentMonPath -Algorithm SHA256).Hash -ne $presentMonHash) {
        throw 'A7_EVIDENCE_PRESENTMON_HASH_MISMATCH'
    }
    & $etwGuard -Mode Preflight -PresentMonExe $presentMonPath
}
if (-not $SkipVideo) {
    if (-not $FfmpegExe) {
        # A7 can operate without a machine-wide FFmpeg installation, PATH
        # changes or winget. A versioned ZIP is verified before extraction.
        $bootstrap = Join-Path $PSScriptRoot 'a7-bootstrap-ffmpeg-windows.ps1'
        & $bootstrap
        if (-not $?) { throw 'A7_EVIDENCE_FFMPEG_BOOTSTRAP_FAILED' }
        $FfmpegExe = Join-Path $root 'reports/tools/a7-ffmpeg-7.1.1/ffmpeg-7.1.1-essentials_build/bin/ffmpeg.exe'
    }
    if (-not (Test-Path -LiteralPath $FfmpegExe -PathType Leaf)) {
        throw 'A7_EVIDENCE_FFMPEG_NOT_FOUND'
    }
    $ff = (Resolve-Path -LiteralPath $FfmpegExe).Path
    $ffhash = (Get-FileHash -LiteralPath $ff -Algorithm SHA256).Hash.ToLowerInvariant()
}

$campaign = Join-Path $root ('reports/generated/a7-visual-evidence/evidence-' +
    (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID")
New-Item -ItemType Directory -Force -Path $campaign | Out-Null
$video = Join-Path $campaign 'desktop-1080p-60fps.mkv'
$recording = $null
$recordingExitCode = $null
$recordingError = $null
$recordingStartedEpochS = $null
$recordingStoppedEpochS = $null
$etwGuardError = $null
$etwCaptureError = $null
$etwCaptureValid = $false
$childSucceeded = $false
$start = $null
$end = $null
$previous = $env:A7_CAMPAIGN_DIR
$manifestPath = Join-Path $campaign 'visual_evidence_manifest.json'
try {
    if (-not $SkipVideo) {
        # gdigrab captures only the 1920x1080 top-left part of the primary
        # display; Windows monitor mode and resolution remain untouched.
        # Godot's evidence-only window is borderless at (0,0). Other windows
        # must not obscure it, or the resulting video cannot qualify pixels.
        # This is a distinct, instrumented capture arm, NEVER a PERF-60 arm.
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $ff
        $psi.Arguments = ('-hide_banner -loglevel error -nostats -y ' +
            '-f gdigrab -framerate 60 -offset_x ' + $screen.X +
            ' -offset_y ' + $screen.Y +
            ' -video_size 1920x1080 -draw_mouse 0 -i desktop ' +
            '-c:v libx264 -preset ultrafast -crf 19 -pix_fmt yuv420p "' +
            $video + '"')
        $psi.WorkingDirectory = $root
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardInput = $true
        $recording = New-Object System.Diagnostics.Process
        $recording.StartInfo = $psi
        if (-not $recording.Start()) { throw 'A7_EVIDENCE_FFMPEG_START_FAILED' }
        $recordingStartedEpochS = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
        Write-Host "A7_EVIDENCE_VIDEO_STARTED pid=$($recording.Id) path=$video"
        Start-Sleep -Seconds 2
        if ($recording.HasExited) {
            throw "A7_EVIDENCE_FFMPEG_EXITED_EARLY exit=$($recording.ExitCode)"
        }
    }
    $start = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $env:A7_CAMPAIGN_DIR = Join-Path $campaign 'game'
    $params = @{
        Scenario = $Scenario
        Seeds = @($Seed)
        Warmup = $Warmup
        Capture = $true
    }
    if ($Mode -eq 'Route') {
        $params.Duration = $Duration
        # External video: ZERO in-engine GPU readbacks (no stutter induced by
        # get_viewport().get_texture().get_image()).
        # Without a video recorder, sample sparingly for static review only.
        $params.ScreenshotIntervalSeconds = if ($SkipVideo -and -not $NoStills) { 15.0 } else { 0.0 }
        Write-Host "A7_EVIDENCE_ROUTE_STILLS interval_s=$($params.ScreenshotIntervalSeconds)"
    } else {
        # All marker/timestamp observations remain; avoid inline PNG readback
        # when capturing the desktop externally, or when --NoStills requested.
        $params.EditNoStills = (-not $SkipVideo) -or [bool]$NoStills
        Write-Host "A7_EVIDENCE_EDIT_STILLS enabled=$(-not $params.EditNoStills)"
    }
    if ($presentMonPath) {
        # Distinct evidence-only arm: readback/video costs invalidate PERF-60.
        $params.PresentMonExe = $presentMonPath
        $params.EvidenceOnlyPresentMon = $true
    }
    & $runner @params
    $childSucceeded = $?
} finally {
    $end = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $env:A7_CAMPAIGN_DIR = $previous
    if ($presentMonPath) {
        try {
            $pmStatusFile = Get-ChildItem -LiteralPath (Join-Path $campaign 'game') -Recurse -File -Filter 'a7_presentmon_status.json' -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if ($null -ne $pmStatusFile) {
                $status = Get-Content -LiteralPath $pmStatusFile.FullName -Raw | ConvertFrom-Json
                if ($status.etw_session_name) {
                    & $etwGuard -Mode Postflight -PresentMonExe $presentMonPath -SessionName $status.etw_session_name
                }
                if ($status.collection_started -and $status.exit_code -eq 0 -and
                    $status.csv_bytes -ge 1024 -and
                    ($null -eq $status.etw_events_lost -or $status.etw_events_lost -eq 0) -and
                    ($null -eq $status.etw_buffers_lost -or $status.etw_buffers_lost -eq 0)) {
                    $etwCaptureValid = $true
                } else {
                    $etwCaptureError = "A7_EVIDENCE_ETW_CAPTURE_INVALID exit=$($status.exit_code) bytes=$($status.csv_bytes) lost=$($status.etw_events_lost)"
                }
            } else {
                $etwGuardError = 'A7_EVIDENCE_ETW_STATUS_MISSING'
            }
        } catch {
            $etwGuardError = $_.Exception.Message
        }
    }
    if ($null -ne $recording) {
        try {
            if (-not $recording.HasExited) {
                $recording.StandardInput.WriteLine('q')
                $recording.StandardInput.Flush()
                $recording.StandardInput.Close()
                if (-not $recording.WaitForExit(30000)) {
                    $recording.Kill()
                    $recording.WaitForExit()
                    $recordingError = 'A7_EVIDENCE_RECORDER_FORCE_KILLED'
                }
            }
            $recordingExitCode = $recording.ExitCode
            $recordingStoppedEpochS = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
        } catch {
            $recordingError = $_.Exception.Message
        } finally {
            $recording.Dispose()
        }
    }
    $videoBytes = if (Test-Path -LiteralPath $video) { (Get-Item -LiteralPath $video).Length } else { 0 }
    $videoValid = (-not $SkipVideo) -and ($videoBytes -gt 1000000 -and
        $recordingExitCode -eq 0 -and -not $recordingError)
    $captureValid = $SkipVideo -or $videoValid
    $manifest = [ordered]@{
        schema = 'a7_visual_evidence_manifest_v1'
        mode = $Mode
        scenario = $Scenario
        seed = $Seed
        warmup_s = $Warmup
        duration_override_s = $(if ($Mode -eq 'Route') { $Duration } else { $null })
        git_sha = (& git -C $root rev-parse HEAD).Trim()
        recording_process_started_epoch_s = $recordingStartedEpochS
        recording_process_stopped_epoch_s = $recordingStoppedEpochS
        game_invocation_begin_epoch_s = $start
        game_invocation_end_epoch_s = $end
        video_path = $(if ($SkipVideo) { $null } else { $video })
        video_fps_requested = $(if ($SkipVideo) { 0 } else { 60 })
        desktop_primary_px = "$($screen.Width)x$($screen.Height)"
        video_capture_region_xywh = @(0,0,1920,1080)
        desktop_mode_changed = $false
        desktop_offset_xy = @($screen.X,$screen.Y)
        recorder_sha256 = $ffhash
        recorder_source = $(if ($ff -and $ff.Contains('a7-ffmpeg-7.1.1')) { 'pinned_portable_7.1.1' } else { 'provided_path' })
        ffprobe_path = $(if ($ff) { Join-Path (Split-Path -Parent $ff) 'ffprobe.exe' } else { $null })
        presentmon_sha256 = $(if ($presentMonPath) { $presentMonHash.ToLowerInvariant() } else { $null })
        presentmon_requested = [bool]$presentMonPath
        presentmon_capture_valid = [bool]$etwCaptureValid
        presentmon_capture_error = $etwCaptureError
        etw_cleanup_error = $etwGuardError
        video_bytes = $videoBytes
        video_exit_code = $recordingExitCode
        video_error = $recordingError
        video_capture_valid_container = [bool]$videoValid
        capture_mode_valid = [bool]$captureValid
        in_engine_stills_requested = (-not $NoStills) -and [bool]$SkipVideo
        in_engine_screenshot_interval_s = $(if ($Mode -eq 'Route' -and $SkipVideo -and -not $NoStills) { 15.0 } else { 0.0 })
        game_run_succeeded = [bool]$childSucceeded
        instrumentation_overhead = 'external recorder and screenshots; NOT comparable PERF-60 measurement'
        video_actual_fps_verified = $false
        video_timestamp_alignment_verified = $false
        terrain_pixels_correct_verified = $false
        depth_130m_verified = $false
        first_correct_presented_pixel_verified = $false
        presentmon_edit_trace_verified = $false
        strict_gates = 'NOT_QUALIFIED'
        review_required = @('Verify actual monitor/game window coverage',
            'Review full-rate video for missing terrain, water, rocks and seams',
            'Verify 360-degree 130m pixel/depth coverage independently',
            'For edits correlate scripted call UTC, video marker, real changed terrain pixels and ETW present')
    }
    $manifest | ConvertTo-Json -Depth 8 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8
    Write-Host "A7_EVIDENCE_MANIFEST=$manifestPath video_bytes=$videoBytes game_ok=$childSucceeded"
}
if ($etwGuardError) { throw "A7_EVIDENCE_ETW_CLEANUP_FAILED $etwGuardError" }
if ($presentMonPath -and -not $etwCaptureValid) {
    throw "A7_EVIDENCE_ETW_CAPTURE_FAILED $etwCaptureError"
}
if (-not $childSucceeded) { throw 'A7_EVIDENCE_GAME_RUN_FAILED' }
if (-not $captureValid) { throw "A7_EVIDENCE_VIDEO_MISSING_OR_INVALID exit=$recordingExitCode bytes=$videoBytes error=$recordingError" }
if ($SkipVideo) {
    Write-Warning 'A7_NO_VIDEO: still-image evidence cannot prove continuous STREAM-18 or EDIT-100 presentation'
}
Write-Host "A7_EVIDENCE_RECORDED mode=$Mode scenario=$Scenario video_requested=$(-not [bool]$SkipVideo) strict=NOT_QUALIFIED"
