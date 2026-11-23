<#
A7 portable Windows FFmpeg bootstrap. Installs only inside the repository,
with no PATH, registry, winget, system installation, or display changes.
The archive SHA256 is pinned to the Microsoft winget-pkgs 7.1.1 manifest.
#>
param([switch] $Force)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$toolsDir=Join-Path $root 'reports/tools/a7-ffmpeg-7.1.1'
$zip=Join-Path $toolsDir 'ffmpeg-7.1.1-essentials_build.zip'
$binDir=Join-Path $toolsDir 'ffmpeg-7.1.1-essentials_build/bin'
$ff=Join-Path $binDir 'ffmpeg.exe'
$probe=Join-Path $binDir 'ffprobe.exe'
$sha='04861D3339C5EBE38B56C19A15CF2C0CC97F5DE4FA8910E4D47E5E6404E4A2D4'
$url='https://github.com/GyanD/codexffmpeg/releases/download/7.1.1/ffmpeg-7.1.1-essentials_build.zip'
if ((Test-Path -LiteralPath $ff -PathType Leaf) -and
    (Test-Path -LiteralPath $probe -PathType Leaf) -and -not $Force) {
    Write-Host "A7_FFMPEG_PORTABLE_READY=$ff"
    return
}
New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null
if (-not (Test-Path -LiteralPath $zip -PathType Leaf) -or $Force) {
    Write-Host 'A7_FFMPEG_DOWNLOADING_PORTABLE pinned=7.1.1 (one-time)'
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
}
$found=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
if ($found -ne $sha) { throw "A7_FFMPEG_SHA256_MISMATCH expected=$sha actual=$found" }
Write-Host "A7_FFMPEG_ARCHIVE_SHA256_OK=$found"
Expand-Archive -LiteralPath $zip -DestinationPath $toolsDir -Force
if (-not (Test-Path -LiteralPath $ff -PathType Leaf) -or
    -not (Test-Path -LiteralPath $probe -PathType Leaf)) {
    throw 'A7_FFMPEG_PORTABLE_BINARIES_MISSING_AFTER_EXTRACTION'
}
Write-Host "A7_FFMPEG_PORTABLE_READY=$ff"
