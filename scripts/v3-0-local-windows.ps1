param(
    [string]$RuntimeSource = 'C:\Dev\sandbox-a7-etw',
    [string]$PresentMonExe = '',
    [string]$ResumeControlPath = ''
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$root=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ($env:COMPUTERNAME -ne 'DESKTOP-SAFGO15') { throw 'Baseline host mismatch' }
if ((Get-Process -Id $PID).SessionId -eq 0) { throw 'Session 0 is not interactive' }
if (@(Get-CimInstance Win32_VideoController | ForEach-Object Name) -notcontains 'NVIDIA GeForce GTX 1050 Ti') { throw 'Baseline GPU mismatch' }
Add-Type -AssemblyName System.Windows.Forms
$screen=[System.Windows.Forms.Screen]::PrimaryScreen.Bounds
if ($screen.Width -lt 1920 -or $screen.Height -lt 1080) { throw 'Desktop smaller than 1920x1080' }
if (@(Get-Process -Name 'godot*','PresentMon*' -ErrorAction SilentlyContinue).Count -gt 0) { throw 'Close other Godot/PresentMon processes before starting' }
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$sid=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-559')
if (!$principal.IsInRole($sid) -and !$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'ETW requires Performance Log Users or administrator token' }
& python.exe --version
if ($LASTEXITCODE -ne 0) { throw 'Python unavailable' }
$dll='godot\bin\sandbox_native.windows.template_debug.x86_64.dll'
$api='extension_api.json'
if (!(Test-Path (Join-Path $root $dll)) -or !(Test-Path (Join-Path $root $api))) {
    if ((Test-Path (Join-Path $RuntimeSource $dll)) -and (Test-Path (Join-Path $RuntimeSource $api))) {
        New-Item -ItemType Directory -Force (Join-Path $root 'godot\bin') | Out-Null
        Copy-Item -LiteralPath (Join-Path $RuntimeSource $dll) -Destination (Join-Path $root $dll)
        Copy-Item -LiteralPath (Join-Path $RuntimeSource $api) -Destination (Join-Path $root $api)
    } elseif (Get-Command gh.exe -ErrorAction SilentlyContinue) {
        & gh.exe run download 44522153759 --repo publiomcko-labs/sandbox_v2_mvp_godotVoxel --name a0-build-snapshot --dir $root
        if ($LASTEXITCODE -ne 0) { throw 'Approved native artifact download failed' }
    } else { throw 'Approved A5 DLL/API missing; pass -RuntimeSource or install/authenticate GitHub CLI' }
}
& (Join-Path $root 'scripts\bootstrap-windows.ps1') -RuntimeOnly
if (!$?) { throw 'Pinned runtime bootstrap failed' }
if (!$PresentMonExe) {
    $PresentMonExe=Join-Path $root '.tools\PresentMon-2.6.0-x64.exe'
    if (!(Test-Path $PresentMonExe)) {
        Invoke-WebRequest -Uri 'https://github.com/GameTechDev/PresentMon/releases/download/v2.6.0/PresentMon-2.6.0-x64.exe' -OutFile $PresentMonExe -UseBasicParsing
    }
}
$PresentMonExe=(Resolve-Path -LiteralPath $PresentMonExe).Path
if ((Get-FileHash -LiteralPath $PresentMonExe -Algorithm SHA256).Hash -ne 'B2A706BC6AD475749E3B7E3409263AA1E6906D45BDCF993F6DBC0F660188F1AF') { throw 'PresentMon hash mismatch' }
& (Join-Path $root 'scripts\a7-etw-session-guard.ps1') -Mode Preflight -PresentMonExe $PresentMonExe
$stamp=[DateTimeOffset]::UtcNow.ToString('yyyyMMdd-HHmmss-fff')
$out=Join-Path $root "reports\generated\v3\local-$stamp"
$stage=Join-Path $out 'evidence'
New-Item -ItemType Directory -Force -Path $stage | Out-Null
$runner=Join-Path $root 'scripts\comparison-v1-windows.ps1'
try {
    if ($ResumeControlPath) {
        $source=(Resolve-Path -LiteralPath $ResumeControlPath).Path
        $controlDest=Join-Path (Join-Path $out 'control') 'recovered-control'
        New-Item -ItemType Directory -Force -Path $controlDest | Out-Null
        foreach ($name in @('frames.csv','native.json','godot-stdout.txt','godot-stderr.txt')) {
            Copy-Item -LiteralPath (Join-Path $source $name) -Destination $controlDest
        }
        & python.exe (Join-Path $root 'scripts\v3_0_recover_control.py') $controlDest --contract (Join-Path $root 'benchmarks\comparison-v1.json')
        if ($LASTEXITCODE -ne 0) { throw 'Original control evidence invalid; no additional survey started' }
    } else {
        & $runner -Profile cold -OutputRoot (Join-Path $out 'control')
    }
    & $runner -Profile cold -OutputRoot (Join-Path $out 'traced') -V3Trace -PresentMonExe $PresentMonExe
    $control=@(Get-ChildItem (Join-Path $out 'control') -Directory)
    $traced=@(Get-ChildItem (Join-Path $out 'traced') -Directory)
    if ($control.Count -ne 1 -or $traced.Count -ne 1) { throw 'Unexpected survey count' }
    & python.exe (Join-Path $root 'scripts\v3_0_triage.py') --control $control[0].FullName --traced $traced[0].FullName --out (Join-Path $out 'triage.json')
    if ($LASTEXITCODE -ne 0) { throw 'Trace integrity failed' }
} finally {
    foreach ($arm in @('control','traced')) {
        $armPath=Join-Path $out $arm
        if (Test-Path $armPath) {
            $dest=Join-Path $stage $arm
            New-Item -ItemType Directory -Force $dest | Out-Null
            Get-ChildItem $armPath -Directory | ForEach-Object {
                $d=Join-Path $dest $_.Name
                New-Item -ItemType Directory -Force $d | Out-Null
                Get-ChildItem $_.FullName -File | Where-Object { $_.Extension -in @('.json','.csv','.txt') } | Copy-Item -Destination $d
            }
        }
    }
    $triage=Join-Path $out 'triage.json'
    if (Test-Path $triage) { Copy-Item $triage $stage }
    $zip=Join-Path $out 'v3_0_evidence.zip'
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force
    Write-Host "V3_0_EVIDENCE=$zip"
}
