param(
    [ValidateSet('template_debug','template_release')]
    [string] $Target = 'template_debug',
    [switch] $SkipDownload,
    [switch] $RuntimeOnly
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$lock = Get-Content (Join-Path $root 'third_party.lock') -Raw | ConvertFrom-Json
$toolsDir = Join-Path $root '.tools'
$cppDir = Join-Path $root 'third_party/godot-cpp'
$editor = Join-Path $toolsDir 'godot.exe'
$archive = Join-Path $toolsDir 'godot-editor.zip'
New-Item -ItemType Directory -Force $toolsDir | Out-Null

if (-not $SkipDownload) {
    Write-Host 'Fetching locked custom Godot editor...'
    Invoke-WebRequest -Uri $lock.godot.editor_windows.url -OutFile $archive
    $actual = (Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $lock.godot.editor_windows.sha256) {
        throw "Editor SHA-256 mismatch: expected $($lock.godot.editor_windows.sha256), got $actual"
    }
    $unzip = Join-Path $toolsDir 'unpacked'
    New-Item -ItemType Directory -Force $unzip | Out-Null
    Expand-Archive -LiteralPath $archive -DestinationPath $unzip -Force
    $executable = Get-ChildItem $unzip -Recurse -File -Filter 'godot.windows.editor.x86_64.exe' | Select-Object -First 1
    if ($null -eq $executable) { throw 'Godot editor EXE absent from verified release archive' }
    Copy-Item -LiteralPath $executable.FullName -Destination $editor -Force
}
if (-not (Test-Path $editor)) { throw "Missing editor: $editor" }

if ($RuntimeOnly) {
    # A2 changes no native sources. Reuse the exact DLL and custom API from
    # the successfully compiled A1 artifact, after static SHA checks.
    $dll = Join-Path $root "godot/bin/sandbox_native.windows.$Target.x86_64.dll"
    $apiFile = Join-Path $root 'extension_api.json'
    if (-not (Test-Path $dll)) { throw "A2 locked snapshot DLL missing: $dll" }
    if (-not (Test-Path $apiFile)) { throw "A2 locked snapshot API missing: $apiFile" }
    $apiData = Get-Content -LiteralPath $apiFile -Raw | ConvertFrom-Json
    if (-not ($apiData.classes | Where-Object { $_.name -eq 'VoxelLodTerrain' })) {
        throw 'A2 snapshot API missing VoxelLodTerrain'
    }
    Write-Host "A2_LOCKED_RUNTIME_OK: verified editor and locked A1 API/DLL"
    return
}


# GitHub Actions checkout can fall back to a source archive when Git is absent.
# Fetch godot-cpp at its exact locked SHA through the same GitHub source endpoint.
$commit = [string]$lock.godot_cpp.commit
if ($commit -notmatch '^[0-9a-f]{40}$') { throw "Invalid godot-cpp SHA: $commit" }
$gitExe = Get-Command 'git.exe' -ErrorAction SilentlyContinue
if ($null -ne $gitExe) {
    Write-Host "Fetching locked godot-cpp revision through Git: $commit"
    if (-not (Test-Path (Join-Path $cppDir '.git'))) {
        if (Test-Path $cppDir) { Remove-Item -LiteralPath $cppDir -Recurse -Force }
        New-Item -ItemType Directory -Force $cppDir | Out-Null
        & $gitExe.Source -C $cppDir init -q
        if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
        & $gitExe.Source -C $cppDir remote add origin $lock.godot_cpp.repository
        if ($LASTEXITCODE -ne 0) { throw 'git remote add failed' }
    }
    & $gitExe.Source -C $cppDir fetch --depth 1 origin $commit
    if ($LASTEXITCODE -ne 0) { throw 'git fetch failed' }
    & $gitExe.Source -C $cppDir checkout --detach --force FETCH_HEAD
    if ($LASTEXITCODE -ne 0) { throw 'git checkout failed' }
    $actualCommit = (& $gitExe.Source -C $cppDir rev-parse HEAD).Trim()
    if ($actualCommit -ne $commit) { throw "godot-cpp commit mismatch: $actualCommit" }
} else {
    Write-Host "Git is not installed; obtaining pinned source archive: $commit"
    $sourceZip = Join-Path $toolsDir 'godot-cpp-source.zip'
    $sourceExtract = Join-Path $toolsDir 'godot-cpp-extract'
    $url = "https://github.com/godotengine/godot-cpp/archive/$commit.zip"
    Invoke-WebRequest -Uri $url -OutFile $sourceZip -UseBasicParsing
    if (Test-Path $sourceExtract) { Remove-Item -LiteralPath $sourceExtract -Force -Recurse }
    New-Item -ItemType Directory -Force $sourceExtract | Out-Null
    Expand-Archive -LiteralPath $sourceZip -DestinationPath $sourceExtract -Force
    $sourceRoot = Join-Path $sourceExtract "godot-cpp-$commit"
    if (-not (Test-Path (Join-Path $sourceRoot 'SConstruct'))) {
        throw "Pinned godot-cpp archive missing SConstruct: $sourceRoot"
    }
    if (Test-Path $cppDir) { Remove-Item -LiteralPath $cppDir -Force -Recurse }
    Copy-Item -LiteralPath $sourceRoot -Destination $cppDir -Recurse -Force
    Write-Host "Unpacked pinned godot-cpp source: $commit"
}

# V3 full native build only. RuntimeOnly retains the existing A5 path.
$jsonDir = Join-Path $root 'third_party/nlohmann-json'
$jsonCommit = [string]$lock.nlohmann_json.commit
if ($jsonCommit -notmatch '^[0-9a-f]{40}$' -or $null -eq $gitExe) { throw 'V3 native build requires Git and pinned JSON commit' }
if (-not (Test-Path (Join-Path $jsonDir '.git'))) {
    if (Test-Path $jsonDir) { throw "Unmanaged JSON dependency directory: $jsonDir" }
    New-Item -ItemType Directory -Force $jsonDir | Out-Null
    & $gitExe.Source -C $jsonDir init -q
    if ($LASTEXITCODE -ne 0) { throw 'JSON git init failed' }
    & $gitExe.Source -C $jsonDir remote add origin $lock.nlohmann_json.repository
    if ($LASTEXITCODE -ne 0) { throw 'JSON remote failed' }
}
& $gitExe.Source -C $jsonDir fetch --depth 1 origin $jsonCommit
if ($LASTEXITCODE -ne 0) { throw 'JSON dependency fetch failed' }
& $gitExe.Source -C $jsonDir checkout --detach FETCH_HEAD
if ($LASTEXITCODE -ne 0) { throw 'JSON dependency checkout failed' }
if ((& $gitExe.Source -C $jsonDir rev-parse HEAD).Trim() -ne $jsonCommit) { throw 'JSON revision mismatch' }
if (@(& $gitExe.Source -C $jsonDir status --porcelain).Count -ne 0) { throw 'Dirty JSON dependency' }
Write-Host 'Generating extension_api.json from the locked custom engine...'
$probe = Join-Path $toolsDir 'api-probe'
New-Item -ItemType Directory -Force $probe | Out-Null
Set-Content -LiteralPath (Join-Path $probe 'project.godot') -Value 'config_version=5' -Encoding UTF8
Push-Location $probe
try {
    Write-Host "Godot API probe directory: $(Get-Location)"
    # Windows GUI-subsystem executables may return to PowerShell before the process exits.
    $dump = Start-Process -FilePath $editor -ArgumentList @('--headless', '--editor', '--path', ('"' + $probe + '"'), '--dump-extension-api') -Wait -PassThru -NoNewWindow
    if ($dump.ExitCode -ne 0) { throw "Godot --dump-extension-api failed: exit=$($dump.ExitCode)" }
} finally { Pop-Location }
# Search only the generated probe and binary paths, never the godot-cpp bundled vanilla API.
$candidates = @(
    (Join-Path $probe 'extension_api.json'),
    (Join-Path $toolsDir 'extension_api.json'),
    (Join-Path $root 'extension_api.json'),
    (Join-Path $root 'godot/extension_api.json')
)
Write-Host "API probe files:"
Get-ChildItem -LiteralPath $probe -Force -File | ForEach-Object { Write-Host $_.FullName }
$foundApi = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $foundApi) { throw "Custom Godot API missing: $($candidates -join '; ')" }
$api = Join-Path $root 'extension_api.json'
if ($foundApi -ne $api) { Copy-Item -LiteralPath $foundApi -Destination $api -Force }
Write-Host "Found custom API: $foundApi"
$apiData = Get-Content $api -Raw | ConvertFrom-Json
if (-not ($apiData.classes | Where-Object { $_.name -eq 'VoxelLodTerrain' })) {
    throw 'Custom Godot API contains no VoxelLodTerrain; wrong engine binary'
}

Write-Host "Building native GDExtension ($Target)..."
& scons -C (Join-Path $root 'native') 'platform=windows' "target=$Target" "custom_api_file=$api" '-j4'
if ($LASTEXITCODE -ne 0) { throw "SCons failed: exit $LASTEXITCODE" }
$dll = Join-Path $root "godot/bin/sandbox_native.windows.$Target.x86_64.dll"
if (-not (Test-Path $dll)) { throw "Expected GDExtension DLL missing: $dll" }
Write-Host "A0_BUILD_PASS: $dll"
