param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('Preflight','Postflight')]
    [string] $Mode,
    [Parameter(Mandatory=$true)]
    [string] $PresentMonExe,
    [string] $SessionName = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not (Test-Path -LiteralPath $PresentMonExe -PathType Leaf)) {
    throw 'A7_ETW_GUARD_PRESENTMON_NOT_FOUND'
}
$collector = (Resolve-Path -LiteralPath $PresentMonExe).Path
if ($Mode -eq 'Postflight' -and $SessionName -notmatch '^A7_[0-9]+_[a-fA-F0-9]{32}$') {
    throw 'A7_ETW_GUARD_INVALID_OWNED_SESSION'
}

function Get-A7EtwSessions {
    # Query the live Windows ETW registry; do not rely on process count alone.
    # Exact A7 names contain the Godot PID and a 32-digit random session GUID.
    # Only these sessions may ever be stopped by this guard.
    $lines = @(& logman.exe query -ets 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "A7_ETW_GUARD_LOGMAN_QUERY_FAILED exit=$LASTEXITCODE"
    }
    $names = @(
        foreach ($line in $lines) {
            if ([string]$line -match '^\s*(A7_[0-9]+_[a-fA-F0-9]{32})(?=\s|$)') {
                $Matches[1]
            }
        }
    )
    return @($names | Sort-Object -Unique)
}

$active = @(Get-A7EtwSessions)
$targets = if ($Mode -eq 'Preflight') {
    @($active)
} else {
    @($active | Where-Object { $_ -eq $SessionName })
}
if ($targets.Count -eq 0) {
    Write-Host "A7_ETW_GUARD_CLEAN mode=$Mode active_a7=$($active.Count)"
    return
}

# Never terminate ETW while a PresentMon collector is active. An A7 session
# could belong to a concurrent legitimate capture; require manual resolution.
$collectors = @(Get-Process -Name PresentMon -ErrorAction SilentlyContinue)
if ($collectors.Count -gt 0) {
    throw "A7_ETW_GUARD_ACTIVE_COLLECTOR mode=$Mode sessions=$($targets -join ',') pids=$($collectors.Id -join ',')"
}

foreach ($session in $targets) {
    Write-Warning "A7_ETW_GUARD_RECOVERING mode=$Mode session=$session no_active_presentmon_process"
    $stopResult = @(& $collector --session_name $session --terminate_existing_session 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "A7_ETW_GUARD_STOP_FAILED session=$session exit=$LASTEXITCODE detail=$($stopResult -join ' ')"
    }
}
$remaining = @(Get-A7EtwSessions)
foreach ($session in $targets) {
    if ($remaining -contains $session) {
        throw "A7_ETW_GUARD_SESSION_PERSISTED session=$session"
    }
}
Write-Host "A7_ETW_GUARD_RECOVERED mode=$Mode count=$($targets.Count)"
