# install.ps1 - TD Dialog Restore
#
# Installs the watcher for the current user, with no admin rights:
#   * copies src\td-dialog-restore.ps1 to %LOCALAPPDATA%\TDDialogRestore\
#   * adds a Startup shortcut so it runs at every logon (hidden window)
#   * starts it now, and verifies that exactly one instance is running
#
# Usage (from the folder you downloaded/cloned):
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#
# Options:
#   -InstallDir <path>  where to put the script     (default %LOCALAPPDATA%\TDDialogRestore)
#   -NoStartup          do not add the logon entry  (start it yourself / run once)
#   -NoStart            do not start it now         (installs the logon entry only)
#   -NoLog              do not pass -Log to the watcher (no restore.log)
#
# Uninstall:  .\uninstall.ps1
# Toggle off: .\toggle.ps1 off

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'TDDialogRestore'),
    [switch]$NoStartup,
    [switch]$NoStart,
    [switch]$NoLog
)

$ErrorActionPreference = 'Stop'
$AppName   = 'TD Dialog Restore'
$RawBase   = 'https://raw.githubusercontent.com/DIY23/td-dialog-restore/main'
$ScriptName = 'td-dialog-restore.ps1'

function Write-Step($msg) { Write-Host "  $msg" }
function Fail($msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

Write-Host ''
Write-Host "$AppName - installer" -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- prerequisites
if ($env:OS -ne 'Windows_NT') { Fail 'this tool only runs on Windows.' }
if ($PSVersionTable.PSVersion.Major -lt 5) { Fail "PowerShell 5.1 or newer required (found $($PSVersionTable.PSVersion))." }

# ---------------------------------------------------------------- locate source
$src = Join-Path $PSScriptRoot "src\$ScriptName"
if (-not (Test-Path -LiteralPath $src)) {
    # run from a lone downloaded install.ps1: fetch the watcher from the repo
    $tmp = Join-Path $env:TEMP "td-dialog-restore-$([guid]::NewGuid().ToString('N').Substring(0,8)).ps1"
    Write-Step "source not found next to this script; downloading $RawBase/$ScriptName"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri "$RawBase/$ScriptName" -OutFile $tmp
    } catch {
        Fail "could not download the watcher: $($_.Exception.Message)"
    }
    $src = $tmp
}
Write-Step "source: $src"

# ---------------------------------------------------------------- stop old copies
$existing = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like "*$ScriptName*" })
foreach ($p in $existing) {
    Write-Step "stopping previous instance (pid $($p.ProcessId))"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
if ($existing.Count -gt 0) { Start-Sleep -Milliseconds 500 }

# ---------------------------------------------------------------- copy the script
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$target = Join-Path $InstallDir $ScriptName
Copy-Item -LiteralPath $src -Destination $target -Force
if ($src -like "$env:TEMP*") { Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue }
Write-Step "installed: $target"

# ---------------------------------------------------------------- logon entry
$startupDir = [Environment]::GetFolderPath('Startup')
$lnk        = Join-Path $startupDir "$AppName.lnk"
$lnkOff     = "$lnk.disabled"

if (-not $NoStartup) {
    $args = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`""
    if (-not $NoLog) { $args += ' -Log' }

    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath       = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $sc.Arguments        = $args
    $sc.WorkingDirectory = $InstallDir
    $sc.WindowStyle      = 7          # minimised: no console flash at logon
    $sc.Description      = "$AppName - un-maximises TouchDesigner dialogs"
    $tdExe = 'C:\Program Files\Derivative\TouchDesigner\bin\touchdesigner.exe'
    if (Test-Path -LiteralPath $tdExe) { $sc.IconLocation = "$tdExe,0" }
    $sc.Save()
    if (Test-Path -LiteralPath $lnkOff) { Remove-Item -LiteralPath $lnkOff -Force }
    Write-Step "logon entry: $lnk"
} else {
    Write-Step 'logon entry: skipped (-NoStartup)'
}

# ---------------------------------------------------------------- start it now
if (-not $NoStart) {
    $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$target`"")
    if (-not $NoLog) { $psArgs += '-Log' }
    Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                  -ArgumentList $psArgs -WindowStyle Hidden | Out-Null
    Start-Sleep -Milliseconds 1500

    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like "*$ScriptName*" })
    if ($running.Count -ne 1) { Fail "expected exactly 1 watcher process, found $($running.Count)." }
    Write-Step "running: pid $($running[0].ProcessId)"

    # a watcher started from a service/SSH session cannot see the desktop's windows
    $me       = Get-Process -Id $running[0].ProcessId
    $explorer = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($explorer -and $me.SessionId -ne $explorer.SessionId) {
        Write-Host ''
        Write-Host "WARNING: the watcher started in session $($me.SessionId), but your desktop is session $($explorer.SessionId)." -ForegroundColor Yellow
        Write-Host '         It cannot see TouchDesigner windows there. Run this installer from your own' -ForegroundColor Yellow
        Write-Host '         desktop session (not over SSH or from a service) so it starts where you work.' -ForegroundColor Yellow
        Write-Host '         The logon entry is unaffected: it will run in the right session next time you log on.' -ForegroundColor Yellow
    }
} else {
    Write-Step 'start: skipped (-NoStart)'
}

# ---------------------------------------------------------------- report
Write-Host ''
Write-Host 'Installed.' -ForegroundColor Green
Write-Host "  watcher      $target"
if (-not $NoStartup) { Write-Host "  logon entry  $lnk" }
Write-Host "  task manager: look for powershell.exe running $ScriptName"
Write-Host ''
Write-Host '  Check it:    .\status.ps1        (or open a TouchDesigner dialog with Tab)'
Write-Host '  Turn off:    .\toggle.ps1 off    (stays off after reboot, install kept)'
Write-Host '  Turn on:     .\toggle.ps1 on'
Write-Host '  Uninstall:   .\uninstall.ps1'
Write-Host ''
