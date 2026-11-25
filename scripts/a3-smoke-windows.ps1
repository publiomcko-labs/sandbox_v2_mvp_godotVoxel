$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$editor = Join-Path $root '.tools/godot.exe'
$project = Join-Path $root 'godot'
if (-not (Test-Path $editor)) { throw 'A3 requires pinned custom Godot; run bootstrap-windows.ps1' }
if (-not (Test-Path (Join-Path $project 'bin/sandbox_native.windows.template_debug.x86_64.dll'))) {
    throw 'A3 requires newly compiled C++ GDExtension; run bootstrap-windows.ps1'
}
$cache = Join-Path $project '.godot'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $cache 'extension_list.cfg'),
    "res://sandbox_native.gdextension" + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($false))
)
$results = Join-Path $root 'reports/generated/a3-ci'
if (Test-Path $results) { Remove-Item -LiteralPath $results -Force -Recurse }
New-Item -ItemType Directory -Path $results -Force | Out-Null
$env:A3_RESULTS_DIR = $results
$env:A3_SAVE_PATH = Join-Path $results 'a3_world.sqlite'
$quoted = '"' + $project + '"'
foreach ($phase in @('write','reopen')) {
    Write-Host "A3 executing separate Godot process: $phase"
    $run = Start-Process -FilePath $editor -ArgumentList @(
        '--headless', '--path', $quoted, '--script',
        'res://tests/a3_persistence.gd', '--', "--phase=$phase"
    ) -Wait -PassThru -NoNewWindow
    if ($run.ExitCode -ne 0) { throw "A3 smoke $phase failed, exit=$($run.ExitCode)" }
    $report = Join-Path $results "a3_$phase.json"
    if (-not (Test-Path $report)) { throw "A3 missing $phase JSON report" }
    $record = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
    if ($record.phase -ne $phase -or $record.removed_center_sdf -le 0.2 -or
        $record.added_boundary_sdf -ge -0.2 -or $record.visual_gate -ne 'NOT_QUALIFIED') {
        throw "A3 invalid $phase result"
    }
}
if (-not (Test-Path $env:A3_SAVE_PATH)) { throw 'A3 missing SQLite after reopen' }
Write-Host 'A3_SQLITE_REOPEN_E2E_PASS'
