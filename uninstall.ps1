# uninstall.ps1 - TD Dialog Restore
#
# Removes everything the installer created for the current user:
#   * stops the running watcher
#   * removes the Startup shortcut (enabled or disabled)
#   * deletes %LOCALAPPDATA%\TDDialogRestore (script + restore.log)
#
# Nothing else is touched: no registry keys, no TouchDesigner files, no project files.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
#
# Options:
#   -KeepFiles          remove the autostart entry and stop it, but keep the script on disk

[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'TDDialogRestore'),
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Stop'
$AppName    = 'TD Dialog Restore'
$ScriptName = 'td-dialog-restore.ps1'
$startupDir = [Environment]::GetFolderPath('Startup')
$lnk        = Join-Path $startupDir "$AppName.lnk"
$lnkOff     = "$lnk.disabled"

Write-Host ''
Write-Host "$AppName - uninstaller" -ForegroundColor Cyan
Write-Host ''

# ---------------------------------------------------------------- stop it
$running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
             Where-Object { $_.CommandLine -like "*$ScriptName*" })
foreach ($p in $running) {
    Write-Host "  stopping watcher pid $($p.ProcessId)"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
}
if ($running.Count -eq 0) { Write-Host '  watcher was not running' }
Start-Sleep -Milliseconds 400

# ---------------------------------------------------------------- autostart entries
$removed = 0
foreach ($path in @($lnk, $lnkOff)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
        Write-Host "  removed $path"
        $removed++
    }
}
if ($removed -eq 0) { Write-Host '  no Startup entry found' }

# ---------------------------------------------------------------- files
if ($KeepFiles) {
    Write-Host "  kept $InstallDir (-KeepFiles)"
} elseif (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host "  removed $InstallDir"
} else {
    Write-Host "  $InstallDir not present"
}

# ---------------------------------------------------------------- verify
$left = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
          Where-Object { $_.CommandLine -like "*$ScriptName*" })
$lnkLeft = (Test-Path -LiteralPath $lnk) -or (Test-Path -LiteralPath $lnkOff)

Write-Host ''
if ($left.Count -eq 0 -and -not $lnkLeft) {
    Write-Host 'Uninstalled. TouchDesigner dialogs are back to their normal (broken) behaviour.' -ForegroundColor Green
    exit 0
}
Write-Host 'WARNING: something is still present:' -ForegroundColor Yellow
if ($left.Count -gt 0)   { Write-Host "  running processes: $(($left.ProcessId) -join ', ')" }
if ($lnkLeft)            { Write-Host "  startup entry: $lnk" }
exit 1
