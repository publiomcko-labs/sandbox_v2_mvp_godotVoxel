param(
    [ValidateSet('stationary_180s','straight_18mps_600s','turns_18mps_300s','out_and_back_18mps_300s')]
    [string] $Route = 'out_and_back_18mps_300s',
    [double] $Duration = -1,
    [double] $Warmup = 45,
    [switch] $Capture,
    [switch] $Headless,
    [switch] $CiSmoke
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = Join-Path $root '.tools/godot.exe'
$project = Join-Path $root 'godot'
if (-not (Test-Path $exe)) { throw 'Missing Godot editor; execute bootstrap-windows.ps1' }
if (-not (Test-Path (Join-Path $project 'bin/sandbox_native.windows.template_debug.x86_64.dll'))) {
    throw 'Missing native DLL; execute bootstrap-windows.ps1'
}
$cache = Join-Path $project '.godot'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $cache 'extension_list.cfg'),
    "res://sandbox_native.gdextension" + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($false))
)
if (-not $env:A2_OUTPUT_DIR) {
    $env:A2_OUTPUT_DIR = Join-Path $root 'reports/generated'
}
$nominal = switch ($Route) {
    'stationary_180s' { 180 }
    'straight_18mps_600s' { 600 }
    'turns_18mps_300s' { 300 }
    'out_and_back_18mps_300s' { 300 }
}
if ($Duration -le 0) { $Duration = $nominal }
if ($Duration -gt $nominal -or $Warmup -lt 0 -or $Warmup -gt 180) {
    throw 'Invalid A2 duration/warmup'
}
$quoted = '"' + $project + '"'
$arguments = @()
if ($Headless) { $arguments += '--headless' }
$arguments += @('--path', $quoted, '--script', 'res://tests/a2_benchmark.gd', '--',
                "--route=$Route", "--duration=$Duration", "--warmup=$Warmup")
if ($Capture) { $arguments += '--capture' }
if ($CiSmoke) { $arguments += '--ci-smoke' }
Write-Host "A2: route=$Route duration=$Duration warmup=$Warmup output=$env:A2_OUTPUT_DIR"
$run = Start-Process -FilePath $exe -ArgumentList $arguments -Wait -PassThru -NoNewWindow
if ($run.ExitCode -ne 0) { throw "A2_BENCH_FAIL exit=$($run.ExitCode)" }
Write-Host 'A2_BENCH_DONE (metrics recorded; no pixel/GPU qualification claimed)'
