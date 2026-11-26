param(
    [string]$ArtifactZip='',
    [ValidateSet('Pond','Lake','Lava')]
    [string]$Spawn='Pond'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$candidate='2f5cef4d1518af57aa4be96a44124cc0f2498ea8'
$run='45863463827'
$artifact='v3-native-integration-evidence'
$zipSha='e3fc22c950d4b7ccb501d6b50c79aa8f8ee923593a0801161945f0c28d66cbd5'
if ((Get-Process -Id $PID).SessionId -eq 0) { throw 'Graphical fixture requires an interactive Windows session' }
if (@(Get-Process -Name 'godot*' -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Close other Godot processes first' }
& git -C $root diff --quiet $candidate HEAD -- godot native third_party.lock
if ($LASTEXITCODE -ne 0) { throw 'Checkout runtime differs from validated candidate' }
& git -C $root diff --quiet HEAD -- godot native third_party.lock
if ($LASTEXITCODE -ne 0) { throw 'Local tracked runtime modifications detected' }
$stamp=[DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
$report=Join-Path $root "reports/generated/v3-fluids-visual/$stamp"
$stage=Join-Path $report 'artifact'
New-Item -ItemType Directory -Force $stage | Out-Null
if (!$ArtifactZip) {
    $defaultZip=Join-Path $env:USERPROFILE 'Downloads/v3-native-integration-evidence.zip'
    if (Test-Path -LiteralPath $defaultZip) {
        if ((Get-FileHash -LiteralPath $defaultZip -Algorithm SHA256).Hash.ToLowerInvariant() -eq $zipSha) {
            $ArtifactZip=$defaultZip
        }
    }
}
if ($ArtifactZip) {
    $ArtifactZip=(Resolve-Path -LiteralPath $ArtifactZip).Path
    if ((Get-FileHash -LiteralPath $ArtifactZip -Algorithm SHA256).Hash.ToLowerInvariant() -ne $zipSha) {
        throw 'Artifact ZIP SHA256 mismatch: download the exact run artifact'
    }
    Expand-Archive -LiteralPath $ArtifactZip -DestinationPath $stage
} elseif (Get-Command gh.exe -ErrorAction SilentlyContinue) {
    & gh.exe run download $run --repo publiomcko-labs/sandbox_v2_mvp_godotVoxel --name $artifact --dir $stage
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI download failed: download artifact manually and pass -ArtifactZip' }
} else {
    throw 'Download https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/45863463827/artifacts/15139331707 and pass -ArtifactZip <path>'
}
$dll='godot/bin/sandbox_native.windows.template_debug.x86_64.dll'
foreach ($file in @($dll,'extension_api.json')) {
    $src=Join-Path $stage $file
    if (!(Test-Path -LiteralPath $src -PathType Leaf)) { throw "Missing validated artifact file: $file" }
    $dst=Join-Path $root $file
    New-Item -ItemType Directory -Force (Split-Path -Parent $dst) | Out-Null
    Copy-Item -LiteralPath $src -Destination $dst -Force
}
& (Join-Path $root 'scripts/bootstrap-windows.ps1') -RuntimeOnly
if (!$?) { throw 'Locked runtime bootstrap failed' }
$project=Join-Path $root 'godot'
$cache=Join-Path $project '.godot'
New-Item -ItemType Directory -Force $cache | Out-Null
[IO.File]::WriteAllText((Join-Path $cache 'extension_list.cfg'),("res://sandbox_native.gdextension"+[Environment]::NewLine),(New-Object Text.UTF8Encoding($false)))
$env:V3_WORLD_ROOT=Join-Path $report 'worlds'
$env:V3_MOD_ROOT=Join-Path $root 'examples/v3/mods'
$env:V3_WORLD_ID='visual_fixture'
$env:V3_GEOLOGY_PROFILE='earth:temperate'
$env:V3_CAVE_PROFILE='karst:natural'
$env:V3_WORLD_SEED='20261119'
switch ($Spawn) {
    'Pond' { $env:V3_CAVE_SPAWN='-4,12,42' }
    'Lake' { $env:V3_CAVE_SPAWN='-42,16,-2' }
    'Lava' { $env:V3_CAVE_SPAWN='48,16,-12' }
}
New-Item -ItemType Directory -Force $env:V3_WORLD_ROOT | Out-Null
$stdout=Join-Path $report 'godot-stdout.txt'
$stderr=Join-Path $report 'godot-stderr.txt'
$editor=Join-Path $root '.tools/godot.exe'
Write-Host 'V3.4c: inspect open water sheets, smooth margins, faster flow and animated waterfalls, excavate a path below the pond edge, check progressive flow and dry distant caves. Wet construction is rejected. G toggles physical swimming. Close the window normally.'
$p=Start-Process -FilePath $editor -ArgumentList @('--path',('"'+$project+'"'),'--rendering-method','gl_compatibility','res://scenes/v3_fluids_main.tscn') -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$null=$p.Handle
$p.WaitForExit()
$meta=[ordered]@{candidate=$candidate;run_id=$run;profile=$env:V3_CAVE_PROFILE;seed=$env:V3_WORLD_SEED;spawn=$Spawn;exit_code=$p.ExitCode;native_dll_sha256=(Get-FileHash -LiteralPath (Join-Path $root $dll) -Algorithm SHA256).Hash;visual_gate='USER_OBSERVATION_REQUIRED'}
$meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $report 'metadata.json') -Encoding UTF8
$zip=Join-Path $report 'v3_fluids_visual_evidence.zip'
Compress-Archive -LiteralPath @($stdout,$stderr,(Join-Path $report 'metadata.json')) -DestinationPath $zip -Force
Write-Host "V3_FLUIDS_VISUAL_EVIDENCE=$zip"
if ($null -eq $p.ExitCode -or $p.ExitCode -ne 0 -or
    !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS') -or
    !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_FLUID_VISUAL_REPORT') -or
    (Select-String -LiteralPath @($stdout,$stderr) -Pattern 'SHADER ERROR:|Shader compilation failed|SCRIPT ERROR:|V3_RESERVOIR_REJECTED:')) {
    throw 'Visual runtime/clean-close failed; send evidence ZIP'
}
Write-Host 'V3_GRAPHICAL_RUNTIME_EXIT_PASS; visual quality must be assessed by user'
