$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = Join-Path $root '.tools/godot.exe'
$project = Join-Path $root 'godot'
if (-not (Test-Path $exe)) { throw 'Missing pinned Godot; use scripts/bootstrap-windows.ps1 -RuntimeOnly' }
if (-not (Test-Path (Join-Path $project 'bin/sandbox_native.windows.template_debug.x86_64.dll'))) {
    throw 'Missing native A3 DLL; restore the A3 artifact or build via bootstrap-windows.ps1 -SkipDownload'
}
$cache = Join-Path $project '.godot'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $cache 'extension_list.cfg'),
    "res://sandbox_native.gdextension" + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($false))
)
$reports = Join-Path $root 'reports/generated/a5-ci'
if (Test-Path $reports) { Remove-Item -LiteralPath $reports -Force -Recurse }
New-Item -ItemType Directory -Path $reports -Force | Out-Null
$env:A3_SAVE_PATH = Join-Path $reports 'a5_world.sqlite'
$env:A4_ROCK_STATE_PATH = Join-Path $reports 'a5_rocks.json'
$env:A5_RESULTS_DIR = $reports
$quoted = '"' + $project + '"'
function Invoke-Test([string] $script, [string[]] $arguments) {
    $opts = @('--headless', '--path', $quoted, '--script', $script, '--') + $arguments
    $process = Start-Process -FilePath $exe -ArgumentList $opts -Wait -PassThru -NoNewWindow
    if ($process.ExitCode -ne 0) { throw "A5_SMOKE_FAIL script=$script args=$($arguments -join ',') exit=$($process.ExitCode)" }
}
Invoke-Test 'res://tests/a5_water_physics.gd' @('--a4-standalone-physics')
Invoke-Test 'res://tests/a5_shoreline.gd' @('--phase=write')
Invoke-Test 'res://tests/a5_shoreline.gd' @('--phase=reopen')
$phys = Get-Content -LiteralPath (Join-Path $reports 'a5_physics.json') -Raw | ConvertFrom-Json
$write = Get-Content -LiteralPath (Join-Path $reports 'a5_shore_write.json') -Raw | ConvertFrom-Json
$reopen = Get-Content -LiteralPath (Join-Path $reports 'a5_shore_reopen.json') -Raw | ConvertFrom-Json
if ($phys.heavy_rock_y -ge -4 -or $phys.light_body_y -le -1 -or $phys.current_drift_x -le 0.5 -or
    $write.probe_sdf -le 0.2 -or $reopen.probe_sdf -le 0.2 -or
    $write.surface_y -ne 0 -or $reopen.surface_y -ne 0 -or
    $write.visual_shoreline_gate -ne 'NOT_QUALIFIED') { throw 'A5_REPORT_FAIL: physical and shoreline invariants' }
Write-Host "A5_HEADLESS_E2E_PASS heavy_y=$($phys.heavy_rock_y) float_y=$($phys.light_body_y) current_x=$($phys.current_drift_x) shore_sdf=$($reopen.probe_sdf)"
