$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$editor = Join-Path $root '.tools/godot.exe'
$project = Join-Path $root 'godot'
if (-not (Test-Path $editor)) { throw 'A4 missing pinned editor; run bootstrap-windows.ps1 -SkipDownload' }
if (-not (Test-Path (Join-Path $project 'bin/sandbox_native.windows.template_debug.x86_64.dll'))) {
    throw 'A4 missing A3 C++ DLL; use the compiled A3 checkout or bootstrap-windows.ps1'
}
$cache = Join-Path $project '.godot'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $cache 'extension_list.cfg'),
    "res://sandbox_native.gdextension" + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($false))
)
$reports = Join-Path $root 'reports/generated/a4-ci'
if (Test-Path $reports) { Remove-Item -LiteralPath $reports -Recurse -Force }
New-Item -ItemType Directory -Path $reports -Force | Out-Null
$env:A3_SAVE_PATH = Join-Path $reports 'world.sqlite'
$env:A4_ROCK_STATE_PATH = Join-Path $reports 'rocks.json'
$env:A4_RESULTS_DIR = $reports
$quoted = '"' + $project + '"'
function Invoke-Godot([string] $script, [string[]] $extra) {
    $argsList = @('--headless','--path',$quoted,'--script',$script,'--') + $extra
    $run = Start-Process -FilePath $editor -ArgumentList $argsList -PassThru -Wait -NoNewWindow
    if ($run.ExitCode -ne 0) { throw "A4_SMOKE_FAIL script=$script args=$($extra -join ',') code=$($run.ExitCode)" }
}
Invoke-Godot 'res://tests/a4_physics.gd' @('--a4-standalone-physics')
Invoke-Godot 'res://tests/a4_smoke.gd' @('--phase=write')
Invoke-Godot 'res://tests/a4_smoke.gd' @('--phase=reopen')
$write = Get-Content -LiteralPath (Join-Path $reports 'a4_write.json') -Raw | ConvertFrom-Json
$reopen = Get-Content -LiteralPath (Join-Path $reports 'a4_reopen.json') -Raw | ConvertFrom-Json
if ($write.promoted_count -le 0 -or $write.static_count_after -ge $write.static_count_before -or
    $write.active_count -gt 24 -or $reopen.promoted_count_reopened -ne $write.promoted_count -or
    $reopen.visual_130_gate -ne 'NOT_QUALIFIED' -or
    $write.headless_native_transform_gate -ne 'NOT_QUALIFIED') { throw 'A4_REPORT_FAIL: native promotion/persistence invariant' }
# A3 terrain/rock snapshots and native VoxelInstancer removals must be loaded
# from disk; the sidecar must not use stale in-memory process state.
if (-not (Test-Path $env:A3_SAVE_PATH) -or -not (Test-Path $env:A4_ROCK_STATE_PATH)) {
    throw 'A4_SAVE_FAIL: missing SQLite or rock sidecar'
}
Write-Host "A4_HEADLESS_WITH_LIMITATIONS_PASS before=$($write.static_count_before) after=$($write.static_count_after) controlled_bodies=$($write.promoted_count) native_transform=NOT_QUALIFIED"
