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
    $hydraulicCapacity=$null
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
            -not (Select-String -LiteralPath $stdout -SimpleMatch "V3_HYDRAULIC_SDF_PASS phase=$phase") -or
            -not (Select-String -LiteralPath $stdout -SimpleMatch "V3_CAVES_FIXTURE_PASS phase=$phase") -or
            -not (Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS')) {
            throw "V3 caves $phase failed exit=$($p.ExitCode)"
        }
        $marker=Select-String -LiteralPath $stdout -Pattern 'V3_HYDRAULIC_SDF_PASS.*capacity_after=(\d+)'
        if (!$marker) { throw 'Hydraulic SDF evidence missing' }
        $observed=[int64]$marker.Matches[0].Groups[1].Value
        if ($phase -eq 'write') { $hydraulicCapacity=$observed }
        elseif ($observed -ne $hydraulicCapacity) { throw 'Hydraulic geometry differs across SQLite reopen' }
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

$env:V3_WORLD_ROOT=Join-Path $results 'hydraulic-worlds'
$env:V3_WORLD_ID='hydraulic_fixture'
$env:V3_WORLD_SEED='20261119'
$env:V3_CAVE_PROFILE='karst:natural'
$env:V3_GEOLOGY_PROFILE='earth:temperate'
New-Item -ItemType Directory -Force $env:V3_WORLD_ROOT | Out-Null
$mass=$null
foreach ($phase in @('write','reopen')) {
    $stdout=Join-Path $results "hydraulic-$phase.stdout.log"
    $stderr=Join-Path $results "hydraulic-$phase.stderr.log"
    $p=Start-Process -FilePath $editor -ArgumentList @('--headless','--path',('"'+$project+'"'),'--script','res://tests/v3_hydraulic_smoke.gd','--',"--phase=$phase") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow
    $null=$p.Handle
    if (-not $p.WaitForExit(180000)) { $p.Kill(); $p.WaitForExit(); throw "Hydraulic $phase timed out" }
    $p.WaitForExit()
    Get-Content $stdout
    Get-Content $stderr
    if (Select-String -LiteralPath @($stdout,$stderr) -Pattern 'SHADER ERROR:|Shader compilation failed|SCRIPT ERROR:|V3_HYDRAULIC_RUNTIME_FAIL:') { throw "Hydraulic $phase errors" }
    $marker=Select-String -LiteralPath $stdout -Pattern "V3_HYDRAULIC_RUNTIME_PASS phase=$phase mass=(\d+)"
    if ($null -eq $p.ExitCode -or $p.ExitCode -ne 0 -or !$marker -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS')) { throw "Hydraulic $phase failed" }
    $observed=[int64]$marker.Matches[0].Groups[1].Value
    if ($phase -eq 'write') {
        if (!(Select-String -LiteralPath $stdout -SimpleMatch 'V3_HYDRAULIC_EDIT_RETENTION_PASS') -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_HYDRAULIC_BASIN_RUNTIME_PASS') -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_HYDRAULIC_WET_BREACH_PASS') -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_HYDRAULIC_VISIBILITY_PASS')) { throw 'Missing breach/visibility evidence' }
        $mass=$observed
    }
    elseif ($mass -ne $observed) { throw 'Hydraulic mass changed on reopen' }
}
$worldPath=Join-Path $env:V3_WORLD_ROOT 'hydraulic_fixture'
$checkpoint=Get-Content (Join-Path $worldPath 'checkpoint.json') -Raw | ConvertFrom-Json
if ($checkpoint.generation -ne 2 -or $checkpoint.core.terrain_revision -ne 2 -or $checkpoint.pins.Count -ne 6 -or !(Test-Path (Join-Path $worldPath 'hydraulic_domain.json')) -or (Test-Path (Join-Path $worldPath 'session_pending'))) { throw 'Hydraulic checkpoint contract failed' }
Write-Host "V3_HYDRAULIC_E2E_PASS mass=$mass"

# R3 integrated mode uses an isolated generator and archive identity.
if ($env:GITHUB_REF_NAME -eq 'exp/v3-hydraulic-hybrid') {
    $env:V3_HYBRID_SOLVER='1'
    $env:V3_WORLD_ROOT=Join-Path $results 'hybrid-integrated-worlds'
    $env:V3_WORLD_ID='hybrid_integrated_fixture'
    New-Item -ItemType Directory -Force $env:V3_WORLD_ROOT | Out-Null
    $hybridMass=$null
    foreach ($phase in @('write','reopen')) {
        $stdout=Join-Path $results "hybrid-integrated-$phase.stdout.log"
        $stderr=Join-Path $results "hybrid-integrated-$phase.stderr.log"
        $p=Start-Process -FilePath $editor -ArgumentList @('--headless','--path',('"'+$project+'"'),'--script','res://tests/v3_hydraulic_integrated.gd','--',"--phase=$phase") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow
        $null=$p.Handle
        if (!$p.WaitForExit(240000)) { $p.Kill(); $p.WaitForExit(); throw "Hybrid integrated $phase timeout" }
        $p.WaitForExit()
        Get-Content $stdout
        Get-Content $stderr
        if (Select-String -LiteralPath @($stdout,$stderr) -Pattern 'SCRIPT ERROR:|V3_HYBRID_INTEGRATED_FAIL:') { throw "Hybrid integrated $phase errors" }
        $marker=Select-String -LiteralPath $stdout -Pattern "V3_HYBRID_INTEGRATED_PASS phase=$phase mass=(\d+)"
        if ($p.ExitCode -ne 0 -or !$marker -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS')) { throw "Hybrid integrated $phase failed" }
        $observed=[int64]$marker.Matches[0].Groups[1].Value
        if ($phase -eq 'write') { $hybridMass=$observed }
        elseif ($hybridMass -ne $observed) { throw 'Hybrid mass changed on reopen' }
    }
    # Separate actual terrain lifecycle, no changes to the breach fixture.
    $env:V3_WORLD_ID='hybrid_lifecycle_fixture'
    foreach ($phase in @('lifecycle','lifecycle-reopen')) {
        $stdout=Join-Path $results "hybrid-$phase.stdout.log"
        $stderr=Join-Path $results "hybrid-$phase.stderr.log"
        $p=Start-Process -FilePath $editor -ArgumentList @('--headless','--path',('"'+$project+'"'),'--script','res://tests/v3_hydraulic_integrated.gd','--',"--phase=$phase") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow
        $null=$p.Handle
        if (!$p.WaitForExit(180000)) { $p.Kill(); $p.WaitForExit(); throw "Hybrid $phase timeout" }
        $p.WaitForExit()
        Get-Content $stdout
        Get-Content $stderr
        if ($p.ExitCode -ne 0 -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_HYBRID_LIFECYCLE_PASS') -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS') -or (Select-String -LiteralPath @($stdout,$stderr) -Pattern 'SCRIPT ERROR:|V3_HYBRID_INTEGRATED_FAIL:')) { throw "Hybrid $phase failed" }
    }
    $env:V3_WORLD_ID='hybrid_late_sources_fixture'
    foreach ($phase in @('sources','sources-reopen')) {
        $stdout=Join-Path $results "hybrid-$phase.stdout.log"
        $stderr=Join-Path $results "hybrid-$phase.stderr.log"
        $p=Start-Process -FilePath $editor -ArgumentList @('--headless','--path',('"'+$project+'"'),'--script','res://tests/v3_hydraulic_integrated.gd','--',"--phase=$phase") -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow
        $null=$p.Handle
        if (!$p.WaitForExit(240000)) { $p.Kill(); $p.WaitForExit(); throw "Hybrid $phase timeout" }
        $p.WaitForExit()
        Get-Content $stdout
        Get-Content $stderr
        if ($p.ExitCode -ne 0 -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_HYBRID_SOURCES_PASS') -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS') -or (Select-String -LiteralPath @($stdout,$stderr) -Pattern 'SCRIPT ERROR:|V3_HYBRID_INTEGRATED_FAIL:')) { throw "Hybrid $phase failed" }
    }
    $env:V3_WORLD_ID='hybrid_barrier_fixture'
    $stdout=Join-Path $results 'hybrid-barrier.stdout.log'
    $stderr=Join-Path $results 'hybrid-barrier.stderr.log'
    $p=Start-Process -FilePath $editor -ArgumentList @('--headless','--path',('"'+$project+'"'),'--script','res://tests/v3_hydraulic_integrated.gd','--','--phase=barrier') -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow
    $null=$p.Handle
    if (!$p.WaitForExit(180000)) { $p.Kill(); $p.WaitForExit(); throw 'Hybrid barrier timeout' }
    $p.WaitForExit()
    Get-Content $stdout
    Get-Content $stderr
    if ($p.ExitCode -ne 0 -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_HYBRID_BARRIER_PASS') -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS') -or (Select-String -LiteralPath @($stdout,$stderr) -Pattern 'SCRIPT ERROR:|V3_HYBRID_INTEGRATED_FAIL:')) { throw 'Hybrid barrier failed' }
    $env:V3_WORLD_ID='hybrid_stream_fixture'
    $stdout=Join-Path $results 'hybrid-stream.stdout.log'
    $stderr=Join-Path $results 'hybrid-stream.stderr.log'
    $p=Start-Process -FilePath $editor -ArgumentList @('--headless','--path',('"'+$project+'"'),'--script','res://tests/v3_hydraulic_integrated.gd','--','--phase=streaming') -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow
    $null=$p.Handle
    if (!$p.WaitForExit(180000)) { $p.Kill(); $p.WaitForExit(); throw 'Hybrid stream timeout' }
    $p.WaitForExit()
    Get-Content $stdout
    Get-Content $stderr
    if (!(Select-String -LiteralPath $stdout -SimpleMatch 'V3_HYBRID_STREAM_SDF_PASS') -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_HYBRID_STREAM_PUBLICATION_PASS')) { throw 'Missing stream evidence' }
    if ($p.ExitCode -ne 0 -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_HYBRID_BARRIER_PASS') -or !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS') -or (Select-String -LiteralPath @($stdout,$stderr) -Pattern 'SCRIPT ERROR:|V3_HYBRID_INTEGRATED_FAIL:')) { throw 'Hybrid stream failed' }
    Remove-Item Env:V3_HYBRID_SOLVER
    Write-Host "V3_HYBRID_INTEGRATED_E2E_PASS mass=$hybridMass"
}
