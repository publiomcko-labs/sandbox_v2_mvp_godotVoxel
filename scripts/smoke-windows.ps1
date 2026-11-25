$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$editor = Join-Path $root '.tools/godot.exe'
if (-not (Test-Path $editor)) { throw 'Run scripts/bootstrap-windows.ps1 first' }
if (-not (Test-Path (Join-Path $root 'godot/bin/sandbox_native.windows.template_debug.x86_64.dll'))) {
    throw 'Run scripts/bootstrap-windows.ps1 -Target template_debug first'
}
$godotProject = Join-Path $root 'godot'
# Godot 4.7.2 runtime loads registered extensions from this newline-delimited
# editor cache. Generate only for this smoke, not as a committed source file.
$cache = Join-Path $godotProject '.godot'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
$listPath = Join-Path $cache 'extension_list.cfg'
[System.IO.File]::WriteAllText($listPath, "res://sandbox_native.gdextension`n", (New-Object System.Text.UTF8Encoding($false)))
Write-Host "A0: registered GDExtension for runtime smoke: $listPath"
$quotedPath = '"' + $godotProject + '"'
# The previous hosted runner compiled successfully but exited 0xC0000005
# during editor import/shutdown. Execute the standalone runtime smoke first,
# so it tests the actual native API without editor teardown as a confounder.
Write-Host 'A0: standalone headless runtime smoke (editor import omitted)'
$smoke = Start-Process -FilePath $editor -ArgumentList @('--headless','--path',$quotedPath,'--script','res://tests/smoke.gd') -Wait -PassThru -NoNewWindow
if ($smoke.ExitCode -ne 0) { throw "A0_SMOKE_FAIL exit=$($smoke.ExitCode)" }
Write-Host 'A0_SMOKE_PASS'
