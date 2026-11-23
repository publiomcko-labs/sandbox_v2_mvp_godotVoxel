param(
    [ValidateSet('static_remove','static_add','boundary_remove','boundary_add')]
    [string[]] $Scenarios = @('static_remove','static_add','boundary_remove','boundary_add'),
    [ValidateRange(1,10)] [int] $Repeats = 3,
    [ValidateRange(5,180)] [int] $Warmup = 45,
    [string] $SeedList = '20261119',
    [string] $FfmpegExe = '',
    [switch] $ContinueOnFailure,
    [switch] $FullArchive
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
# -File does not reliably bind a comma-delimited string to [int[]]; parse it
# explicitly so the documented CLI works in Windows PowerShell 5.1.
try {
    $Seeds = @($SeedList.Split(',') | ForEach-Object { [int]::Parse($_.Trim()) })
} catch { throw "A74_BATCH_INVALID_SEED_LIST $SeedList" }
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runner = Join-Path $PSScriptRoot 'a74-pilot-windows.ps1'
$reporter = Join-Path $PSScriptRoot 'a74_batch_report.py'
if (-not (Test-Path -LiteralPath $runner) -or -not (Test-Path -LiteralPath $reporter)) {
    throw 'A74_BATCH_SCRIPTS_MISSING'
}
if ($Seeds.Count -lt 1 -or $Seeds.Count -gt 5 -or $Seeds.Count -ne @($Seeds | Select-Object -Unique).Count) {
    throw 'A74_BATCH_SEEDS_INVALID: use 1..5 distinct seeds'
}
if ($Scenarios.Count -ne @($Scenarios | Select-Object -Unique).Count) {
    throw 'A74_BATCH_DUPLICATE_SCENARIO'
}
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$base = Join-Path $root 'reports/generated/a74-batch'
$batchId = "batch-$stamp-$PID"
$folder = Join-Path $base $batchId
if (Test-Path -LiteralPath $folder) { throw 'A74_BATCH_FOLDER_ALREADY_EXISTS' }
New-Item -ItemType Directory -Path $folder -Force | Out-Null
$manifestPath = Join-Path $folder 'a74_batch_manifest.json'
$trials = [System.Collections.Generic.List[object]]::new()
$manifest = [ordered]@{
    schema = 'a74_batch_manifest_v1'
    batch_id = $batchId
    git_sha = (& git -C $root rev-parse HEAD).Trim()
    sampling_policy = 'one brush per process, isolated SQLite/video/oracle; fixed seed across repeats for comparable variation'
    scenarios = @($Scenarios)
    seeds = @($Seeds)
    repeats_per_scenario_seed = $Repeats
    expected_runs = ($Scenarios.Count * $Seeds.Count * $Repeats)
    collection_complete = $false
    trials = @()
    edit_100_gate = 'NOT_QUALIFIED'
}
function Write-BatchManifest {
    $manifest.trials = @($trials.ToArray())
    $manifest | ConvertTo-Json -Depth 9 |
        Set-Content -LiteralPath $manifestPath -Encoding UTF8
}
Write-BatchManifest
Write-Host "A74_BATCH_START id=$batchId runs=$($manifest.expected_runs)"
$stop = $false
foreach ($scenario in $Scenarios) {
    foreach ($seed in $Seeds) {
        for ($repeat = 1; $repeat -le $Repeats; $repeat++) {
            $relative = "$scenario/seed-$seed/run-$('{0:D2}' -f $repeat)"
            $target = Join-Path $folder ($relative.Replace('/', [string][IO.Path]::DirectorySeparatorChar))
            if (Test-Path -LiteralPath $target) { throw "A74_REPEAT_FOLDER_COLLISION $target" }
            $argsList = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$runner,
                          '-Scenario',$scenario,'-Seed',[string]$seed,
                          '-Warmup',[string]$Warmup,'-OutputDirectory',$target)
            if ($FfmpegExe) { $argsList += @('-FfmpegExe',$FfmpegExe) }
            $ordinal = $trials.Count + 1
            Write-Host "A74_BATCH_TRIAL_BEGIN ordinal=$ordinal/$($manifest.expected_runs) scenario=$scenario seed=$seed repeat=$repeat"
            $exitCode = 1
            $errorText = $null
            try {
                & powershell.exe @argsList
                $exitCode = $LASTEXITCODE
            } catch {
                $errorText = $_.Exception.Message
                $exitCode = 1
            }
            $trials.Add([ordered]@{
                scenario = $scenario
                seed = $seed
                repeat = $repeat
                relative_path = $relative
                runner_exit_code = $exitCode
                runner_error = $errorText
            })
            Write-BatchManifest
            Write-Host "A74_BATCH_TRIAL_END ordinal=$ordinal scenario=$scenario seed=$seed repeat=$repeat exit=$exitCode"
            if ($exitCode -ne 0 -and -not $ContinueOnFailure) {
                Write-Warning 'A74_BATCH_STOP_ON_FAILURE: use -ContinueOnFailure to run remaining independent trials'
                $stop = $true
                break
            }
        }
        if ($stop) { break }
    }
    if ($stop) { break }
}
$manifest.collection_complete = ($trials.Count -eq $manifest.expected_runs)
Write-BatchManifest
$reportExit = 1
try {
    & python $reporter $folder
    $reportExit = $LASTEXITCODE
} catch {
    Write-Warning "A74_BATCH_REPORT_ERROR $($_.Exception.Message)"
}
# Compact upload preserves raw JSON+JSONL and references but not private desktop
# videos. Full video stays available in each isolated local trial directory.
$summaryDir = Join-Path $folder 'upload-summary'
New-Item -ItemType Directory -Force -Path $summaryDir | Out-Null
foreach ($name in @('a74_batch_manifest.json','a74_batch_report.json','a74_batch_trials.csv')) {
    $p = Join-Path $folder $name
    if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $summaryDir }
}
foreach ($trial in $trials) {
    $from = Join-Path $folder ($trial.relative_path.Replace('/', [string][IO.Path]::DirectorySeparatorChar))
    $to = Join-Path $summaryDir ($trial.relative_path.Replace('/', [string][IO.Path]::DirectorySeparatorChar))
    New-Item -ItemType Directory -Force -Path $to | Out-Null
    foreach ($name in @('a74_capture_manifest.json','a74_events.jsonl',
                        'a74_reference.json','a74_result.json','a74_pilot_review.json')) {
        $p = Join-Path $from $name
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $to }
    }
}
$summaryArchive = Join-Path $folder 'a74_batch_summary.zip'
Compress-Archive -Path (Join-Path $summaryDir '*') -DestinationPath $summaryArchive -Force
Write-Host "A74_BATCH_SUMMARY_ZIP=$summaryArchive"
if ($FullArchive) {
    # Archive outside source tree so it cannot include itself.
    $archive = Join-Path $base "$batchId-full.zip"
    $paths = Get-ChildItem -LiteralPath $folder | Where-Object {
        $_.Name -ne 'upload-summary' -and $_.Name -ne 'a74_batch_summary.zip'
    } | Select-Object -ExpandProperty FullName
    Compress-Archive -LiteralPath $paths -DestinationPath $archive -Force
    Write-Host "A74_BATCH_FULL_ZIP=$archive"
}
Write-Host "A74_BATCH_DONE attempted=$($trials.Count)/$($manifest.expected_runs) report_exit=$reportExit strict=NOT_QUALIFIED"
if ($reportExit -ne 0) { throw 'A74_BATCH_INCOMPLETE_OR_INVALID: inspect summary JSON and failed trials' }
