# status.ps1 - TD Dialog Restore
#
# Shows what is installed and what is running. Read-only: changes nothing.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\status.ps1

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'TDDialogRestore')
)

$ErrorActionPreference = 'SilentlyContinue'
$AppName    = 'TD Dialog Restore'
$ScriptName = 'td-dialog-restore.ps1'

Write-Host ''
Write-Host "$AppName - status" -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- files
$target = Join-Path $InstallDir $ScriptName
if (Test-Path -LiteralPath $target) {
    $ver = (Select-String -LiteralPath $target -Pattern "Version\s*=\s*'([^']+)'" |
            Select-Object -First 1).Matches.Groups[1].Value
    $size = (Get-Item -LiteralPath $target).Length
    Write-Host "  watcher    $target  (v$ver, $size bytes)"
} else {
    Write-Host "  watcher    NOT INSTALLED at $target" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- logon entry
$startupDir = [Environment]::GetFolderPath('Startup')
$lnk        = Join-Path $startupDir "$AppName.lnk"
$lnkOff     = "$lnk.disabled"

if (Test-Path -LiteralPath $lnk) {
    $sc = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    Write-Host "  logon      enabled  -> $($sc.Arguments)"
} elseif (Test-Path -LiteralPath $lnkOff) {
    Write-Host '  logon      DISABLED (toggle.ps1 off) - will not run after reboot' -ForegroundColor Yellow
} else {
    Write-Host '  logon      no entry (not installed, or installed with -NoStartup)' -ForegroundColor Yellow
}

# ---------------------------------------------------------------- processes
$running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
             Where-Object { $_.CommandLine -like "*$ScriptName*" })
if ($running.Count -eq 1) {
    $p = Get-Process -Id $running[0].ProcessId
    $mb = [math]::Round($p.WorkingSet64 / 1MB, 1)
    Write-Host "  running    yes - pid $($running[0].ProcessId), $mb MB working set"
} elseif ($running.Count -eq 0) {
    Write-Host '  running    no' -ForegroundColor Yellow
} else {
    Write-Host "  running    $($running.Count) instances (should be 1) - pids: $(($running.ProcessId) -join ', ')" -ForegroundColor Yellow
}

$td = @(Get-Process touchdesigner)
Write-Host ("  TouchDesigner: " + $(if ($td.Count -eq 0) { 'not running' } else { "$($td.Count) process(es), pid $(($td.Id) -join ', ')" }))

# ---------------------------------------------------------------- last events
$logPath = Join-Path $InstallDir 'restore.log'
if (Test-Path -LiteralPath $logPath) {
    Write-Host ''
    Write-Host '  last restores (restore.log):'
    Get-Content -LiteralPath $logPath -Tail 5 | ForEach-Object { Write-Host "    $_" }
}

Write-Host ''
