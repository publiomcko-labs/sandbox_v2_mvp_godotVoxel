param(
    [ValidateSet('template_debug','template_release')]
    [string] $Target = 'template_debug',
    [switch] $SkipDownload,
    [switch] $RuntimeOnly
)
$ErrorActionPreference = 'Stop'
# Avoid Windows PowerShell per-byte progress rendering during locked downloads.
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$lock = Get-Content (Join-Path $root 'third_party.lock') -Raw | ConvertFrom-Json
$toolsDir = Join-Path $root '.tools'
$cppDir = Join-Path $root 'third_party/godot-cpp'
$editor = Join-Path $toolsDir 'godot.exe'
$archive = Join-Path $toolsDir 'godot-editor.zip'
New-Item -ItemType Directory -Force $toolsDir | Out-Null

if (-not $RuntimeOnly) {
    # Fetch the single-header JSON library and its license directly from the
    # immutable revision. This path works on Windows runners without git.exe.
    $jsonDir = Join-Path $root 'third_party/nlohmann-json'
    $jsonCommit = [string]$lock.nlohmann_json.commit
    if ($jsonCommit -notmatch '^[0-9a-f]{40}$') { throw 'Invalid pinned JSON commit' }
    function Confirm-GitBlob {
        param([string]$Path, [string]$Expected, [long]$Size)
        if ($Expected -notmatch '^[0-9a-f]{40}$' -or $Size -le 0) { throw 'Invalid JSON blob lock' }
        if (!(Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
        if ((Get-Item -LiteralPath $Path).Length -ne $Size) { return $false }
        $bytes = [IO.File]::ReadAllBytes($Path)
        $prefix = [Text.Encoding]::ASCII.GetBytes("blob $($bytes.Length)" + [char]0)
        $inputBytes = New-Object byte[] ($prefix.Length + $bytes.Length)
        [Buffer]::BlockCopy($prefix, 0, $inputBytes, 0, $prefix.Length)
        [Buffer]::BlockCopy($bytes, 0, $inputBytes, $prefix.Length, $bytes.Length)
        $sha = [Security.Cryptography.SHA1]::Create()
        try { $actual = [BitConverter]::ToString($sha.ComputeHash($inputBytes)).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        return ($actual -eq $Expected)
    }
    foreach ($entry in @($lock.nlohmann_json.files)) {
        $relative = [string]$entry.path
        if ($relative -notin @('single_include/nlohmann/json.hpp','LICENSE.MIT')) { throw 'Unexpected JSON dependency path' }
        $destination = Join-Path $jsonDir $relative
        $expected = [string]$entry.git_blob_sha1
        $size = [long]$entry.bytes
        if (!(Confirm-GitBlob -Path $destination -Expected $expected -Size $size)) {
            New-Item -ItemType Directory -Force (Split-Path -Parent $destination) | Out-Null
            $tmp = "$destination.download"
            Invoke-WebRequest -Uri "https://raw.githubusercontent.com/nlohmann/json/$jsonCommit/$relative" -OutFile $tmp -UseBasicParsing
            if (!(Confirm-GitBlob -Path $tmp -Expected $expected -Size $size)) { throw "Pinned JSON blob mismatch: $relative" }
            Move-Item -LiteralPath $tmp -Destination $destination -Force
        }
        Write-Host "V3_JSON_BLOB_VERIFIED path=$relative revision=$jsonCommit"
    }
    if (!(Test-Path -LiteralPath (Join-Path $jsonDir 'single_include/nlohmann/json.hpp') -PathType Leaf)) { throw 'Pinned JSON header missing' }
}

if (-not $SkipDownload) {
    Write-Host 'Fetching locked custom Godot editor...'
    Invoke-WebRequest -Uri $lock.godot.editor_windows.url -OutFile $archive -UseBasicParsing
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
