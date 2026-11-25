$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runner = Join-Path $root 'scripts/a7-run-windows.ps1'
foreach ($scenario in @('stationary_180s', 'edit_idle_100')) {
    $env:A7_CAMPAIGN_DIR = Join-Path $root "reports/generated/a7-ci/$scenario"
    & $runner -CiSmoke -Scenario $scenario -Seeds @(20261119)
    if (-not $?) { throw "A7 smoke integration failed $scenario" }
    $matrixPath = Join-Path $env:A7_CAMPAIGN_DIR 'a7_acceptance_matrix.json'
    if (-not (Test-Path $matrixPath)) { throw "A7 smoke missing matrix $scenario" }
    $m = Get-Content -LiteralPath $matrixPath -Raw | ConvertFrom-Json
    if ($m.schema -ne 'a7_acceptance_matrix_v1' -or -not $m.complete -or
        $m.runs_reported -ne 1 -or $m.overall -ne 'NOT_QUALIFIED' -or
        $m.automatic_acceptance -ne $false -or
        $m.gates.'PERF-60'.status -ne 'NOT_QUALIFIED' -or
        $m.gates.'VIEW-130'.status -ne 'NOT_QUALIFIED' -or
        $m.gates.'EDIT-100'.status -ne 'NOT_QUALIFIED') {
        throw "A7 smoke illegally qualified acceptance without pixels: $scenario"
    }
    if ($scenario -eq 'edit_idle_100') {
        $editReport = Get-ChildItem -LiteralPath $env:A7_CAMPAIGN_DIR -Filter 'a7_edits.json' -Recurse -File |
            Select-Object -First 1
        if ($null -eq $editReport) { throw 'A7 expected real headless edit report' }
        $ed = Get-Content -LiteralPath $editReport.FullName -Raw | ConvertFrom-Json
        if ($ed.accepted_count -lt 1 -or $ed.sdf_changed_count -lt 1) {
            throw "A7_EDIT_SMOKE_NO_ACTUAL_EDITS accepted=$($ed.accepted_count) changed=$($ed.sdf_changed_count)"
        }
    }
    Write-Host "A7_HEADLESS_CONFIG_PASS scenario=$scenario report=$matrixPath"
}
Write-Host 'A7_CI_PASS_WITH_UNQUALIFIED_GRAPHICS no strict gate auto-approved'
