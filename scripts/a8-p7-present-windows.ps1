param(
    [string] $PresentMonExe = '',
    [switch] $SkipDownload
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$a7=Join-Path $PSScriptRoot 'a7-run-windows.ps1'
$guard=Join-Path $PSScriptRoot 'a7-etw-session-guard.ps1'
$reporter=Join-Path $PSScriptRoot 'a8_p7_present_report.py'
$sha='B2A706BC6AD475749E3B7E3409263AA1E6906D45BDCF993F6DBC0F660188F1AF'
$sourceUrl='https://github.com/GameTechDev/PresentMon/releases/download/v2.6.0/PresentMon-2.6.0-x64.exe'
if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'A8_P7_REQUIRES_INTERACTIVE_GPU_SESSION_NOT_SERVICE_SESSION_0'
}
Add-Type -AssemblyName System.Windows.Forms
$primary=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if ($primary.Width -lt 1920 -or $primary.Height -lt 1080) {
    throw 'A8_P7_PRIMARY_DISPLAY_BELOW_1920x1080'
}
$gpus=@(Get-CimInstance Win32_VideoController | ForEach-Object Name)
if ($env:COMPUTERNAME -ne 'DESKTOP-SAFGO15' -or -not ($gpus -contains 'NVIDIA GeForce GTX 1050 Ti')) {
    throw 'A8_P7_WRONG_GPU_HOST_OR_CARD'
}
$identity=[System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal=[System.Security.Principal.WindowsPrincipal]::new($identity)
$perfLogSid=[System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-559')
if (-not ($principal.IsInRole($perfLogSid) -or
          $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator))) {
    throw 'A8_P7_ETW_PERMISSION_REQUIRED: Performance Log Users and new Windows logon token needed; do not elevate runner or modify groups automatically'
}
if (-not $PresentMonExe) {
    foreach ($candidate in @((Join-Path $root 'PresentMon.exe'),
                             (Join-Path $root '.tools/PresentMon.exe'),
                             (Join-Path $root '.tools/a8-p7/PresentMon-2.6.0-x64.exe'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $PresentMonExe=$candidate;break
        }
    }
}
if (-not $PresentMonExe) {
    if ($SkipDownload) { throw 'A8_P7_PRESENTMON_MISSING_WITH_SKIPDOWNLOAD' }
    $store=Join-Path $root '.tools/a8-p7'
    New-Item -ItemType Directory -Force -Path $store | Out-Null
    $PresentMonExe=Join-Path $store 'PresentMon-2.6.0-x64.exe'
    Invoke-WebRequest -Uri $sourceUrl -OutFile $PresentMonExe -UseBasicParsing
}
if (-not (Test-Path -LiteralPath $PresentMonExe -PathType Leaf) -or
    (Get-FileHash -LiteralPath $PresentMonExe -Algorithm SHA256).Hash -ne $sha) {
    throw 'A8_P7_PRESENTMON_2_6_0_BINARY_HASH_MISMATCH'
}
$head=(& git -C $root rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0 -or $head.Length -ne 40) {
    throw 'A8_P7_GIT_SHA_NOT_VERIFIED'
}
# Explicitly forbid accidental execution on main/default branches.
$currentBranchOutput = & git -C $root branch --show-current
if ($LASTEXITCODE -ne 0) { throw 'A8_P7_GIT_BRANCH_QUERY_FAILED' }
$currentBranch = ([string]$currentBranchOutput).Trim()
if ($currentBranch -eq 'main' -or $currentBranch -eq 'master') {
    throw 'A8_P7_REFUSES_TO_BENCHMARK_OR_MODIFY_MAIN'
}
$pilot=Join-Path $root ('reports/generated/a8-p7/pilot-' +
    (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID")
if (Test-Path -LiteralPath $pilot) { throw 'A8_P7_FOLDER_COLLISION' }
New-Item -ItemType Directory -Force -Path $pilot | Out-Null
$prior=$env:A7_CAMPAIGN_DIR
$err=$null
try {
    & $guard -Mode Preflight -PresentMonExe $PresentMonExe
    $env:A7_CAMPAIGN_DIR=$pilot
    Write-Host "A8_P7_PILOT_START git=$head mode=VSync_ON warmup=1000_drawn duration=30s ETW=FULL gpu=1050Ti"
    $params=@{
        Scenario='turns_18mps_300s'
        Seeds=@(20261119)
        Duration=30
        Warmup=0
        WarmupFrames=1000
        ResourceTelemetry=$true
        PresentMonExe=$PresentMonExe
        A8P7Performance=$true
    }
    & $a7 @params
    if (-not $?) { throw 'A8_P7_GAME_RUN_FAILED' }
    & python $reporter $pilot
    if ($LASTEXITCODE -ne 0) { throw "A8_P7_REPORTER_FAILED exit=$LASTEXITCODE" }
    $r=Get-Content -LiteralPath (Join-Path $pilot 'a8_p7_present_report.json') -Raw | ConvertFrom-Json
    if ($r.presentmon_etw_status -ne 'ETW_ALIGNED' -or
        $null -eq $r.frame_presentation_cadence) {
        throw "A8_P7_ETW_NOT_ALIGNED status=$($r.presentmon_etw_status) reason=$($r.presentmon_etw_reason)"
    }
    Write-Host "A8_P7_REAL_ETW_CAPTURED gap_p99_ms=$($r.frame_presentation_cadence.p99_ms) gap_max_ms=$($r.frame_presentation_cadence.max_ms) over16_7=$($r.frame_presentation_cadence.over_16_7_ms)"
} catch {
    $err=$_.Exception.Message
    @{
        schema='a8_p7_failed_pilot_v1'; reason=$err
        git_sha=$head; strict_gates='NOT_QUALIFIED'
        original_etw_must_be_preserved=$true
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $pilot 'a8_p7_error.json') -Encoding UTF8
} finally {
    $env:A7_CAMPAIGN_DIR=$prior
    $statusFiles=@(Get-ChildItem -LiteralPath $pilot -Recurse -File -Filter 'a7_presentmon_status.json')
    foreach ($s in $statusFiles) {
        try {
            $pm=Get-Content -LiteralPath $s.FullName -Raw | ConvertFrom-Json
            if ($pm.etw_session_name) {
                & $guard -Mode Postflight -PresentMonExe $PresentMonExe -SessionName $pm.etw_session_name
            }
        } catch {
            Write-Warning "A8_P7_ETW_GUARD_POSTFLIGHT_ERROR $($_.Exception.Message)"
            if (-not $err) { $err='A8_P7_POSTFLIGHT_FAILED' }
        }
    }
    foreach ($csv in @(Get-ChildItem -LiteralPath $pilot -Recurse -File -Filter 'a7_presentmon.csv')) {
        Compress-Archive -LiteralPath $csv.FullName -DestinationPath ($csv.FullName+'.zip') -CompressionLevel Optimal
        Remove-Item -LiteralPath $csv.FullName -Force
    }
    $archiveTemp=$pilot+'.zip'
    if (Test-Path -LiteralPath $archiveTemp) { throw 'A8_P7_ARCHIVE_COLLISION' }
    Compress-Archive -Path (Join-Path $pilot '*') -DestinationPath $archiveTemp -CompressionLevel Fastest
    $finalZip=Join-Path $pilot 'a8_p7_performance_evidence.zip'
    Move-Item -LiteralPath $archiveTemp -Destination $finalZip
    Write-Host "A8_P7_DIAGNOSTIC_ARCHIVE=$finalZip"
}
if ($err) {
    Write-Host "A8_P7_PILOT_FAIL evidence=$finalZip reason=$err"
    throw $err
}
Write-Host "A8_P7_PILOT_VALID_ETW=TRUE strict=NOT_QUALIFIED evidence=$finalZip"
Write-Host "A8_P7_NOTE: no videos, 1000 drawn warmup frames, 30s single-seed pilot; no automatic optimization or gate promotion"
