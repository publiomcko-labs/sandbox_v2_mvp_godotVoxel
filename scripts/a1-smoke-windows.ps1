$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$godot = Join-Path $root '.tools/godot.exe'
$project = Join-Path $root 'godot'
if (-not (Test-Path $godot)) { throw 'Run scripts/bootstrap-windows.ps1 first' }
if (-not (Test-Path (Join-Path $root 'godot/bin/sandbox_native.windows.template_debug.x86_64.dll'))) {
    throw 'Run scripts/bootstrap-windows.ps1 -Target template_debug first'
}
$cache = Join-Path $project '.godot'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $cache 'extension_list.cfg'),
    "res://sandbox_native.gdextension" + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($false))
)
$quoted = '"' + $project + '"'
$run = Start-Process -FilePath $godot -ArgumentList @(
    '--headless', '--path', $quoted, '--script', 'res://tests/a1_smoke.gd'
) -Wait -PassThru -NoNewWindow
if ($run.ExitCode -ne 0) { throw "A1_SMOKE_FAIL exit=$($run.ExitCode)" }
Write-Host 'A1_SMOKE_PASS'
