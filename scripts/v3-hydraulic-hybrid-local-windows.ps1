param(
    [string]$ArtifactZip='',
    [string]$ArtifactDirectory='',
    [string]$CandidateCommit='',
    [string]$ExpectedDllSha256='',
    [string]$ExpectedZipSha256='',
    [switch]$AutomatedSmoke,
    [ValidateSet('A','B')][string]$Renderer='B',
    [ValidateSet('Hybrid','H14')][string]$Solver='Hybrid',
    [ValidateSet('Pond','Lava','Sea')][string]$Spawn='Pond'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
# Certified default; refresh these four pins only after both native and GPU PASS.
$defaultCandidate='a6f5665aeea5dddb12fad3250633384ec2602a8b'
$defaultRun='46144108908'
$defaultZip='2b4e3527b316173b2dd5a83acb431afc991096df6dd4dc8fa3aea2debf35c8d0'
$defaultDll='16e8ed2638b7dff7d989274be90bd28360700381c7f23ae47b15b954aa7f2cc1'
$candidate=if ($CandidateCommit) { $CandidateCommit.ToLowerInvariant() } else { $defaultCandidate }
$dllSha=if ($ExpectedDllSha256) { $ExpectedDllSha256.ToLowerInvariant() } else { $defaultDll }
$zipSha=if ($ExpectedZipSha256) { $ExpectedZipSha256.ToLowerInvariant() } else { $defaultZip }
if (($CandidateCommit -and !$ExpectedDllSha256) -or (!$CandidateCommit -and $ExpectedDllSha256)) {
    throw 'CandidateCommit and ExpectedDllSha256 must be supplied together'
}
if ($candidate -notmatch '^[0-9a-f]{40}$' -or $dllSha -notmatch '^[0-9a-f]{64}$' -or $zipSha -notmatch '^[0-9a-f]{64}$') {
    throw 'Invalid pinned commit or artifact hash'
}
if ((Get-Process -Id $PID).SessionId -eq 0) { throw 'Interactive Windows session required' }
if (@(Get-Process -Name 'godot*' -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Existing Godot process detected; no interference' }
& git -C $root cat-file -e "$candidate^{commit}"
if ($LASTEXITCODE -ne 0) { throw 'Pinned candidate is unavailable in local checkout' }
& git -C $root diff --quiet $candidate HEAD -- native experiments/v3/hybrid third_party.lock
if ($LASTEXITCODE -ne 0) { throw 'Native runtime differs from pinned candidate' }
& git -C $root diff --quiet $candidate HEAD -- godot/scripts godot/scenes godot/shaders godot/mods godot/sandbox_native.gdextension
if ($LASTEXITCODE -ne 0) { throw 'Visual runtime differs from pinned candidate' }
& git -C $root diff --quiet HEAD -- godot native experiments/v3/hybrid third_party.lock
if ($LASTEXITCODE -ne 0) { throw 'Local tracked runtime modifications detected' }
$stamp=[DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
$report=Join-Path $root "reports/generated/v3-hydraulic-hybrid-visual/$stamp"
$stage=Join-Path $report 'artifact'
New-Item -ItemType Directory -Force $stage | Out-Null
$dll='godot/bin/sandbox_native.windows.template_debug.x86_64.dll'
if (!$ArtifactZip -and !$ArtifactDirectory) {
    $download=Join-Path $env:USERPROFILE 'Downloads/v3-native-integration-evidence.zip'
    if ((Test-Path -LiteralPath $download) -and (Get-FileHash -LiteralPath $download -Algorithm SHA256).Hash.ToLowerInvariant() -eq $zipSha) {
        $ArtifactZip=$download
    }
}
if ($ArtifactDirectory) {
    $dir=(Resolve-Path -LiteralPath $ArtifactDirectory).Path
    foreach ($file in @($dll,'extension_api.json')) {
        $src=Join-Path $dir $file
        if (!(Test-Path -LiteralPath $src -PathType Leaf)) { throw "Missing extracted artifact file: $file" }
        $dst=Join-Path $stage $file
        New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
} elseif ($ArtifactZip) {
    $file=(Resolve-Path -LiteralPath $ArtifactZip).Path
    if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $zipSha) { throw 'Artifact ZIP SHA256 mismatch' }
    Expand-Archive -LiteralPath $file -DestinationPath $stage
} elseif (Get-Command gh.exe -ErrorAction SilentlyContinue) {
    if ($CandidateCommit) { throw 'Supply ArtifactDirectory or ArtifactZip for an explicit candidate' }
    & gh.exe run download $defaultRun --repo publiomcko-labs/sandbox_v2_mvp_godotVoxel --name v3-native-integration-evidence --dir $stage
    if ($LASTEXITCODE -ne 0) { throw 'GitHub artifact download failed' }
} else {
    throw "Obtain native artifact for commit $candidate and pass -ArtifactZip or -ArtifactDirectory"
}
$from=Join-Path $stage $dll
if (!(Test-Path -LiteralPath $from -PathType Leaf) -or
    (Get-FileHash -LiteralPath $from -Algorithm SHA256).Hash.ToLowerInvariant() -ne $dllSha) {
    throw 'Native DLL SHA256 mismatch: binary does not match pinned candidate'
}
foreach ($file in @($dll,'extension_api.json')) {
    $src=Join-Path $stage $file
    if (!(Test-Path -LiteralPath $src -PathType Leaf)) { throw "Missing validated artifact file: $file" }
    $dst=Join-Path $root $file
    New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
}
& (Join-Path $root 'scripts/bootstrap-windows.ps1') -RuntimeOnly
if (!$?) { throw 'Locked Windows runtime bootstrap failed' }
$project=Join-Path $root 'godot'
$cache=Join-Path $project '.godot'
New-Item -ItemType Directory -Force $cache | Out-Null
[IO.File]::WriteAllText((Join-Path $cache 'extension_list.cfg'),("res://sandbox_native.gdextension"+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
if ($Solver -eq 'Hybrid') {
    $env:V3_HYBRID_SOLVER='1'
    $Renderer='B'
} else {
    if ($AutomatedSmoke) { throw 'AutomatedSmoke requires Hybrid solver' }
    Remove-Item Env:V3_HYBRID_SOLVER -ErrorAction SilentlyContinue
}
$env:V3_HYBRID_RENDERER=$Renderer
$env:V3_WORLD_ROOT=Join-Path $report 'worlds'
$env:V3_MOD_ROOT=Join-Path $root 'examples/v3/mods'
$env:V3_WORLD_ID=if ($AutomatedSmoke) { 'launcher_auto_smoke' } else { 'visual_fixture' }
$env:V3_GEOLOGY_PROFILE='earth:temperate'
$env:V3_CAVE_PROFILE='karst:natural'
$env:V3_WORLD_SEED='20261119'
switch ($Spawn) {
    'Pond' { $env:V3_CAVE_SPAWN='-4,12,28' }
    'Lava' { $env:V3_CAVE_SPAWN='48,12,-28' }
    'Sea' { $env:V3_CAVE_SPAWN='-128,12,128' }
}
New-Item -ItemType Directory -Force $env:V3_WORLD_ROOT | Out-Null
$stdout=Join-Path $report 'godot-stdout.txt'
$stderr=Join-Path $report 'godot-stderr.txt'
$editor=Join-Path $root '.tools/godot.exe'
if ($AutomatedSmoke) {
    $argList=@('--headless','--path',('"'+$project+'"'),'--script','res://tests/v3_hydraulic_integrated.gd','--','--phase=remote-basin')
} else {
    $argList=@('--path',('"'+$project+'"'),'--rendering-method','gl_compatibility','res://scenes/v3_hydraulic_main.tscn')
}
Write-Host "V3.4 hybrid candidate=$candidate solver=$Solver renderer=$Renderer automated=$AutomatedSmoke"
$p=Start-Process -FilePath $editor -ArgumentList $argList -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$null=$p.Handle
if ($AutomatedSmoke) {
    if (!$p.WaitForExit(240000)) { $p.Kill();$p.WaitForExit();throw 'Launcher E2E timeout' }
} else {
    $p.WaitForExit()
}
$p.WaitForExit()
$meta=[ordered]@{
    candidate=$candidate;renderer=$Renderer;solver=$Solver;run_id=$defaultRun;spawn=$Spawn;
    automated_smoke=[bool]$AutomatedSmoke;exit_code=$p.ExitCode;expected_dll_sha256=$dllSha;
    actual_dll_sha256=(Get-FileHash -LiteralPath (Join-Path $root $dll) -Algorithm SHA256).Hash;
    visual_gate='USER_OBSERVATION_REQUIRED'
}
$meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $report 'metadata.json') -Encoding UTF8
$zip=Join-Path $report 'v3_hydraulic_hybrid_visual_evidence.zip'
Compress-Archive -LiteralPath @($stdout,$stderr,(Join-Path $report 'metadata.json')) -DestinationPath $zip -Force
Write-Host "V3_HYDRAULIC_VISUAL_EVIDENCE=$zip"
$expected=if ($AutomatedSmoke) { 'V3_HYBRID_REMOTE_BASIN_PASS' } else { 'V3_HYDRAULIC_VISUAL_REPORT' }
if ($null -eq $p.ExitCode -or $p.ExitCode -ne 0 -or
    !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS') -or
    !(Select-String -LiteralPath $stdout -SimpleMatch $expected) -or
    (Select-String -LiteralPath @($stdout,$stderr) -Pattern 'SHADER ERROR:|Shader compilation failed|SCRIPT ERROR:|V3_HYBRID_INTEGRATED_FAIL:')) {
    throw 'Launcher runtime, smoke, or clean-close failed'
}
if ($AutomatedSmoke) {
    Write-Host 'V3_HYBRID_LAUNCHER_E2E_PASS exact-artifact remote-basin clean-close'
} else {
    Write-Host 'V3_GRAPHICAL_RUNTIME_EXIT_PASS; visual quality must be assessed by user'
}
