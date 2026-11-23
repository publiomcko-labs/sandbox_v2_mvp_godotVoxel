param(
    [ValidateSet('static_remove','static_add','boundary_remove','boundary_add')]
    [string] $Scenario = 'static_remove',
    [ValidateRange(5,180)] [int] $Warmup = 45,
    [ValidateRange(0,10000)] [int] $WarmupFrames = 0,
    [int] $Seed = 20261119,
    [string] $FfmpegExe = '',
    [string] $OutputDirectory = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$project = Join-Path $root 'godot'
$godot = Join-Path $root '.tools/godot.exe'
if (-not (Test-Path -LiteralPath $godot)) { throw 'A74_GODOT_NOT_BOOTSTRAPPED' }
if (-not (Test-Path -LiteralPath (Join-Path $project 'bin/sandbox_native.windows.template_debug.x86_64.dll'))) {
    throw 'A74_A5_NATIVE_DLL_MISSING'
}
Add-Type -AssemblyName System.Windows.Forms
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if ($screen.X -ne 0 -or $screen.Y -ne 0 -or $screen.Width -lt 1920 -or $screen.Height -lt 1080) {
    throw 'A74_DISPLAY_REQUIRED primary >=1920x1080 at origin (0,0)'
}
if (-not ('A74Window' -as [type])) {
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class A74Window {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
'@
}
if (-not $FfmpegExe) {
    & (Join-Path $PSScriptRoot 'a7-bootstrap-ffmpeg-windows.ps1')
    if (-not $?) { throw 'A74_FFMPEG_BOOTSTRAP_FAILED' }
    $FfmpegExe = Join-Path $root 'reports/tools/a7-ffmpeg-7.1.1/ffmpeg-7.1.1-essentials_build/bin/ffmpeg.exe'
}
$ff = (Resolve-Path -LiteralPath $FfmpegExe).Path
$ffprobe = Join-Path (Split-Path $ff -Parent) 'ffprobe.exe'
if (-not (Test-Path -LiteralPath $ffprobe)) { throw 'A74_FFPROBE_MISSING' }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$folder = if ($OutputDirectory) { [IO.Path]::GetFullPath($OutputDirectory) } else {
    Join-Path $root "reports/generated/a74-pilot/$Scenario-$stamp-$PID"
}
$generated = [IO.Path]::GetFullPath((Join-Path $root 'reports/generated')).TrimEnd('\') + '\'
if (-not ([IO.Path]::GetFullPath($folder)).StartsWith($generated, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'A74_OUTPUT_DIR_MUST_BE_UNDER_REPORTS_GENERATED'
}
if (Test-Path -LiteralPath $folder) { throw "A74_OUTPUT_DIR_ALREADY_EXISTS $folder" }
New-Item -ItemType Directory -Force -Path $folder | Out-Null
$video = Join-Path $folder 'desktop-1080p-60fps.mkv'
$previousOut = $env:A74_OUTPUT_DIR
$previousSave = $env:A3_SAVE_PATH
$previousRock = $env:A4_ROCK_STATE_PATH
$env:A74_OUTPUT_DIR = $folder
$env:A3_SAVE_PATH = Join-Path $folder 'world.sqlite'
$env:A4_ROCK_STATE_PATH = Join-Path $folder 'rocks.json'
$recording = $null
$game = $null
$gameExit = $null
$recorderExit = $null
$recorderError = $null
$foregroundOk = $false
$focusObserved = $false
$focusError = $null
$runnerError = $null
$warmupObservedFrames = $null
$warmupObservedMs = $null
$recorderHandshakeOk = $false
try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ff
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.Arguments = ('-hide_banner -loglevel error -nostats -y ' +
        '-f lavfi -i "ddagrab=output_idx=0:framerate=60:video_size=1920x1080:' +
        'offset_x=0:offset_y=0:draw_mouse=0:dup_frames=0" ' +
        '-fps_mode passthrough -c:v h264_nvenc -preset p1 -cq 18 -bf 0 "' + $video + '"')
    # Start Godot first. The 1000 rendered-frame warmup happens without video
    # capture/encoding. Once its immutable SDF reference is ready, start FFmpeg,
    # then release Godot to show the eight clock markers and one edit.
    $args = @('--path', ('"' + $project + '"'), '--script', 'res://tests/a74_pilot.gd',
        '--', "--scenario=$Scenario", "--warmup=$Warmup",
        "--warmup-frames=$WarmupFrames", "--seed=$Seed")
    $game = Start-Process -FilePath $godot -ArgumentList $args -WorkingDirectory $root -PassThru
    Write-Host "A74_PILOT_START scenario=$Scenario game_pid=$($game.Id) warmup_frames=$WarmupFrames"
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $focusWaitUntil = 15.0
    $readyPath = Join-Path $folder 'a74_ready.json'
    $releasePath = Join-Path $folder 'a74_capture_start.flag'
    while (-not $game.HasExited) {
        if (-not $recorderHandshakeOk -and (Test-Path -LiteralPath $readyPath)) {
            $ready = Get-Content -LiteralPath $readyPath -Raw | ConvertFrom-Json
            if ($ready.schema -ne 'a74_capture_ready_v1' -or
                $ready.scenario -ne $Scenario -or $ready.seed -ne $Seed -or
                $ready.camera_fixed -ne $true -or $ready.reference_written -ne $true -or
                $ready.warmup_frames_requested -ne $WarmupFrames) {
                throw 'A74_INVALID_CAPTURE_READY_HANDSHAKE'
            }
            $warmupObservedFrames = [int]$ready.warmup_frames_observed
            $warmupObservedMs = [int]$ready.warmup_elapsed_ms
            if ($WarmupFrames -gt 0 -and $warmupObservedFrames -lt $WarmupFrames) {
                throw 'A74_WARMUP_INSUFFICIENT_DRAWN_FRAMES'
            }
            $recording = New-Object System.Diagnostics.Process
            $recording.StartInfo = $psi
            if (-not $recording.Start()) { throw 'A74_FFMPEG_START_FAILED' }
            Start-Sleep -Seconds 2
            if ($recording.HasExited) { throw 'A74_FFMPEG_EXITED_EARLY' }
            Set-Content -LiteralPath $releasePath -Value 'A74_CAPTURE_READY' -Encoding ASCII
            $recorderHandshakeOk = $true
            Write-Host "A74_VIDEO_AFTER_WARMUP_OK pid=$($recording.Id) drawn_frames=$warmupObservedFrames warmup_ms=$warmupObservedMs"
        }
        $h = [A74Window]::GetForegroundWindow()
        [uint32] $activePid = 0
        [void][A74Window]::GetWindowThreadProcessId($h, [ref]$activePid)
        if ($activePid -eq [uint32]$game.Id) {
            $focusObserved = $true
        } elseif ($focusObserved) {
            # An unrelated desktop app covering the game is invalid evidence.
            # Expected focus transfer AFTER a fully written pilot report is permitted.
            $reportPath = Join-Path $folder 'a74_result.json'
            $done = $false
            if (Test-Path -LiteralPath $reportPath) {
                try {
                    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
                    $done = ($report.schema -eq 'a74_pilot_result_v1' -and
                             $report.accepted_count -eq 1 -and
                             $report.scenario -eq $Scenario)
                } catch { $done = $false }
            }
            if (-not $done) {
                $focusError = "A74_FOREGROUND_LOST active=$activePid expected=$($game.Id)"
                break
            }
        } elseif ($clock.Elapsed.TotalSeconds -gt $focusWaitUntil) {
            $focusError = "A74_GAME_NEVER_FOREGROUND expected=$($game.Id)"
            break
        }
        $watchdogSeconds = if ($WarmupFrames -gt 0) { 240.0 } else { $Warmup + 70.0 }
        if ($clock.Elapsed.TotalSeconds -gt $watchdogSeconds) {
            $runnerError = 'A74_PILOT_TIMEOUT'
            break
        }
        if ($null -ne $recording -and $recording.HasExited) {
            $runnerError = 'A74_RECORDER_EXITED_DURING_GAME'
            break
        }
        Start-Sleep -Milliseconds 100
    }
    if (($focusError -or $runnerError) -and -not $game.HasExited) {
        $game.Kill()
        $game.WaitForExit()
    }
    if (-not $game.HasExited) { [void]$game.WaitForExit(15000) }
    $gameExit = $game.ExitCode
    $foregroundOk = [bool]($focusObserved -and -not $focusError)
    if (-not $recorderHandshakeOk) { $runnerError = 'A74_RECORDER_HANDSHAKE_MISSING' }
} catch {
    $runnerError = $_.Exception.Message
    if ($null -ne $game -and -not $game.HasExited) {
        $game.Kill()
        $game.WaitForExit()
        $gameExit = $game.ExitCode
    }
} finally {
    if ($null -ne $recording) {
        try {
            if (-not $recording.HasExited) {
                $recording.StandardInput.WriteLine('q')
                $recording.StandardInput.Flush()
                $recording.StandardInput.Close()
                if (-not $recording.WaitForExit(30000)) {
                    $recording.Kill()
                    $recording.WaitForExit()
                    $recorderError = 'A74_RECORDER_FORCED_STOP'
                }
            }
            $recorderExit = $recording.ExitCode
        } catch { $recorderError = $_.Exception.Message }
        $recording.Dispose()
    }
    if ($null -ne $game) { $game.Dispose() }
    $env:A74_OUTPUT_DIR = $previousOut
    $env:A3_SAVE_PATH = $previousSave
    $env:A4_ROCK_STATE_PATH = $previousRock
    $videoSize = if (Test-Path -LiteralPath $video) { (Get-Item -LiteralPath $video).Length } else { 0 }
    $videoValid = ($videoSize -gt 1000000 -and $recorderExit -eq 0 -and -not $recorderError)
    $manifest = [ordered]@{
        schema = 'a74_capture_manifest_v1'
        scenario = $Scenario
        seed = $Seed
        warmup_s = $(if ($WarmupFrames -eq 0) { $Warmup } else { $null })
        warmup_frames_requested = $WarmupFrames
        warmup_frames_observed = $warmupObservedFrames
        warmup_elapsed_ms = $warmupObservedMs
        recording_started_after_warmup = [bool]$recorderHandshakeOk
        git_sha = (& git -C $root rev-parse HEAD).Trim()
        game_exit_code = $gameExit
        ffmpeg_exit_code = $recorderExit
        ffmpeg_sha256 = (Get-FileHash -LiteralPath $ff -Algorithm SHA256).Hash.ToLowerInvariant()
        foreground_ok = [bool]$foregroundOk
        game_foreground_observed = [bool]$focusObserved
        foreground_error = $focusError
        runner_error = $runnerError
        recorder_error = $recorderError
        video_bytes = $videoSize
        video_container_valid = [bool]$videoValid
        desktop_region_xywh = @(0,0,1920,1080)
        desktop_mode_changed = $false
        capture_includes_recorder_overhead = $true
        presentmon_etw_aligned = $false
        raw_hid_captured = $false
        edit_100_gate = 'NOT_QUALIFIED'
    }
    $manifest | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $folder 'a74_capture_manifest.json') -Encoding UTF8
    Write-Host "A74_PILOT_EVIDENCE=$folder foreground_ok=$foregroundOk video_valid=$videoValid game_exit=$gameExit"
}
if ($runnerError) { throw "A74_RUN_FAILED $runnerError" }
if ($focusError) { throw $focusError }
if ($gameExit -ne 0) { throw "A74_GODOT_EXIT_NOT_ZERO $gameExit" }
if (-not $videoValid) { throw "A74_VIDEO_INVALID ffmpeg_exit=$recorderExit bytes=$videoSize" }
$analysis = Join-Path $PSScriptRoot 'a74_geometry_pilot.py'
python $analysis $folder --ffmpeg $ff --ffprobe $ffprobe
if ($LASTEXITCODE -ne 0) { throw "A74_ORACLE_AUDIT_FAILED $LASTEXITCODE" }
Write-Host "A74_PILOT_COMPLETE status=DIAGNOSTIC_ONLY strict=NOT_QUALIFIED evidence=$folder"
