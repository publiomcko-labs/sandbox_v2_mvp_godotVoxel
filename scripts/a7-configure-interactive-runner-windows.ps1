param(
    [string] $RunnerRoot = 'C:\actios-runner-org1',
    [string] $ServiceName = '',
    [string] $TaskName = 'GitHub-A7-Interactive-Runner',
    [switch] $RestoreService
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ([System.Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) {
    throw 'A7_SETUP_REQUIRES_DESKTOP: run from a signed-in Windows desktop, not GitHub Actions/service Session 0.'
}
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principalCheck = New-Object System.Security.Principal.WindowsPrincipal($identity)
if (-not $principalCheck.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'A7_SETUP_REQUIRES_ADMIN: open PowerShell as Administrator in the signed-in desktop session.'
}
$resolvedRoot = (Resolve-Path -LiteralPath $RunnerRoot).Path
$runCmd = Join-Path $resolvedRoot 'run.cmd'
if (-not (Test-Path -LiteralPath $runCmd) -or -not (Test-Path -LiteralPath (Join-Path $resolvedRoot '.runner'))) {
    throw "A7_SETUP_WRONG_RUNNER_ROOT: $resolvedRoot is not a configured GitHub runner."
}
$services = @(Get-CimInstance Win32_Service | Where-Object {
    $_.Name -like 'actions.runner.*' -and
    $_.PathName -like "*$resolvedRoot*"
})
if ($ServiceName) {
    $services = @($services | Where-Object Name -eq $ServiceName)
}
if ($services.Count -ne 1) {
    throw "A7_SETUP_SERVICE_AMBIGUOUS: found $($services.Count) matching runner services under $resolvedRoot. Pass -ServiceName for the correct service."
}
$service = $services[0]
Write-Host "A7_SETUP_RUNNER_ROOT=$resolvedRoot SERVICE=$($service.Name) USER=$($identity.Name)"

if ($RestoreService) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    Set-Service -Name $service.Name -StartupType Automatic
    Start-Service -Name $service.Name
    Write-Host "A7_RUNNER_SERVICE_RESTORED service=$($service.Name)"
    return
}

# Avoid interrupting any job currently being executed by the service.
$activeWorkers = @(Get-CimInstance Win32_Process -Filter "Name='Runner.Worker.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -like "$resolvedRoot*" })
if ($activeWorkers.Count -gt 0) {
    throw "A7_SETUP_RUNNER_BUSY: $($activeWorkers.Count) jobs active; refusing to interrupt them."
}
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds 0) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
$taskPrincipal = New-ScheduledTaskPrincipal -UserId $identity.Name -LogonType Interactive -RunLevel Limited
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $identity.Name
$commandArgs = '/d /c ""' + $runCmd + '""'
$action = New-ScheduledTaskAction -Execute "$env:ComSpec" -Argument $commandArgs -WorkingDirectory $resolvedRoot
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $taskPrincipal -Settings $settings -Force | Out-Null

try {
    Stop-Service -Name $service.Name -ErrorAction Stop
    Set-Service -Name $service.Name -StartupType Manual
    Start-ScheduledTask -TaskName $TaskName
} catch {
    Write-Warning 'A7_SETUP_FAILED: attempting service restore'
    Set-Service -Name $service.Name -StartupType Automatic
    Start-Service -Name $service.Name -ErrorAction SilentlyContinue
    throw
}
Write-Host "A7_INTERACTIVE_RUNNER_TASK_STARTED task=$TaskName"
Write-Host 'A7_NEXT_STEP: rerun the failed GitHub graphical A/B job; leave the user logged in with an active 1920x1080 desktop.'
Write-Host "A7_ROLLBACK: .\scripts\a7-configure-interactive-runner-windows.ps1 -RunnerRoot '$resolvedRoot' -RestoreService"
