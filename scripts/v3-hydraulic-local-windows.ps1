param(
    [string]$ArtifactZip='',
    [ValidateSet('Pond','Lava','Sea')]
    [string]$Spawn='Pond'
)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$candidate='1067bc7d6ebae83f41820ceef78403b79abaafba'
$run='45982136425'
$artifact='v3-native-integration-evidence'
$zipSha='65b346343f7f35e24d06aea8cba3c768a022bebc576ce872145848c81e78bc6c'
if ((Get-Process -Id $PID).SessionId -eq 0) { throw 'Graphical fixture requires an interactive Windows session' }
if (@(Get-Process -Name 'godot*' -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Close other Godot processes first' }
& git -C $root diff --quiet $candidate HEAD -- godot native third_party.lock ':(exclude)godot/tests/v3_hydraulic_gpu_capture.gd'
if ($LASTEXITCODE -ne 0) { throw 'Checkout runtime differs from validated candidate' }
& git -C $root diff --quiet HEAD -- godot native third_party.lock
if ($LASTEXITCODE -ne 0) { throw 'Local tracked runtime modifications detected' }
$stamp=[DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
$report=Join-Path $root "reports/generated/v3-hydraulic-visual/$stamp"
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
    throw 'Download https://github.com/publiomcko-labs/sandbox_v2_mvp_godotVoxel/actions/runs/45982136425/artifacts/15189683209 and pass -ArtifactZip <path>'
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
    'Pond' { $env:V3_CAVE_SPAWN='-4,12,28' }
    'Lava' { $env:V3_CAVE_SPAWN='48,12,-28' }
    'Sea' { $env:V3_CAVE_SPAWN='-128,12,128' }
}
New-Item -ItemType Directory -Force $env:V3_WORLD_ROOT | Out-Null
$stdout=Join-Path $report 'godot-stdout.txt'
$stderr=Join-Path $report 'godot-stderr.txt'
$editor=Join-Path $root '.tools/godot.exe'
Write-Host 'V3 hydraulic H14: inspect movement during active discharge, continuous shoreline and grouped mesh swaps after edits; close normally. Lava/Sea source spawns are exploratory and not yet terrain-qualified.'
$p=Start-Process -FilePath $editor -ArgumentList @('--path',('"'+$project+'"'),'--rendering-method','gl_compatibility','res://scenes/v3_hydraulic_main.tscn') -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$null=$p.Handle
$p.WaitForExit()
$meta=[ordered]@{candidate=$candidate;run_id=$run;profile=$env:V3_CAVE_PROFILE;seed=$env:V3_WORLD_SEED;spawn=$Spawn;exit_code=$p.ExitCode;native_dll_sha256=(Get-FileHash -LiteralPath (Join-Path $root $dll) -Algorithm SHA256).Hash;visual_gate='USER_OBSERVATION_REQUIRED'}
$meta | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $report 'metadata.json') -Encoding UTF8
$zip=Join-Path $report 'v3_hydraulic_visual_evidence.zip'
Compress-Archive -LiteralPath @($stdout,$stderr,(Join-Path $report 'metadata.json')) -DestinationPath $zip -Force
Write-Host "V3_HYDRAULIC_VISUAL_EVIDENCE=$zip"
if ($null -eq $p.ExitCode -or $p.ExitCode -ne 0 -or
    !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_RUNTIME_CLEAN_CLOSE_PASS') -or
    !(Select-String -LiteralPath $stdout -SimpleMatch 'V3_HYDRAULIC_VISUAL_REPORT') -or
    (Select-String -LiteralPath @($stdout,$stderr) -Pattern 'SHADER ERROR:|Shader compilation failed|SCRIPT ERROR:')) {
    throw 'Visual runtime/clean-close failed; send evidence ZIP'
}
Write-Host 'V3_GRAPHICAL_RUNTIME_EXIT_PASS; visual quality must be assessed by user'
