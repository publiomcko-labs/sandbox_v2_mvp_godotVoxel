param(
    [ValidateSet('turns_18mps_300s','straight_18mps_600s','out_and_back_18mps_300s')]
    [string] $Scenario = 'turns_18mps_300s',
    [ValidateRange(20,60)] [int] $Duration = 30
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$old = Join-Path $PSScriptRoot 'a7-record-evidence-windows.ps1'
$timelineTool = Join-Path $PSScriptRoot 'a7_video_timeline.py'
$audit = Join-Path $PSScriptRoot 'a8_visual_audit.py'
if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'A8_VISUAL_INTERACTIVE_DESKTOP_REQUIRED'
}
$location = Join-Path $root 'reports/generated/a7-visual-evidence'
New-Item -ItemType Directory -Path $location -Force | Out-Null
$prior = @{}
foreach ($d in @(Get-ChildItem -LiteralPath $location -Directory)) {
    $prior[$d.FullName] = $true
}
Write-Host "A8_VISUAL_GPU_START scenario=$Scenario duration=$Duration warmup_drawn_frames=1000 recorder=DDAGrab_NVENC"
# Not a frame-performance comparison. Recorder starts before warmup; the route
# attests the full 1000 drawn frames in the isolated game report.
& $old -Mode Route -Scenario $Scenario -Duration $Duration -Warmup 0 -WarmupFrames 1000 -A8VisualEvidence -RecorderMode ddagrab_nvenc
if (-not $?) { throw 'A8_VISUAL_EXISTING_RECORDER_FAILED' }
$new = @(Get-ChildItem -LiteralPath $location -Directory | Where-Object {
    -not $prior.ContainsKey($_.FullName)
})
if ($new.Count -ne 1) {
    throw "A8_VISUAL_CAMPAIGN_DISCOVERY_AMBIGUOUS new=$($new.Count)"
}
$folder = $new[0].FullName
$manifest = Get-Content -LiteralPath (Join-Path $folder 'visual_evidence_manifest.json') -Raw | ConvertFrom-Json
if ($manifest.a8_visual_evidence_requested -ne $true -or
    $manifest.warmup_frames_requested -ne 1000 -or
    $manifest.scenario -ne $Scenario -or
    $manifest.game_run_succeeded -ne $true -or
    $manifest.video_capture_valid_container -ne $true) {
    throw 'A8_VISUAL_RECORDER_PROVENANCE_INVALID'
}
$probe = [string]$manifest.ffprobe_path
$ff = Join-Path (Split-Path -Parent $probe) 'ffmpeg.exe'
if (-not (Test-Path -LiteralPath $probe) -or -not (Test-Path -LiteralPath $ff)) {
    throw 'A8_VISUAL_FFMPEG_FFPROBE_MISSING'
}
& python $timelineTool $folder --ffmpeg $ff --ffprobe $probe
if ($LASTEXITCODE -ne 0) { throw "A8_VISUAL_TIMELINE_INVALID exit=$LASTEXITCODE" }
& python $audit $folder
if ($LASTEXITCODE -ne 0) { throw "A8_VISUAL_AUDIT_INVALID exit=$LASTEXITCODE" }
$files = @(
    (Join-Path $folder 'desktop-1080p-60fps.mkv'),
    (Join-Path $folder 'visual_evidence_manifest.json'),
    (Join-Path $folder 'a7_video_timeline.json'),
    (Join-Path $folder 'a8_visual_review.json')
)
$routes = @(Get-ChildItem -LiteralPath (Join-Path $folder 'game') -Recurse -File -Filter 'a7_route.json*')
if ($routes.Count -ne 2) { throw "A8_VISUAL_ROUTE_FILES_INCOMPLETE $($routes.Count)" }
$files += @($routes | ForEach-Object { $_.FullName })
$games = @(Get-ChildItem -LiteralPath (Join-Path $folder 'game') -File -Filter 'manifest.json')
if ($games.Count -ne 1) { throw 'A8_VISUAL_GAME_MANIFEST_MISSING' }
$files += $games[0].FullName
foreach ($file in $files) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
        throw "A8_VISUAL_REQUIRED_FILE_MISSING $file"
    }
}
$zip = Join-Path $folder 'a8_visual_evidence.zip'
if (Test-Path -LiteralPath $zip) { throw 'A8_VISUAL_ZIP_COLLISION' }
# Video is compressed already; fastest avoids wasted recompression effort.
Compress-Archive -LiteralPath $files -DestinationPath $zip -CompressionLevel Fastest
Write-Host "A8_VISUAL_EVIDENCE_READY=TRUE strict=NOT_QUALIFIED zip=$zip"
Write-Host 'A8_VISUAL_NOTE: video/clock is evidence only, not 130m depth or 60FPS qualification'
