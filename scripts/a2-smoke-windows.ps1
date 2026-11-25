$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$godot = Join-Path $root '.tools/godot.exe'
$project = Join-Path $root 'godot'
if (-not (Test-Path $godot)) { throw 'Missing Godot executable' }
if (-not (Test-Path (Join-Path $project 'bin/sandbox_native.windows.template_debug.x86_64.dll'))) {
    throw 'Missing GDExtension'
}
$cache = Join-Path $project '.godot'
New-Item -ItemType Directory -Path $cache -Force | Out-Null
[System.IO.File]::WriteAllText(
    (Join-Path $cache 'extension_list.cfg'),
    "res://sandbox_native.gdextension" + [Environment]::NewLine,
    (New-Object System.Text.UTF8Encoding($false))
)
$quoted = '"' + $project + '"'
$paths = Start-Process -FilePath $godot -ArgumentList @(
    '--headless','--path',$quoted,'--script','res://tests/a2_smoke.gd'
) -Wait -PassThru -NoNewWindow
if ($paths.ExitCode -ne 0) { throw "A2_ROUTES_FAIL exit=$($paths.ExitCode)" }

# Ensure the smoke cannot inadvertently consume a previous ignored report.
$smokeDir = Join-Path $root 'reports/generated/a2-ci'
if (Test-Path $smokeDir) { Remove-Item -LiteralPath $smokeDir -Force -Recurse }
New-Item -ItemType Directory -Path $smokeDir -Force | Out-Null
$env:A2_OUTPUT_DIR = $smokeDir
$run = Start-Process -FilePath $godot -ArgumentList @(
    '--headless','--path',$quoted,'--script','res://tests/a2_benchmark.gd','--',
    '--route=out_and_back_18mps_300s','--duration=2.0','--warmup=0.2','--ci-smoke'
) -Wait -PassThru -NoNewWindow
if ($run.ExitCode -ne 0) { throw "A2_HEADLESS_TRACE_FAIL exit=$($run.ExitCode)" }
$files = @(Get-ChildItem -LiteralPath $smokeDir -Filter '*.json' -File)
if ($files.Count -ne 1) { throw "Expected exactly one A2 JSON summary; got $($files.Count)" }
$data = Get-Content -LiteralPath $files[0].FullName -Raw | ConvertFrom-Json
if ($data.route -ne 'out_and_back_18mps_300s' -or
    $data.frame_intervals_observed -le 0 -or
    $data.ci_smoke -ne $true -or
    $data.view_130_pixel_gate -ne 'NOT_QUALIFIED') {
    throw "Invalid A2 trace/qualification summary: $($files[0].FullName)"
}
Write-Host "A2_HEADLESS_E2E_PASS report=$($files[0].FullName) intervals=$($data.frame_intervals_observed)"
