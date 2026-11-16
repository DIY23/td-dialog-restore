# verify.ps1 - TD Dialog Restore (test aid)
#
# Opens the OP Create Dialog in a running TouchDesigner (sends Tab to it) and reports
# whether the dialog came up as a normal popup or maximized. This is exactly the
# measurement the fix is judged on - use it to check that the watcher is doing its job.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 -Close
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\verify.ps1 -NoInput   # just report
#
# WARNING: it gives TouchDesigner the foreground for a moment (that is the only way to
# deliver Tab reliably), so do not run it while you are busy inside TouchDesigner.
#
# Exit codes: 0 = dialog normal (fix working), 2 = dialog maximized (not fixed),
#             3 = no dialog appeared, 4 = TouchDesigner not running.

[CmdletBinding()]
param(
    [switch]$Close,
    [switch]$NoInput,
    [int]$TimeoutMs = 3000
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections.Generic;

public class TDProbe {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int x, y; }
  [StructLayout(LayoutKind.Sequential)] public struct WINDOWPLACEMENT {
    public int length; public int flags; public int showCmd;
    public POINT ptMinPosition; public POINT ptMaxPosition; public RECT rcNormalPosition;
  }
  [StructLayout(LayoutKind.Sequential)] public struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
  [StructLayout(LayoutKind.Explicit, Size = 40)] public struct INPUT { [FieldOffset(0)] public uint type; [FieldOffset(8)] public MOUSEINPUT mi; [FieldOffset(8)] public KEYBDINPUT ki; }

  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint a, uint b, bool f);
  [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet=CharSet.Auto)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetWindowPlacement(IntPtr h, ref WINDOWPLACEMENT wp);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr d);
  [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] i, int size);
  public delegate bool EnumProc(IntPtr h, IntPtr d);

  static void Key(ushort vk, ushort scan, bool up) {
    var i = new INPUT { type = 1 };
    i.ki.wVk = vk; i.ki.wScan = scan; i.ki.dwFlags = (uint)(0x0001 | (up ? 0x0002 : 0));   // SCANCODE | KEYUP
    SendInput(1, new INPUT[] { i }, Marshal.SizeOf(typeof(INPUT)));
  }
  public static void Tap(ushort vk, ushort scan) { Key(vk, scan, false); System.Threading.Thread.Sleep(90); Key(vk, scan, true); }

  // SetForegroundWindow is refused unless we share the foreground thread's input state
  public static void Force(IntPtr h) {
    IntPtr f = GetForegroundWindow(); uint ft; GetWindowThreadProcessId(f, out ft);
    AttachThreadInput(ft, GetCurrentThreadId(), true);
    Key(0x12, 0x38, false); Key(0x12, 0x38, true);      // a harmless Alt tap
    SetForegroundWindow(h);
    AttachThreadInput(ft, GetCurrentThreadId(), false);
  }

  public static IntPtr FindOwnedDialog(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, d) => {
      uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid) return true;
      if (!IsWindowVisible(h)) return true;
      var c = new StringBuilder(256); GetClassName(h, c, 256);
      if (c.ToString() != "TouchDesigner Window") return true;
      if (GetWindow(h, 4) == IntPtr.Zero) return true;          // GW_OWNER: dialogs only
      found = h; return false;
    }, IntPtr.Zero);
    return found;
  }

  public static string Describe(IntPtr h) {
    var wp = new WINDOWPLACEMENT(); wp.length = Marshal.SizeOf(typeof(WINDOWPLACEMENT));
    GetWindowPlacement(h, ref wp);
    RECT r; GetWindowRect(h, out r);
    string state = wp.showCmd == 3 ? "MAXIMIZED" : (wp.showCmd == 1 ? "normal" : "showCmd=" + wp.showCmd);
    var t = new StringBuilder(300); GetWindowText(h, t, 300);
    return string.Format("{0} | {1}x{2} at ({3},{4}) | zoomed={5} | title=[{6}]",
      state, r.Right - r.Left, r.Bottom - r.Top, r.Left, r.Top, IsZoomed(h), t.ToString());
  }

  public static string Rect(IntPtr h) {
    RECT r; if (!GetWindowRect(h, out r)) return "?";
    return string.Format("{0}x{1} at ({2},{3})", r.Right - r.Left, r.Bottom - r.Top, r.Left, r.Top);
  }
}
"@

[void][TDProbe]::SetProcessDPIAware()

$td = @(Get-Process touchdesigner -ErrorAction SilentlyContinue)
if ($td.Count -eq 0) { Write-Host 'TouchDesigner is not running - start it first.' -ForegroundColor Yellow; exit 4 }
$tdProc = $td[0]
$main = $tdProc.MainWindowHandle

Write-Host ''
Write-Host "TD Dialog Restore - verify  (TD pid $($tdProc.Id))" -ForegroundColor Cyan
Write-Host "  main window: $([TDProbe]::Rect($main))"
Write-Host ''

if (-not $NoInput) {
    [TDProbe]::Force($main)
    Start-Sleep -Milliseconds 300
    Write-Host '  sending Tab to TouchDesigner...'
    [TDProbe]::Tap(0x09, 0x0F)                     # VK_TAB, scancode 0x0F
}

$dialog = [IntPtr]::Zero
$waited = 0
while ($waited -lt $TimeoutMs -and $dialog -eq [IntPtr]::Zero) {
    Start-Sleep -Milliseconds 250
    $waited += 250
    $dialog = [TDProbe]::FindOwnedDialog([uint32]$tdProc.Id)
}

if ($dialog -eq [IntPtr]::Zero) {
    Write-Host "  no TouchDesigner dialog appeared within $TimeoutMs ms." -ForegroundColor Yellow
    Write-Host '  (Nothing to measure. Is the main window focused and a project open?)'
    exit 3
}

$desc = [TDProbe]::Describe($dialog)
Write-Host "  dialog: $desc"
Write-Host ''

$zoomed = $desc.StartsWith('MAXIMIZED')
if ($zoomed) {
    Write-Host 'RESULT: dialog opened MAXIMIZED - the watcher is not running or not working.' -ForegroundColor Red
    Write-Host '        Fix: .\toggle.ps1 on   (or run status.ps1 to see what is missing)'
} else {
    Write-Host 'RESULT: dialog opened as a normal popup - the fix is working.' -ForegroundColor Green
}

if ($Close) {
    [TDProbe]::Force($main)
    Start-Sleep -Milliseconds 200
    [TDProbe]::Tap(0x1B, 0x01)                     # VK_ESCAPE, scancode 0x01
    Write-Host '  dialog closed (Esc).'
}

Write-Host ''
exit $(if ($zoomed) { 2 } else { 0 })
