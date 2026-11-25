param(
    [ValidateSet('shoreline_180s','straight_18mps_600s','out_and_back_18mps_300s')]
    [string] $Scenario = 'shoreline_180s',
    [ValidateRange(1,5)] [int] $Repeats = 2,
    [ValidateRange(30,180)] [int] $Duration = 60,
    [ValidateRange(10,120)] [int] $Warmup = 45,
    [int] $Seed = 20261119
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runner = Join-Path $root 'scripts/a7-run-windows.ps1'
$logical = [Environment]::ProcessorCount
$medium = [Math]::Max(2, [Math]::Min(16, [int][Math]::Floor($logical / 2.0)))
$high = [Math]::Max(2, [Math]::Min(24, $logical - 4))
$profiles = @(
    [pscustomobject]@{name='vsync_on_auto'; vsync_off=$false; voxel_threads=0},
    [pscustomobject]@{name='vsync_off_auto'; vsync_off=$true; voxel_threads=0},
    [pscustomobject]@{name=("vsync_off_t$medium"); vsync_off=$true; voxel_threads=$medium}
)
if ($high -gt $medium) {
    $profiles += [pscustomobject]@{name=("vsync_off_t$high"); vsync_off=$true; voxel_threads=$high}
}
$campaign = Join-Path $root ("reports/generated/a7-resources/campaign-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID")
New-Item -ItemType Directory -Path $campaign -Force | Out-Null
$manifest = [ordered]@{
    schema='a7_resource_ab_v1'
    base='A5 CPU16 GL Compatibility'
    type='EXPERIMENT_ONLY_NOT_MVP_ACCEPTANCE'
    git_sha=(& git -C $root rev-parse HEAD).Trim()
    logical_processors=$logical
    scenario=$Scenario; repeats=$Repeats; duration_s=$Duration; warmup_s=$Warmup; seed=$Seed
    profiles=@($profiles)
    warning='VSync OFF may increase power/heat and tearing. More workers may worsen main-thread contention.'
}
($manifest | ConvertTo-Json -Depth 8) |
    Set-Content -LiteralPath (Join-Path $campaign 'resource_manifest.json') -Encoding UTF8

$previous = $env:A7_CAMPAIGN_DIR
$rows = New-Object 'System.Collections.Generic.List[object]'
try {
    for ($repeat = 1; $repeat -le $Repeats; $repeat++) {
        $ordered = @($profiles)
        if ($repeat % 2 -eq 0) { [Array]::Reverse($ordered) }
        foreach ($profile in $ordered) {
            $name = $profile.name
            $target = Join-Path $campaign ("{0}_rep{1:D2}" -f $name, $repeat)
            $env:A7_CAMPAIGN_DIR = $target
            Write-Host "A7_RESOURCE_AB_START profile=$name repeat=$repeat/$Repeats"
            $params = @{
                Scenario=$Scenario; Seeds=@($Seed); Duration=$Duration; Warmup=$Warmup
                VsyncOff=[bool]$profile.vsync_off
                VoxelThreads=[int]$profile.voxel_threads
                ResourceTelemetry=$true
            }
            & $runner @params
            if (-not $?) { throw "A7_RESOURCE_AB_RUNNER_FAIL profile=$name rep=$repeat" }
            $resultFile = Get-ChildItem -LiteralPath $target -Recurse -File -Filter 'a7_route.json' |
                Select-Object -First 1
            if ($null -eq $resultFile) { throw "A7_RESOURCE_AB_MISSING_ROUTE profile=$name" }
            $d = Get-Content -LiteralPath $resultFile.FullName -Raw | ConvertFrom-Json
            if ($d.frame_count -lt 100 -or $d.seed -ne $Seed -or $d.capture -ne $false) {
                throw "A7_RESOURCE_AB_INVALID_REPORT profile=$name"
            }
            $samplePath = Join-Path $resultFile.DirectoryName 'a7_process_resources.json'
            if (-not (Test-Path -LiteralPath $samplePath)) {
                throw "A7_RESOURCE_AB_MISSING_RESOURCE_SAMPLES profile=$name"
            }
            # The scalar summary avoids PowerShell 5.1 ConvertFrom-Json array
            # unrolling differences that falsely reported TOO_FEW_SAMPLES.
            $resourceSummaryPath = Join-Path $resultFile.DirectoryName 'a7_process_resource_summary.json'
            if (-not (Test-Path -LiteralPath $resourceSummaryPath)) {
                throw "A7_RESOURCE_AB_MISSING_SUMMARY profile=$name path=$resourceSummaryPath"
            }
            $resourceSummary = Get-Content -LiteralPath $resourceSummaryPath -Raw | ConvertFrom-Json
            if ($resourceSummary.schema -ne 'a7_process_resource_summary_v1' -or
                $resourceSummary.sample_count -lt 3) {
                throw "A7_RESOURCE_AB_TOO_FEW_SAMPLES profile=$name count=$($resourceSummary.sample_count) path=$resourceSummaryPath"
            }
            $cpuAvg = [double]$resourceSummary.cpu_pct_machine_avg
            $coresAvg = [double]$resourceSummary.cpu_equivalent_cores_avg
            $memoryPeak = [double]$resourceSummary.working_set_peak_mb
            $row = [pscustomobject]@{
                profile=$name; repeat=$repeat; scenario=$Scenario; seed=$Seed
                vsync_off_requested=[bool]$profile.vsync_off
                vsync_mode_actual=$d.vsync_mode_actual
                voxel_threads_requested=[int]$profile.voxel_threads
                voxel_threads_actual=$d.voxel_threads_actual
                frame_count=$d.frame_count
                frame_start_p50_ms=$d.frame_start_p50_ms
                frame_start_p99_ms=$d.frame_start_p99_ms
                frame_start_max_ms=$d.frame_start_max_ms
                intervals_over_20_ms=$d.frame_intervals_over_20_ms
                intervals_over_33_ms=$d.frame_intervals_over_33_ms
                gpu_render_p99_ms=$d.viewport_render_gpu_p99_ms
                cpu_render_p99_ms=$d.viewport_render_cpu_p99_ms
                min_radial_probe_hits=$d.min_radial_probe_hits_8
                process_cpu_pct_machine_avg=[Math]::Round([double]$cpuAvg,2)
                process_cpu_cores_avg=[Math]::Round([double]$coresAvg,2)
                process_working_set_peak_mb=[Math]::Round([double]$memoryPeak,1)
                report_dir=$target
            }
            $rows.Add($row)
            Write-Host ("A7_RESOURCE_AB_RECORDED {0} p99={1}ms cpu={2}% threads={3} probes={4}/8" -f $name,$row.frame_start_p99_ms,$row.process_cpu_pct_machine_avg,$row.voxel_threads_actual,$row.min_radial_probe_hits)
        }
    }
    $rows.ToArray() | Export-Csv -LiteralPath (Join-Path $campaign 'resource_comparison.csv') -NoTypeInformation -Encoding UTF8
    $rows.ToArray() | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $campaign 'resource_comparison.json') -Encoding UTF8
    Write-Host "A7_RESOURCE_AB_DONE=$campaign"
    Write-Host 'A7_RESOURCE_AB_NOT_ACCEPTANCE: CPU load and frame-start stats do not prove total CPU+GPU+presentation or 130m pixel coverage.'
} finally {
    $env:A7_CAMPAIGN_DIR = $previous
}
