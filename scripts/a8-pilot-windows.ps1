param(
    [ValidateSet('straight_18mps_600s','turns_18mps_300s','out_and_back_18mps_300s')]
    [string] $Scenario = 'straight_18mps_600s',
    [ValidateRange(10,90)] [int] $Duration = 30,
    [ValidateRange(100,10000)] [int] $WarmupFrames = 1000,
    [int] $Seed = 20261119,
    [switch] $SpikeTrace
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$a7 = Join-Path $PSScriptRoot 'a7-run-windows.ps1'
$reporter = Join-Path $PSScriptRoot 'a8_route_triage.py'
if (-not (Test-Path -LiteralPath $a7) -or -not (Test-Path -LiteralPath $reporter)) {
    throw 'A8_DIAGNOSTIC_SCRIPTS_MISSING'
}
if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'A8_REAL_GPU_INTERACTIVE_SESSION_REQUIRED'
}
$folder = Join-Path $root ('reports/generated/a8/pilot-' +
    (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID")
if (Test-Path -LiteralPath $folder) { throw 'A8_OUTPUT_COLLISION' }
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$oldCampaign = $env:A7_CAMPAIGN_DIR
try {
    $env:A7_CAMPAIGN_DIR = $folder
    Write-Host "A8_GPU_ROUTE_START route=$Scenario warmup_drawn_frames=$WarmupFrames duration_s=$Duration seed=$Seed"
    # Reuse the A7 runner, its identical per-frame sampling and its isolated
    # A5 CPU16 world. This is one diagnostic GPU run, not the A7 Full campaign.
    # Capture/ETW are deliberately OFF: they change the rendering workload.
    if ($SpikeTrace -and $WarmupFrames -ne 1000) {
        throw 'A8_SPIKE_TRACE_REQUIRES_EXACTLY_1000_FRAMES'
    }
    & $a7 -Scenario $Scenario -Seeds @($Seed) -Duration $Duration -Warmup 0 -WarmupFrames $WarmupFrames -A8SpikeTrace:$SpikeTrace
    if (-not $?) { throw 'A8_A7_ROUTE_RUNNER_FAILED' }
    & python $reporter $folder
    if ($LASTEXITCODE -ne 0) { throw "A8_TRIAGE_FAILED exit=$LASTEXITCODE" }
} finally {
    $env:A7_CAMPAIGN_DIR = $oldCampaign
}
# Small upload contains diagnostics, not a recording of a user's desktop.
$upload = Join-Path $folder 'upload-summary'
New-Item -ItemType Directory -Path $upload -Force | Out-Null
foreach ($name in @('manifest.json','a7_acceptance_matrix.json','A7_REPORT.md','a8_triage.json')) {
    $source = Join-Path $folder $name
    if (Test-Path -LiteralPath $source) {
        Copy-Item -LiteralPath $source -Destination $upload -Force
    }
}
$routeFolder = Get-ChildItem -LiteralPath $folder -Directory |
    Where-Object { $_.Name -like ($Scenario + '_seed*') } |
    Select-Object -First 1
if ($null -eq $routeFolder) { throw 'A8_ROUTE_REPORT_FOLDER_MISSING' }
$expectedEvidence = @('a7_route.json','a7_route.jsonl')
if ($SpikeTrace) { $expectedEvidence += 'a8_frame_spikes.json' }
foreach ($name in $expectedEvidence) {
    $source = Join-Path $routeFolder.FullName $name
    if (-not (Test-Path -LiteralPath $source)) { throw "A8_ROUTE_EVIDENCE_MISSING $name" }
    Copy-Item -LiteralPath $source -Destination $upload -Force
}
$zip = Join-Path $folder 'a8_pilot_summary.zip'
Compress-Archive -Path (Join-Path $upload '*') -DestinationPath $zip -Force
Write-Host "A8_PILOT_OK strict=NOT_QUALIFIED zip=$zip"
