param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Windows.Forms
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$recorder = Join-Path $PSScriptRoot 'a7-record-evidence-windows.ps1'
$timeline = Join-Path $PSScriptRoot 'a7_video_timeline.py'
$reviewer = Join-Path $PSScriptRoot 'a8_p5_dynamic_depth_review.py'
$location = Join-Path $root 'reports/generated/a7-visual-evidence'
$pilot = Join-Path $root ('reports/generated/a8-p5/pilot-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID")
if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) { throw 'A8_P5_REQUIRES_INTERACTIVE_GPU_DESKTOP' }
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if ($screen.X -ne 0 -or $screen.Y -ne 0 -or $screen.Width -lt 1920 -or $screen.Height -lt 1080) {
    throw 'A8_P5_REQUIRES_PRIMARY_1920x1080_AT_ORIGIN'
}
if (Test-Path -LiteralPath $pilot) { throw 'A8_P5_CAMPAIGN_COLLISION' }
New-Item -ItemType Directory -Force -Path $pilot | Out-Null
New-Item -ItemType Directory -Force -Path $location | Out-Null
$failure = $null
$head = (& git -C $root rev-parse HEAD).Trim()
try {
    if ($LASTEXITCODE -ne 0 -or $head.Length -ne 40) { throw 'A8_P5_REPO_SHA_MISSING' }
    foreach ($arm in @('rgb','depth')) {
        $prior = @{}
        foreach ($d in @(Get-ChildItem -LiteralPath $location -Directory)) { $prior[$d.FullName] = $true }
        Write-Host "A8_P5_VIDEO_START arm=$arm warmup=1000 duration=30 seed=20261119"
        $recordError = $null
        try {
            & $recorder -Mode Route -Scenario 'turns_18mps_300s' -Seed 20261119 -Warmup 0 -WarmupFrames 1000 -Duration 30 -A8VisualEvidence -A8P5DepthVideo:($arm -eq 'depth') -RecorderMode 'ddagrab_nvenc'
            if (-not $?) { throw "A8_P5_RECORDER_RETURNED_FAILURE arm=$arm" }
        } catch { $recordError = $_.Exception.Message }
        $fresh = @(Get-ChildItem -LiteralPath $location -Directory | Where-Object { -not $prior.ContainsKey($_.FullName) })
        if ($fresh.Count -ne 1) {
            throw "A8_P5_CAMPAIGN_DISCOVERY_FAILED arm=$arm count=$($fresh.Count) error=$recordError"
        }
        $src = $fresh[0].FullName
        $target = Join-Path $pilot $arm
        $trial = Join-Path $target 'game/turns_18mps_300s_seed20261119_rep01'
        New-Item -ItemType Directory -Force -Path $trial | Out-Null
        foreach ($file in @('desktop-1080p-60fps.mkv','visual_evidence_manifest.json')) {
            $origin = Join-Path $src $file
            if (Test-Path -LiteralPath $origin) { Copy-Item -LiteralPath $origin -Destination (Join-Path $target $file) }
        }
        $gameManifest = Join-Path $src 'game/manifest.json'
        if (Test-Path -LiteralPath $gameManifest) {
            Copy-Item -LiteralPath $gameManifest -Destination (Join-Path $target 'game/manifest.json')
        }
        $runs = @(Get-ChildItem -LiteralPath (Join-Path $src 'game') -Recurse -File -Filter 'a7_route.json*' -ErrorAction SilentlyContinue)
        foreach ($file in $runs) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $trial $file.Name) }
        if ($null -ne $recordError) { throw "A8_P5_RECORDER_FAILED arm=$arm error=$recordError" }
        $m = Get-Content -LiteralPath (Join-Path $target 'visual_evidence_manifest.json') -Raw | ConvertFrom-Json
        if ($m.git_sha -ne $head -or $m.a8_p5_depth_video_requested -ne ($arm -eq 'depth') -or $m.video_capture_valid_container -ne $true) {
            throw "A8_P5_ARM_PROVENANCE_FAILED arm=$arm"
        }
        $probe = [string]$m.ffprobe_path
        $ffmpeg = Join-Path (Split-Path -Parent $probe) 'ffmpeg.exe'
        if (-not (Test-Path -LiteralPath $ffmpeg -PathType Leaf) -or -not (Test-Path -LiteralPath $probe -PathType Leaf)) {
            throw "A8_P5_FFMPEG_MISSING arm=$arm"
        }
        & python $timeline $target --ffmpeg $ffmpeg --ffprobe $probe
        if ($LASTEXITCODE -ne 0) { throw "A8_P5_TIMELINE_FAILED arm=$arm exit=$LASTEXITCODE" }
        Write-Host "A8_P5_VIDEO_RECORDED arm=$arm bytes=$($m.video_bytes)"
    }
    & python $reviewer $pilot --ffmpeg $ffmpeg
    if ($LASTEXITCODE -ne 0) { throw "A8_P5_DEPTH_REVIEW_FAILED exit=$LASTEXITCODE" }
    @{
        schema='a8_p5_local_pilot_v1'; git_sha=$head
        baseline='A5_CPU16_GL_COMPATIBILITY'
        seed=20261119; route='turns_18mps_300s'
        duration_s=30; target_speed_mps=18; warmup_frames_each_arm=1000
        video_arms=@('rgb','depth'); depth_calibration_m=@(25,165)
        result='CAPTURED_AND_SAMPLED_REVIEW_PREPARED'
        performance_is_comparable=$false; strict_gates='NOT_QUALIFIED'
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $pilot 'a8_p5_manifest.json') -Encoding UTF8
} catch {
    $failure = $_.Exception.Message
    @{
        schema='a8_p5_failure_v1'; reason=$failure
        baseline='A5_CPU16_GL_COMPATIBILITY'; strict_gates='NOT_QUALIFIED'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $pilot 'a8_p5_error.json') -Encoding UTF8
}
$zip = Join-Path $pilot 'a8_p5_dynamic_depth_evidence.zip'
$inputs = @()
foreach ($name in @('rgb','depth','a8_p5_manifest.json','a8_p5_review.json','a8_p5_error.json')) {
    $candidate = Join-Path $pilot $name
    if (Test-Path -LiteralPath $candidate) { $inputs += $candidate }
}
if ($inputs.Count -gt 0) { Compress-Archive -LiteralPath $inputs -DestinationPath $zip -CompressionLevel Fastest }
if ($null -ne $failure) {
    Write-Host "A8_P5_FAILED reason=$failure evidence=$zip"
    throw $failure
}
Write-Host "A8_P5_DEPTH_EVIDENCE_READY=TRUE strict=NOT_QUALIFIED zip=$zip"
