# toggle.ps1 - TD Dialog Restore
#
# Turns the fix off or on without uninstalling anything.
#
#   .\toggle.ps1 off     stop it now and disable the logon entry (stays off after reboot)
#   .\toggle.ps1 on      re-enable the logon entry and start it now
#   .\toggle.ps1 status  same output as status.ps1
#
# "off" is reversible: nothing is deleted, the startup shortcut is only renamed to
# "TD Dialog Restore.lnk.disabled". "on" renames it back.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\toggle.ps1 off

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('on', 'off', 'status')]
    [string]$Action = 'status',
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'TDDialogRestore')
)

$ErrorActionPreference = 'Stop'
$AppName    = 'TD Dialog Restore'
$ScriptName = 'td-dialog-restore.ps1'
$startupDir = [Environment]::GetFolderPath('Startup')
$lnk        = Join-Path $startupDir "$AppName.lnk"
$lnkOff     = "$lnk.disabled"
$target     = Join-Path $InstallDir $ScriptName

function Get-Watchers {
    @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
      Where-Object { $_.CommandLine -like "*$ScriptName*" })
}

if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
    Write-Host 'ERROR: Windows PowerShell 5.1 or newer is required.' -ForegroundColor Red; exit 1
}

switch ($Action) {

    'status' {
        & (Join-Path $PSScriptRoot 'status.ps1') -InstallDir $InstallDir
        exit 0
    }

    'off' {
        $pids = @(Get-Watchers | ForEach-Object { $_.ProcessId })
        if ($pids.Count -gt 0) {
            foreach ($procId in $pids) { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 400
            Write-Host "  stopped $($pids.Count) watcher process(es): $(($pids) -join ', ')"
        } else {
            Write-Host '  no watcher was running'
        }

        if (Test-Path -LiteralPath $lnk) {
            if (Test-Path -LiteralPath $lnkOff) { Remove-Item -LiteralPath $lnkOff -Force }
            Rename-Item -LiteralPath $lnk -NewName "$AppName.lnk.disabled" -Force
            Write-Host '  logon entry disabled (renamed to "TD Dialog Restore.lnk.disabled")'
        } elseif (Test-Path -LiteralPath $lnkOff) {
            Write-Host '  logon entry was already disabled'
        } else {
            Write-Host '  no logon entry present'
        }

        Write-Host ''
        Write-Host 'TD Dialog Restore is OFF. Turn it back on with: .\toggle.ps1 on' -ForegroundColor Yellow
        Write-Host ''
        exit 0
    }

    'on' {
        if (Test-Path -LiteralPath $lnkOff) {
            if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
            Rename-Item -LiteralPath $lnkOff -NewName "$AppName.lnk" -Force
            Write-Host '  logon entry re-enabled'
        } elseif (Test-Path -LiteralPath $lnk) {
            Write-Host '  logon entry already enabled'
        } else {
            Write-Host 'ERROR: no installation found (no logon entry). Run .\install.ps1 first.' -ForegroundColor Red
            exit 1
        }

        if (-not (Test-Path -LiteralPath $target)) {
            Write-Host "ERROR: watcher missing at $target - run .\install.ps1 again." -ForegroundColor Red
            exit 1
        }

        if (@(Get-Watchers).Count -eq 0) {
            Start-Process -FilePath (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$target`"", '-Log') `
                -WindowStyle Hidden | Out-Null
            Start-Sleep -Milliseconds 1500
            $now = @(Get-Watchers)
            if ($now.Count -ne 1) {
                Write-Host "ERROR: expected 1 watcher, found $($now.Count)." -ForegroundColor Red
                exit 1
            }
            Write-Host "  started, pid $($now[0].ProcessId)"

            $me = Get-Process -Id $now[0].ProcessId
            $explorer = Get-Process explorer -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($explorer -and $me.SessionId -ne $explorer.SessionId) {
                Write-Host "  WARNING: started in session $($me.SessionId), desktop is session $($explorer.SessionId) -" -ForegroundColor Yellow
                Write-Host '           it will not see your TouchDesigner windows. Run toggle.ps1 from your desktop.' -ForegroundColor Yellow
            }
        } else {
            Write-Host '  a watcher was already running'
        }

        Write-Host ''
        Write-Host 'TD Dialog Restore is ON.' -ForegroundColor Green
        Write-Host ''
        exit 0
    }
}
