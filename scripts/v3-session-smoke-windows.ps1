$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$editor=Join-Path $root '.tools/godot.exe'
$project=Join-Path $root 'godot'
if (-not (Test-Path $editor)) { throw 'Pinned custom Godot missing' }
$cache=Join-Path $project '.godot'
New-Item -ItemType Directory -Force $cache | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cache 'extension_list.cfg'), ("res://sandbox_native.gdextension" + [Environment]::NewLine), (New-Object System.Text.UTF8Encoding($false)))
$results=Join-Path $root "reports/generated/v3-session-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Force $results | Out-Null
$env:V3_TEST_WORLD_ROOT=Join-Path $results 'worlds'
$env:V3_TEST_EXTERNAL_MODS=Join-Path $root 'examples/v3/mods'
New-Item -ItemType Directory -Force $env:V3_TEST_WORLD_ROOT | Out-Null
foreach ($phase in @('write','reopen')) {
    $stdout=Join-Path $results "$phase.stdout.log"
    $stderr=Join-Path $results "$phase.stderr.log"
    $p=Start-Process -FilePath $editor -ArgumentList @('--headless','--path',('"'+$project+'"'),'--script','res://tests/v3_session_smoke.gd','--',"--phase=$phase") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow
    $null=$p.Handle
    if (-not $p.WaitForExit(180000)) { $p.Kill(); $p.WaitForExit(); throw "V3 fixture $phase timed out" }
    $p.WaitForExit()
    Get-Content $stdout
    Get-Content $stderr
    if ($null -eq $p.ExitCode -or $p.ExitCode -ne 0 -or -not (Select-String -LiteralPath $stdout -SimpleMatch "V3_SESSION_$($phase.ToUpper())_PASS")) {
        throw "V3 session $phase failed exit=$($p.ExitCode)"
    }
}
$world=Join-Path $env:V3_TEST_WORLD_ROOT 'fixture'
$checkpoint=Get-Content (Join-Path $world 'checkpoint.json') -Raw | ConvertFrom-Json
if ($checkpoint.generation -ne 2 -or $checkpoint.core.terrain_revision -ne 2 -or $checkpoint.pins.Count -ne 3 -or (Test-Path (Join-Path $world 'session_pending'))) {
    throw 'V3 clean checkpoint contract failed'
}
Write-Host 'V3_SESSION_SQLITE_REOPEN_PASS (headless; no graphical qualification)'

