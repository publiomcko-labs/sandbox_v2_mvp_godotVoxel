param(
    [ValidateSet('cold','warm')][string]$Profile = 'cold',
    [string]$OutputRoot = '',
    [string]$StateRoot = '',
    [switch]$HeadlessDiagnostic
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = Join-Path $root '.tools\godot.exe'
$project = Join-Path $root 'godot'
$dll = Join-Path $project 'bin\sandbox_native.windows.template_debug.x86_64.dll'
if (!(Test-Path -LiteralPath $exe) -or !(Test-Path -LiteralPath $dll)) {
    throw 'Godot/Voxel Tools or native DLL missing; restore approved binary with scripts/bootstrap-windows.ps1 -RuntimeOnly.'
}
if ((Get-Process -Id $PID).SessionId -eq 0 -and !$HeadlessDiagnostic) {
    throw 'Interactive comparison requires desktop Windows session, not Session 0 Actions service.'
}
if (!$OutputRoot) { $OutputRoot = Join-Path $root 'reports\comparison-v1' }
$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
$run = Join-Path $OutputRoot "godot-$Profile-$stamp"
New-Item -ItemType Directory -Force -Path $run | Out-Null
$runState = Join-Path $run 'world'
New-Item -ItemType Directory -Force -Path $runState | Out-Null
if ($Profile -eq 'warm') {
    if (!$StateRoot) { throw 'Warm profile requires -StateRoot from a previous cold run.' }
    if (!(Test-Path (Join-Path $StateRoot 'terrain.sqlite'))) { throw "Warm save missing: $StateRoot" }
    Copy-Item -Path (Join-Path $StateRoot '*') -Destination $runState -Recurse -Force
} elseif ($StateRoot) {
    throw 'Cold profile always creates a new isolated state. Omit -StateRoot.'
}
$env:A3_SAVE_PATH = Join-Path $runState 'terrain.sqlite'
$env:A4_ROCK_STATE_PATH = Join-Path $runState 'rocks.json'
$env:COMPARISON_V1_CSV = Join-Path $run 'frames.csv'
$env:COMPARISON_V1_NATIVE_JSON = Join-Path $run 'native.json'
$cache = Join-Path $project '.godot'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cache 'extension_list.cfg'), "res://sandbox_native.gdextension" + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
$args = @()
if ($HeadlessDiagnostic) { $args += '--headless' }
$args += @('--path', ('"' + $project + '"'), '--script', 'res://tests/comparison_v1.gd')
Write-Host "COMPARISON_V1_GODOT session=$run headless=$HeadlessDiagnostic"
$proc = Start-Process -FilePath $exe -ArgumentList $args -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) { throw "Comparison failed exit=$($proc.ExitCode)" }
$native = Get-Content -LiteralPath $env:COMPARISON_V1_NATIVE_JSON -Raw | ConvertFrom-Json
$gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) / $($_.DriverVersion)" })
$cpu = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$meta = [ordered]@{
    engine = 'godot_voxel_tools'
    scenario_id = 'survey46-six-edits-v1'
    render_mode = if ($HeadlessDiagnostic) { 'cpu_headless' } else { 'interactive' }
    profile = $Profile
    git_sha = (& git -C $root rev-parse HEAD).Trim()
    cpu = $cpu
    gpu = $gpu
    hostname = $env:COMPUTERNAME
    resolution = '1920x1080'
    backend = 'Godot GL Compatibility'
    run_id = (Split-Path $run -Leaf)
    functional_proxies = $native
}
$metadata = Join-Path $run 'metadata.json'
$meta | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $metadata -Encoding UTF8
$reducer = Join-Path $root 'scripts\comparison-v1-reduce.py'
$contract = Join-Path $root 'benchmarks\comparison-v1.json'
$result = Join-Path $run 'comparison-v1-result.json'
& python.exe $reducer --csv $env:COMPARISON_V1_CSV --contract $contract --metadata $metadata --out $result
if ($LASTEXITCODE -ne 0) { throw 'Comparison reducer rejected Godot data' }
Write-Host "COMPARISON_V1_DONE report=$run state=$runState"
