# td-dialog-restore.ps1                                                     v1.0.1
#
# Un-maximises TouchDesigner floating dialogs the instant they are shown.
#
# Why: on some machines (notably laptops/handhelds with a rotated panel, where
# GetDpiForSystem() != the monitor DPI) TouchDesigner creates its floating dialogs --
# OP Create Dialog (Tab), colour picker, Window Placement, ... -- in a MAXIMIZED window
# state. They then cover the whole monitor with black padding and their resize edge is
# off-screen. Dragging the title bar restores one, but TouchDesigner never remembers it.
#
# This watcher fixes each dialog as it appears, however TouchDesigner was started.
# It is event-driven: SetWinEventHook(EVENT_OBJECT_SHOW) + a message loop, so idle CPU
# is exactly zero. No admin rights, no registry, no service, no TouchDesigner API.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File td-dialog-restore.ps1 [-Log]
#
#   -Log   append a line to restore.log next to this script every time a dialog is
#          restored (trimmed to the last 200 lines). Off by default.
#
# Stop:  kill the powershell.exe process running this script, or run toggle.ps1 off.

[CmdletBinding()]
param(
    [switch]$Log
)

$ErrorActionPreference = 'Stop'
$script:Version = '1.0.1'

# ---- single instance: a second copy (e.g. Startup fired twice) exits immediately ----
$script:mutex = New-Object System.Threading.Mutex($false, 'Local\TDDialogRestoreSingleInstance')
try {
    if (-not $script:mutex.WaitOne(0)) { exit 0 }
} catch { }

# ---- logging (optional) ----
function Write-Log([string]$line) {
    if (-not $Log) { return }
    try {
        $path = Join-Path $PSScriptRoot 'restore.log'
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        Add-Content -LiteralPath $path -Value "$stamp  $line" -Encoding UTF8
        $lines = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)
        if ($lines.Count -gt 200) {
            Set-Content -LiteralPath $path -Value ($lines[-200..-1]) -Encoding UTF8
        }
    } catch { }
}

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class TDHook {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }

  public delegate void WinEventDelegate(IntPtr hHook, uint ev, IntPtr hwnd, int idObject, int idChild, uint tid, uint time);
  delegate bool EnumProc(IntPtr h, IntPtr d);

  [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventDelegate cb, uint pid, uint tid, uint flags);
  [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetMessage(out MSG m, IntPtr h, uint min, uint max);
  [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
  [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);

  // keep these alive for the lifetime of the process
  static WinEventDelegate _cb;
  static IntPtr _hook = IntPtr.Zero;

  public static Action<string> OnRestored;

  public static void Start() {
    _cb = new WinEventDelegate(Handler);
    // EVENT_OBJECT_SHOW = 0x8002 ; WINEVENT_OUTOFCONTEXT = 0
    _hook = SetWinEventHook(0x8002, 0x8002, IntPtr.Zero, _cb, 0, 0, 0);
    if (_hook == IntPtr.Zero) throw new Exception("SetWinEventHook failed");
    MSG msg;
    while (GetMessage(out msg, IntPtr.Zero, 0, 0)) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
  }

  static void Handler(IntPtr hHook, uint ev, IntPtr hwnd, int idObject, int idChild, uint tid, uint time) {
    try {
      if (hwnd == IntPtr.Zero || idObject != 0) return;          // OBJID_WINDOW only
      if (!IsWindowVisible(hwnd)) return;
      var cls = new StringBuilder(256); GetClassName(hwnd, cls, 256);
      if (cls.ToString() != "TouchDesigner Window") return;      // TouchDesigner's own window class

      // A TouchDesigner *dialog* is an owned window; the application main window is not.
      // This works for every TD build, whatever its version string, and never touches the
      // main window even if that one is maximized.
      IntPtr owner = GetWindow(hwnd, 4);                          // GW_OWNER
      if (owner == IntPtr.Zero) return;

      var title = new StringBuilder(256); GetWindowText(hwnd, title, 256);
      string t = title.ToString();
      if (t.IndexOf(".toe", StringComparison.OrdinalIgnoreCase) >= 0) return;   // safety net

      if (!IsZoomed(hwnd)) return;                                // only maximized dialogs

      ShowWindow(hwnd, 9);                                        // SW_RESTORE
      System.Threading.Thread.Sleep(120);
      Centre(hwnd, 0.85);
      if (OnRestored != null) OnRestored(t);
    } catch { }
  }

  static void Centre(IntPtr h, double maxFrac) {
    MONITORINFO mi = new MONITORINFO();
    mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
    IntPtr mon = MonitorFromWindow(h, 2);                         // MONITOR_DEFAULTTONEAREST
    if (!GetMonitorInfo(mon, ref mi)) return;
    RECT r; if (!GetWindowRect(h, out r)) return;
    int ww = r.Right - r.Left, wh = r.Bottom - r.Top;
    int workW = mi.rcWork.Right - mi.rcWork.Left;
    int workH = mi.rcWork.Bottom - mi.rcWork.Top;
    int maxW = (int)(workW * maxFrac), maxH = (int)(workH * maxFrac);
    if (ww > maxW) ww = maxW;
    if (wh > maxH) wh = maxH;
    SetWindowPos(h, IntPtr.Zero, mi.rcWork.Left + (workW - ww)/2, mi.rcWork.Top + (workH - wh)/2, ww, wh, 0x0004);
  }
}
"@

[TDHook]::OnRestored = {
    param($t)
    Write-Log ("restored: [" + $t + "]")
    if (-not $Log) { Write-Host ("  restored: [" + $t + "]") -ForegroundColor Green }
}

Write-Log "watcher started (v$($script:Version))"
if (-not $Log) {
    Write-Host "TD Dialog Restore v$($script:Version) - waiting for TouchDesigner dialogs. Ctrl+C to stop." -ForegroundColor Cyan
}
[TDHook]::Start()
