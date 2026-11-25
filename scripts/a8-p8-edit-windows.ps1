param([string]$PresentMonExe='', [switch]$Depth, [switch]$Precision, [switch]$Semantic)
$ErrorActionPreference='Stop'
if ($Semantic) { $Precision=$true }
if ($Precision) { $Depth=$true }
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($env:COMPUTERNAME -ne 'DESKTOP-SAFGO15' -or -not (@(Get-CimInstance Win32_VideoController | ForEach-Object Name) -contains 'NVIDIA GeForce GTX 1050 Ti')) { throw 'A8_P8_WRONG_GPU_HOST' }
$b=& git -C $root branch --show-current
if ($LASTEXITCODE -ne 0 -or $b -eq 'main' -or $b -eq 'master') { throw 'A8_P8_INVALID_REF' }
if (-not $PresentMonExe) { $PresentMonExe=Join-Path $root 'PresentMon.exe' }
if (-not (Test-Path -LiteralPath $PresentMonExe)) { throw 'A8_P8_PRESENTMON_MISSING: provide -PresentMonExe' }
$base=Join-Path $root 'reports/generated/a7-visual-evidence'
$before=@()
if (Test-Path $base) { $before=@(Get-ChildItem -LiteralPath $base -Directory | ForEach-Object FullName) }
$failure=$null
try {
    & (Join-Path $PSScriptRoot 'a7-record-evidence-windows.ps1') -Mode Edit -Scenario edit_idle_100 -Seed 20261119 -Warmup 0 -WarmupFrames 1000 -A8P8Edit -A8P81Depth:$Depth -A8P82Precision:$Precision -A8P83Semantic:$Semantic -PresentMonExe $PresentMonExe
} catch { $failure=$_.Exception.Message }
if (-not (Test-Path $base)) { throw "A8_P8_NO_EVIDENCE $failure" }
$created=@(Get-ChildItem -LiteralPath $base -Directory | Where-Object { $before -notcontains $_.FullName })
if ($created.Count -ne 1) { throw "A8_P8_EXPECTED_ONE_NEW_CAMPAIGN $failure" }
$campaign=$created[0].FullName
if (-not $failure) {
    $ff=Join-Path $root 'reports/tools/a7-ffmpeg-7.1.1/ffmpeg-7.1.1-essentials_build/bin/ffmpeg.exe'
    $fp=Join-Path (Split-Path -Parent $ff) 'ffprobe.exe'
    $reporter = if ($Semantic) { 'a8_p83_semantic_report.py' } elseif ($Precision) { 'a8_p82_depth_report.py' } elseif ($Depth) { 'a8_p81_depth_report.py' } else { 'a8_p8_edit_report.py' }
    & python (Join-Path $PSScriptRoot $reporter) $campaign --ffmpeg $ff --ffprobe $fp
    if ($LASTEXITCODE -ne 0) { $failure='A8_P8_OFFLINE_REPORT_FAILED' }
}
if ($failure) { $failure | Set-Content -LiteralPath (Join-Path $campaign 'a8_p8_error.txt') -Encoding UTF8 }
$zip=$campaign+'.zip'
Compress-Archive -Path (Join-Path $campaign '*') -DestinationPath $zip -CompressionLevel Fastest
$archiveName = if ($Semantic) { 'a8_p83_semantic_evidence.zip' } elseif ($Precision) { 'a8_p82_depth_evidence.zip' } elseif ($Depth) { 'a8_p81_depth_evidence.zip' } else { 'a8_p8_edit_evidence.zip' }
$final=Join-Path $campaign $archiveName
Move-Item -LiteralPath $zip -Destination $final
Write-Host "A8_P8_EVIDENCE=$final"
if ($failure) { throw $failure }
Write-Host 'A8_P8_DIAGNOSTIC_COMPLETE EDIT_100=NOT_QUALIFIED'
