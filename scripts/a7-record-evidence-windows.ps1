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
    [switch] $SkipVideo
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runner = Join-Path $PSScriptRoot 'a7-run-windows.ps1'
$routes = @('stationary_180s','straight_18mps_600s','turns_18mps_300s',
    'out_and_back_18mps_300s','shoreline_180s','cave_180s','rocks_water_180s')
$edits = @('edit_idle_100','edit_moving_100','boundary_edit_100')
if (($Mode -eq 'Route' -and $routes -notcontains $Scenario) -or
    ($Mode -eq 'Edit' -and $edits -notcontains $Scenario)) {
    throw 'A7_EVIDENCE_MODE_SCENARIO_MISMATCH'
}
if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'A7_EVIDENCE_REQUIRES_INTERACTIVE_DESKTOP'
}
Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if ($screen.Width -ne 1920 -or $screen.Height -ne 1080 -or
    $screen.X -ne 0 -or $screen.Y -ne 0) {
    throw "A7_EVIDENCE_REQUIRES_PRIMARY_1920X1080_AT_ORIGIN current=$($screen.X),$($screen.Y),$($screen.Width)x$($screen.Height)"
}

$ff = $null
$ffhash = $null
if (-not $SkipVideo) {
    if (-not $FfmpegExe) {
        throw 'A7_EVIDENCE_FFMPEG_REQUIRED: specify -FfmpegExe or explicitly -SkipVideo'
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
$childSucceeded = $false
$start = $null
$end = $null
$previous = $env:A7_CAMPAIGN_DIR
$manifestPath = Join-Path $campaign 'visual_evidence_manifest.json'
try {
    if (-not $SkipVideo) {
        # gdigrab captures the entire physical PRIMARY display at 60fps.
        # A7 evidence-only Godot windows are borderless 1920x1080 at (0,0).
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
    if ($Mode -eq 'Route') { $params.Duration = $Duration }
    & $runner @params
    $childSucceeded = $?
} finally {
    $end = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0
    $env:A7_CAMPAIGN_DIR = $previous
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
        } catch {
            $recordingError = $_.Exception.Message
        } finally {
            $recording.Dispose()
        }
    }
    $videoBytes = if (Test-Path -LiteralPath $video) { (Get-Item -LiteralPath $video).Length } else { 0 }
    $videoValid = $SkipVideo -or ($videoBytes -gt 1000000 -and
        $recordingExitCode -eq 0 -and -not $recordingError)
    $manifest = [ordered]@{
        schema = 'a7_visual_evidence_manifest_v1'
        mode = $Mode
        scenario = $Scenario
        seed = $Seed
        warmup_s = $Warmup
        duration_override_s = $(if ($Mode -eq 'Route') { $Duration } else { $null })
        git_sha = (& git -C $root rev-parse HEAD).Trim()
        recording_begin_epoch_s = $start
        recording_end_epoch_s = $end
        video_path = $(if ($SkipVideo) { $null } else { $video })
        video_fps_requested = $(if ($SkipVideo) { 0 } else { 60 })
        desktop_primary_px = '1920x1080'
        desktop_offset_xy = @($screen.X,$screen.Y)
        recorder_sha256 = $ffhash
        video_bytes = $videoBytes
        video_exit_code = $recordingExitCode
        video_error = $recordingError
        video_capture_valid_container = [bool]$videoValid
        game_run_succeeded = [bool]$childSucceeded
        instrumentation_overhead = 'external recorder and screenshots; NOT comparable PERF-60 measurement'
        video_actual_fps_verified = $false
        video_timestamp_alignment_verified = $false
        terrain_pixels_correct_verified = $false
        depth_130m_verified = $false
        first_correct_presented_pixel_verified = $false
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
if (-not $childSucceeded) { throw 'A7_EVIDENCE_GAME_RUN_FAILED' }
if (-not $videoValid) { throw "A7_EVIDENCE_VIDEO_MISSING_OR_INVALID exit=$recordingExitCode bytes=$videoBytes error=$recordingError" }
Write-Host "A7_EVIDENCE_RECORDED mode=$Mode scenario=$Scenario video_requested=$(-not [bool]$SkipVideo) strict=NOT_QUALIFIED"
