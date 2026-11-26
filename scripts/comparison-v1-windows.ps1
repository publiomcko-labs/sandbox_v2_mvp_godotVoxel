param(
    [ValidateSet('cold','warm')][string]$Profile = 'cold',
    [string]$OutputRoot = '',
    [string]$StateRoot = '',
    [switch]$HeadlessDiagnostic,
    [switch]$V3Trace,
    [string]$PresentMonExe = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = Join-Path $root '.tools\godot.exe'
$project = Join-Path $root 'godot'
$dll = Join-Path $project 'bin\sandbox_native.windows.template_debug.x86_64.dll'
if (!(Test-Path -LiteralPath $exe) -or !(Test-Path -LiteralPath $dll)) {
    throw 'Godot/Voxel Tools or native DLL missing; restore approved binary with scripts/bootstrap-windows.ps1 -RuntimeOnly.'
}
if ((Get-Process -Id $PID).SessionId -eq 0 -and !$HeadlessDiagnostic) {
    throw 'Interactive comparison requires desktop Windows session, not Session 0 Actions service.'
}
if (!$OutputRoot) { $OutputRoot = Join-Path $root 'reports\comparison-v1' }
$stamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
$run = Join-Path $OutputRoot "godot-$Profile-$stamp"
New-Item -ItemType Directory -Force -Path $run | Out-Null
$runState = Join-Path $run 'world'
New-Item -ItemType Directory -Force -Path $runState | Out-Null
if ($Profile -eq 'warm') {
    if (!$StateRoot) { throw 'Warm profile requires -StateRoot from a previous cold run.' }
    if (!(Test-Path (Join-Path $StateRoot 'terrain.sqlite'))) { throw "Warm save missing: $StateRoot" }
    Copy-Item -Path (Join-Path $StateRoot '*') -Destination $runState -Recurse -Force
} elseif ($StateRoot) {
    throw 'Cold profile always creates a new isolated state. Omit -StateRoot.'
}
$env:A3_SAVE_PATH = Join-Path $runState 'terrain.sqlite'
$env:A4_ROCK_STATE_PATH = Join-Path $runState 'rocks.json'
$env:COMPARISON_V1_CSV = Join-Path $run 'frames.csv'
$env:COMPARISON_V1_NATIVE_JSON = Join-Path $run 'native.json'
if ($V3Trace) { $env:V3_0_TRACE = Join-Path $run 'v3-trace.csv' } else { Remove-Item Env:V3_0_TRACE -ErrorAction SilentlyContinue }
if ($PresentMonExe -and (!$V3Trace -or $HeadlessDiagnostic)) { throw 'ETW requires interactive V3Trace' }
if ($PresentMonExe) {
    $PresentMonExe = (Resolve-Path -LiteralPath $PresentMonExe).Path
    if ((Get-FileHash -LiteralPath $PresentMonExe -Algorithm SHA256).Hash -ne 'B2A706BC6AD475749E3B7E3409263AA1E6906D45BDCF993F6DBC0F660188F1AF') { throw 'PresentMon hash mismatch' }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $perfSid = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-559')
    if (!$principal.IsInRole($perfSid) -and !$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'ETW requires Performance Log Users or administrator token; no elevation attempted' }
    if (@(Get-Process -Name 'PresentMon*' -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Another PresentMon process is active' }
    & (Join-Path $root 'scripts\a7-etw-session-guard.ps1') -Mode Preflight -PresentMonExe $PresentMonExe
}
$cache = Join-Path $project '.godot'
New-Item -ItemType Directory -Force -Path $cache | Out-Null
[System.IO.File]::WriteAllText((Join-Path $cache 'extension_list.cfg'), "res://sandbox_native.gdextension" + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
$args = @()
if ($HeadlessDiagnostic) { $args += '--headless' }
$args += @('--path', ('"' + $project + '"'), '--script', 'res://tests/comparison_v1.gd')
Write-Host "COMPARISON_V1_GODOT session=$run headless=$HeadlessDiagnostic"
$proc = $null
$pm = $null
$session = ''
$pmExit = $null
$pmTimedOut = $false
$pmErr = Join-Path $run 'presentmon-stderr.txt'
$pmCsv = Join-Path $run 'presentmon.csv'
try {
    $proc = Start-Process -FilePath $exe -ArgumentList $args -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $run 'godot-stdout.txt') -RedirectStandardError (Join-Path $run 'godot-stderr.txt')
    # Windows PowerShell Start-Process -PassThru may return a Process
    # without a retained native handle. Open it before the process exits.
    $null = $proc.Handle
    if ($PresentMonExe) {
        $session = 'A7_' + $proc.Id + '_' + [guid]::NewGuid().ToString('N')
        $pmArgs = '--session_name ' + $session + ' --process_id ' + $proc.Id + ' --v2_metrics --date_time --output_file "' + $pmCsv + '" --no_console_stats --terminate_on_proc_exit --terminate_after_timed --timed 85'
        $pm = Start-Process -FilePath $PresentMonExe -ArgumentList $pmArgs -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $run 'presentmon-stdout.txt') -RedirectStandardError $pmErr
        $null = $pm.Handle
    }
    if (!$proc.WaitForExit(150000)) { throw 'Survey process timed out' }
    $proc.WaitForExit()
    $gameExit = $proc.ExitCode
    if ($null -eq $gameExit) { throw 'Comparison exit code unavailable (not a verified process failure); inspect preserved raw output' }
    if ($gameExit -ne 0) { throw "Comparison failed exit=$gameExit" }
} finally {
    if ($null -ne $proc -and !$proc.HasExited) { $proc.Kill(); $proc.WaitForExit() }
    if ($null -ne $pm) {
        if (!$pm.WaitForExit(25000)) { $pmTimedOut = $true; $pm.Kill(); $pm.WaitForExit() }
        $pm.WaitForExit()
        $pmExit = $pm.ExitCode
    }
    if ($PresentMonExe) {
        $err = if (Test-Path -LiteralPath $pmErr) { Get-Content -LiteralPath $pmErr -Raw } else { '' }
        $lostEvents = [regex]::Match([string]$err, '(?i)warning:\s*(\d+)\s+ETW events were lost')
        $lostBuffers = [regex]::Match([string]$err, '(?i)warning:\s*(\d+)\s+ETW buffers were lost')
        $bytes = if (Test-Path -LiteralPath $pmCsv) { (Get-Item -LiteralPath $pmCsv).Length } else { 0 }
        $status = [ordered]@{ session=$session; pid=if($null -ne $proc){$proc.Id}else{$null}; exit_code=$pmExit; timeout=$pmTimedOut; csv_bytes=$bytes; etw_events_lost=if($lostEvents.Success){[long]$lostEvents.Groups[1].Value}else{$null}; etw_buffers_lost=if($lostBuffers.Success){[long]$lostBuffers.Groups[1].Value}else{$null}; host_utc_offset_s=[TimeZoneInfo]::Local.GetUtcOffset([DateTime]::Now).TotalSeconds; status='RAW_UNVALIDATED' }
        $status | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'presentmon-status.json') -Encoding UTF8
        if ($session) { & (Join-Path $root 'scripts\a7-etw-session-guard.ps1') -Mode Postflight -PresentMonExe $PresentMonExe -SessionName $session }
    }
    Remove-Item Env:V3_0_TRACE -ErrorAction SilentlyContinue
}
$native = Get-Content -LiteralPath $env:COMPARISON_V1_NATIVE_JSON -Raw | ConvertFrom-Json
$gpu = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name) / $($_.DriverVersion)" })
$cpu = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$meta = [ordered]@{
    engine = 'godot_voxel_tools'
    scenario_id = 'survey46-six-edits-v1'
    render_mode = if ($HeadlessDiagnostic) { 'cpu_headless' } else { 'interactive' }
    profile = $Profile
    git_sha = (& git -C $root rev-parse HEAD).Trim()
    cpu = $cpu
    gpu = $gpu
    hostname = $env:COMPUTERNAME
    resolution = '1920x1080'
    backend = 'Godot GL Compatibility'
    run_id = (Split-Path $run -Leaf)
    functional_proxies = $native
    v3_trace = [bool]$V3Trace
    presentmon_requested = [bool]$PresentMonExe
    godot_sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash
    native_sha256 = (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash
}
$metadata = Join-Path $run 'metadata.json'
$meta | ConvertTo-Json -Depth 9 | Set-Content -LiteralPath $metadata -Encoding UTF8
$reducer = Join-Path $root 'scripts\comparison-v1-reduce.py'
$contract = Join-Path $root 'benchmarks\comparison-v1.json'
$result = Join-Path $run 'comparison-v1-result.json'
& python.exe $reducer --csv $env:COMPARISON_V1_CSV --contract $contract --metadata $metadata --out $result
if ($LASTEXITCODE -ne 0) { throw 'Comparison reducer rejected Godot data' }
Write-Host "COMPARISON_V1_DONE report=$run state=$runState"