# Exercise actual opt-in runtime rather than only direct session bindings.
$env:V3_WORLD_ROOT=Join-Path $results 'runtime-worlds'
$env:V3_MOD_ROOT=$env:V3_TEST_EXTERNAL_MODS
$env:V3_WORLD_ID='runtime_fixture'
$env:V3_WORLD_SEED='20261119'
New-Item -ItemType Directory -Force $env:V3_WORLD_ROOT | Out-Null
foreach ($phase in @('write','reopen')) {
    $stdout=Join-Path $results "runtime-$phase.stdout.log"
    $stderr=Join-Path $results "runtime-$phase.stderr.log"
    $p=Start-Process -FilePath $editor -ArgumentList @('--headless','--path',('"'+$project+'"'),'--script','res://tests/v3_runtime_smoke.gd','--',"--phase=$phase") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow
    $null=$p.Handle
    if (-not $p.WaitForExit(180000)) { $p.Kill(); $p.WaitForExit(); throw "V3 runtime fixture $phase timed out" }
    $p.WaitForExit()
    Get-Content $stdout
    Get-Content $stderr
    if ($null -eq $p.ExitCode -or $p.ExitCode -ne 0 -or
        -not (Select-String -LiteralPath $stdout -SimpleMatch "V3_RUNTIME_FIXTURE_PASS phase=$phase") -or
        -not (Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS')) {
        throw "V3 runtime $phase failed exit=$($p.ExitCode)"
    }
}
$runtimeWorld=Join-Path $env:V3_WORLD_ROOT 'runtime_fixture'
$checkpoint=Get-Content (Join-Path $runtimeWorld 'checkpoint.json') -Raw | ConvertFrom-Json
if ($checkpoint.generation -ne 2 -or $checkpoint.core.terrain_revision -ne 2 -or $checkpoint.pins.Count -ne 3 -or (Test-Path (Join-Path $runtimeWorld 'session_pending'))) {
    throw 'V3 runtime clean checkpoint failed'
}
Write-Host 'V3_RUNTIME_E2E_PASS (headless)'

# V3.2 has its own schema/format and cannot reuse a V3.1 SQLite world.
$env:V3_WORLD_ROOT=Join-Path $results 'geology-worlds'
$env:V3_WORLD_ID='geology_fixture'
$env:V3_GEOLOGY_PROFILE='earth:temperate'
New-Item -ItemType Directory -Force $env:V3_WORLD_ROOT | Out-Null
foreach ($phase in @('write','reopen')) {
    $stdout=Join-Path $results "geology-$phase.stdout.log"
    $stderr=Join-Path $results "geology-$phase.stderr.log"
    $p=Start-Process -FilePath $editor -ArgumentList @('--headless','--path',('"'+$project+'"'),'--script','res://tests/v3_geology_smoke.gd','--',"--phase=$phase") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow
    $null=$p.Handle
    if (-not $p.WaitForExit(180000)) { $p.Kill(); $p.WaitForExit(); throw "V3 geology fixture $phase timed out" }
    $p.WaitForExit()
    Get-Content $stdout
    Get-Content $stderr
    if (Select-String -LiteralPath @($stdout,$stderr) -Pattern 'SHADER ERROR:|Shader compilation failed|SCRIPT ERROR:') {
        throw "V3 geology $phase contains shader or script errors"
    }
    if ($null -eq $p.ExitCode -or $p.ExitCode -ne 0 -or
        -not (Select-String -LiteralPath $stdout -SimpleMatch "V3_GEOLOGY_FIXTURE_PASS phase=$phase") -or
        -not (Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS')) {
        throw "V3 geology $phase failed exit=$($p.ExitCode)"
    }
}
$geologyWorld=Join-Path $env:V3_WORLD_ROOT 'geology_fixture'
$checkpoint=Get-Content (Join-Path $geologyWorld 'checkpoint.json') -Raw | ConvertFrom-Json
if ($checkpoint.generation -ne 2 -or $checkpoint.core.terrain_revision -ne 2 -or
    $checkpoint.generator_version -ne 'v3_2_single_s4_v1:earth:temperate' -or
    $checkpoint.pins.Count -ne 4 -or (Test-Path (Join-Path $geologyWorld 'session_pending'))) {
    throw 'V3 geology checkpoint contract failed'
}
Write-Host 'V3_GEOLOGY_E2E_PASS (headless; no graphical qualification)'

# Two seeds/profiles; only the primary world needs a second reopen process.
$env:V3_WORLD_ROOT=Join-Path $results 'cave-worlds'
New-Item -ItemType Directory -Force $env:V3_WORLD_ROOT | Out-Null
foreach ($case in @(
    @{id='natural_fixture';seed='20261119';profile='karst:natural';phases=@('write','reopen')},
    @{id='wide_fixture';seed='20261120';profile='karst:wide';phases=@('write')}
)) {
    $env:V3_WORLD_ID=$case.id
    $env:V3_WORLD_SEED=$case.seed
    $env:V3_CAVE_PROFILE=$case.profile
    $env:V3_GEOLOGY_PROFILE='earth:temperate'
    foreach ($phase in $case.phases) {
        $stdout=Join-Path $results "caves-$($case.id)-$phase.stdout.log"
        $stderr=Join-Path $results "caves-$($case.id)-$phase.stderr.log"
        $p=Start-Process -FilePath $editor -ArgumentList @('--headless','--path',('"'+$project+'"'),'--script','res://tests/v3_caves_smoke.gd','--',"--phase=$phase") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow
        $null=$p.Handle
        if (-not $p.WaitForExit(180000)) { $p.Kill(); $p.WaitForExit(); throw "V3 caves $phase timed out" }
        $p.WaitForExit()
        Get-Content $stdout
        Get-Content $stderr
        if (Select-String -LiteralPath @($stdout,$stderr) -Pattern 'SHADER ERROR:|Shader compilation failed|SCRIPT ERROR:|V3_CAVES_FAIL:') {
            throw "V3 caves $phase contains errors"
        }
        if ($null -eq $p.ExitCode -or $p.ExitCode -ne 0 -or
            -not (Select-String -LiteralPath $stdout -SimpleMatch "V3_CAVES_FIXTURE_PASS phase=$phase") -or
            -not (Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS')) {
            throw "V3 caves $phase failed exit=$($p.ExitCode)"
        }
    }
    $worldPath=Join-Path $env:V3_WORLD_ROOT $case.id
    $checkpoint=Get-Content (Join-Path $worldPath 'checkpoint.json') -Raw | ConvertFrom-Json
    if ($checkpoint.generation -ne $case.phases.Count -or $checkpoint.core.terrain_revision -ne 1 -or
        $checkpoint.generator_version -ne "v3_3_caves_v3:earth:temperate:$($case.profile)" -or
        $checkpoint.pins.Count -ne 5 -or (Test-Path (Join-Path $worldPath 'session_pending'))) {
        throw 'V3 caves checkpoint contract failed'
    }
}
Write-Host 'V3_CAVES_E2E_PASS (headless topology and persistence; graphical route pending)'

$env:V3_WORLD_ROOT=Join-Path $results 'fluid-worlds'
$env:V3_WORLD_ID='fluid_fixture'
$env:V3_WORLD_SEED='20261119'
$env:V3_CAVE_PROFILE='karst:natural'
$env:V3_GEOLOGY_PROFILE='earth:temperate'
New-Item -ItemType Directory -Force $env:V3_WORLD_ROOT | Out-Null
$mass=$null
foreach ($phase in @('write','reopen')) {
    $stdout=Join-Path $results "fluids-$phase.stdout.log"
    $stderr=Join-Path $results "fluids-$phase.stderr.log"
    $p=Start-Process -FilePath $editor -ArgumentList @('--headless','--path',('"'+$project+'"'),'--script','res://tests/v3_fluids_smoke.gd','--',"--phase=$phase") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow
    $null=$p.Handle
    if (-not $p.WaitForExit(180000)) { $p.Kill(); $p.WaitForExit(); throw "V3 fluids $phase timed out" }
    $p.WaitForExit()
    Get-Content $stdout
    Get-Content $stderr
    if (Select-String -LiteralPath @($stdout,$stderr) -Pattern 'SHADER ERROR:|Shader compilation failed|SCRIPT ERROR:|V3_FLUID_RUNTIME_FAIL:|V3_RESERVOIR_REJECTED:') {
        throw "V3 fluids $phase contains errors"
    }
    $marker=Select-String -LiteralPath $stdout -Pattern "V3_FLUID_RUNTIME_FIXTURE_PASS phase=$phase mass=(\d+)"
    if ($null -eq $p.ExitCode -or $p.ExitCode -ne 0 -or !$marker -or
        -not (Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS')) {
        throw "V3 fluids $phase failed exit=$($p.ExitCode)"
    }
    $observed=[int64]$marker.Matches[0].Groups[1].Value
    if ($phase -eq 'write') {
        if (!(Select-String -LiteralPath $stdout -SimpleMatch 'V3_FLUID_BREACH_PASS')) { throw 'Missing real terrain breach evidence' }
        $mass=$observed
    }
    elseif ($observed -ne $mass) { throw 'Fluid mass changed across reopen' }
}
$fluidWorld=Join-Path $env:V3_WORLD_ROOT 'fluid_fixture'
$checkpoint=Get-Content (Join-Path $fluidWorld 'checkpoint.json') -Raw | ConvertFrom-Json
if ($checkpoint.generation -ne 2 -or $checkpoint.core.terrain_revision -ne 2 -or
    $checkpoint.generator_version -ne 'v3_4_fluids_v2:v3_3_caves_v3:earth:temperate:karst:natural' -or
    $checkpoint.pins.Count -ne 6 -or (Test-Path (Join-Path $fluidWorld 'session_pending'))) {
    throw 'V3 fluid checkpoint contract failed'
}
Write-Host "V3_FLUID_RUNTIME_E2E_PASS mass_litres=$mass (headless)"
