param(
    [ValidateRange(1000,1000)] [int] $WarmupFrames = 1000
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$godot = Join-Path $root '.tools\godot.exe'
$reporter = Join-Path $PSScriptRoot 'a8_p4_depth_report.py'
if (-not (Test-Path -LiteralPath $godot -PathType Leaf)) { throw "A8_P4_GODOT_MISSING $godot" }
if (-not (Test-Path -LiteralPath $reporter -PathType Leaf)) { throw 'A8_P4_VALIDATOR_MISSING' }
if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'A8_P4_REQUIRES_INTERACTIVE_REAL_OPENGL_DESKTOP_NOT_RUNNER'
}
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if ($screen.Width -lt 1920 -or $screen.Height -lt 1080) {
    throw 'A8_P4_REQUIRES_PRIMARY_SCREEN_AT_LEAST_1920x1080'
}
$dest = Join-Path $root ('reports/generated/a8-p4/pilot-' +
    (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID")
if (Test-Path -LiteralPath $dest) { throw 'A8_P4_OUTPUT_COLLISION' }
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$oldOutput = $env:A8_P4_OUTPUT_DIR
$oldSave = $env:A3_SAVE_PATH
$exitCode = -1
$validatorExit = -1
$failure = $null
try {
    $env:A8_P4_OUTPUT_DIR = $dest
    $env:A3_SAVE_PATH = Join-Path $dest 'world.sqlite'
    $gitHead = (& git -C $root rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or $gitHead.Length -ne 40) {
        throw 'A8_P4_GIT_PROVENANCE_UNAVAILABLE'
    }
    $provenance = @{
        schema='a8_p4_windows_capture_manifest_v1'
        experiment='A8-P4'
        git_head=$gitHead
        baseline='A5_CPU16_GL_COMPATIBILITY'
        warmup_frames_requested=$WarmupFrames
        renderer='GL Compatibility OpenGL3'
        capture_arm='DEPTH_RGB_AND_SDF_ONLY_NOT_FPS_BENCHMARK'
        primary_resolution=@($screen.Width,$screen.Height)
        machine=$env:COMPUTERNAME
        started_utc=(Get-Date).ToUniversalTime().ToString('o')
        seed=20261119
        state='STARTED'
        strict_gates='NOT_QUALIFIED'
    }
    $manifest = Join-Path $dest 'a8_p4_capture_manifest.json'
    $provenance | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifest -Encoding UTF8
    Write-Host "A8_P4_DEPTH_CAPTURE_START directory=$dest seed=20261119 warmup_frames=$WarmupFrames headings=8"
    # GUI-subsystem Godot does not reliably set LASTEXITCODE in PowerShell 5.1.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $godot
    $psi.WorkingDirectory = $root
    $psi.Arguments = '--path ".\godot" --script res://tests/a8_p4_depth_capture.gd'
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    if ($null -eq $proc) { throw 'A8_P4_GODOT_PROCESS_START_FAILED' }
    try {
        if (-not $proc.WaitForExit(180000)) {
            $proc.Kill()
            $proc.WaitForExit()
            throw 'A8_P4_GODOT_WATCHDOG_180S'
        }
        $exitCode = $proc.ExitCode
    } finally {
        $proc.Dispose()
    }
    if ($exitCode -ne 0) { throw "A8_P4_GODOT_CAPTURE_FAILED code=$exitCode" }
    & python $reporter $dest
    $validatorExit = $LASTEXITCODE
    if ($validatorExit -ne 0) { throw "A8_P4_FAIL_CLOSED_REVIEW_FAILED code=$validatorExit" }
    $provenance.state = 'CAPTURE_AND_REVIEW_VALID'
    $provenance.godot_exit_code = $exitCode
    $provenance.report_exit_code = $validatorExit
    $provenance.completed_utc = (Get-Date).ToUniversalTime().ToString('o')
    $provenance | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifest -Encoding UTF8
} catch {
    $failure = $_.Exception.Message
    $failureObj = @{
        schema='a8_p4_pilot_error_v1'
        message=$failure
        godot_exit_code=$exitCode
        validator_exit_code=$validatorExit
        strict_gates='NOT_QUALIFIED'
    }
    $failureObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dest 'a8_p4_pilot_error.json') -Encoding UTF8
} finally {
    $env:A8_P4_OUTPUT_DIR = $oldOutput
    $env:A3_SAVE_PATH = $oldSave
}
$zip = Join-Path $dest 'a8_p4_depth_evidence.zip'
$evidence = @(Get-ChildItem -LiteralPath $dest -File | Where-Object { $_.Extension -in @('.json','.png') })
if ($evidence.Count -gt 0) {
    $filePaths = @($evidence | ForEach-Object { $_.FullName })
    Compress-Archive -LiteralPath $filePaths -DestinationPath $zip -CompressionLevel Fastest -Force
}
if ($null -ne $failure) {
    Write-Host "A8_P4_DIAGNOSTIC_FAILED reason=$failure evidence=$zip"
    throw $failure
}
Write-Host "A8_P4_DEPTH_CAPTURE_COMPLETE calibrated=TRUE headings=8 strict=NOT_QUALIFIED zip=$zip"
