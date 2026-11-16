using System;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

[assembly: AssemblyTitle("TD Dialog Restore")]
[assembly: AssemblyDescription("Un-maximises TouchDesigner floating dialogs that are created maximized")]
[assembly: AssemblyProduct("TD Dialog Restore")]
[assembly: AssemblyCompany("")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

// TD Dialog Restore - un-maximises TouchDesigner floating dialogs the moment they are shown.
//
// Why: on this machine (rotated OLED panel; GetDpiForSystem() != monitor DPI) TouchDesigner
// creates its floating dialogs (OP Create Dialog, colour picker, Window Placement, ...) in a
// maximized state, so they cover the whole monitor with black padding and their resize edge
// lands off-screen. Dragging the title bar restores them, but TD does not remember it.
//
// Event-driven (SetWinEventHook + message loop): 0% CPU while idle.
// Modes:
//   (no args)            attach, and exit a few seconds after the last TouchDesigner quits
//   --launch <exe>       start TouchDesigner too, exit when it quits (waits on its handle)
//   --stay               daemon: stay resident (use with a Startup shortcut), never self-exit

static class TDDialogRestore
{
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX; public int ptY; }

    delegate void WinEventDelegate(IntPtr hHook, uint ev, IntPtr hwnd, int idObject, int idChild, uint tid, uint time);

    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr hmod, WinEventDelegate cb, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool GetMessage(out MSG m, IntPtr h, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetClassName(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll", CharSet = CharSet.Auto)] static extern int GetWindowText(IntPtr h, StringBuilder s, int m);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr mon, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);

    static WinEventDelegate _cb;   // must stay referenced
    static Mutex _single;          // must stay referenced

    static int Main(string[] args)
    {
        // one instance is enough; a second launch just exits quietly
        bool created;
        _single = new Mutex(true, @"Local\TDDialogRestoreSingleInstance", out created);
        if (!created) return 0;

        string launchPath = null;
        bool stay = false;
        for (int i = 0; i < args.Length; i++)
        {
            if ((args[i] == "--launch" || args[i] == "-l") && i + 1 < args.Length) launchPath = args[i + 1];
            if (args[i] == "--stay" || args[i] == "-s") stay = true;   // daemon mode: never self-exit
        }

        // if we launched TD ourselves we hold its handle: wait on it (costs nothing),
        // instead of polling for the process every couple of seconds
        Process launched = null;
        if (launchPath != null)
        {
            try
            {
                launched = Process.Start(new ProcessStartInfo(launchPath) { UseShellExecute = true });
            }
            catch { return 2; }
        }

        Thread dog = new Thread(delegate ()
        {
            if (stay) return;                       // daemon: lives until logoff, no exit logic
            if (launched != null)
            {
                try { launched.WaitForExit(); Environment.Exit(0); } catch { }
            }
            Watchdog();
        });
        dog.IsBackground = true;
        dog.Start();

        _cb = new WinEventDelegate(Handler);
        IntPtr hk = SetWinEventHook(0x8002, 0x8002, IntPtr.Zero, _cb, 0, 0, 0);   // EVENT_OBJECT_SHOW, OUTOFCONTEXT
        if (hk == IntPtr.Zero) return 3;

        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0)) { TranslateMessage(ref msg); DispatchMessage(ref msg); }
        return 0;
    }

    // exits the process shortly after TouchDesigner goes away, so nothing lingers
    static void Watchdog()
    {
        bool seenTd = Process.GetProcessesByName("touchdesigner").Length > 0;
        int gone = 0;
        while (true)
        {
            Thread.Sleep(2000);
            int n = Process.GetProcessesByName("touchdesigner").Length;
            if (n > 0) { seenTd = true; gone = 0; continue; }
            if (!seenTd) continue;              // launched before TD came up: keep waiting
            if (++gone >= 2) Environment.Exit(0);
        }
    }

    static void Handler(IntPtr hHook, uint ev, IntPtr hwnd, int idObject, int idChild, uint tid, uint time)
    {
        try
        {
            if (hwnd == IntPtr.Zero || idObject != 0) return;      // OBJID_WINDOW only
            if (!IsWindowVisible(hwnd)) return;

            var cls = new StringBuilder(256);
            GetClassName(hwnd, cls, 256);
            if (cls.ToString() != "TouchDesigner Window") return;

            // A TouchDesigner *dialog* is an owned window; the application main window is not.
            // No title/version parsing, so this works for every TD build.
            if (GetWindow(hwnd, 4) == IntPtr.Zero) return;           // GW_OWNER

            var t = new StringBuilder(256);
            GetWindowText(hwnd, t, 256);
            if (t.ToString().IndexOf(".toe", StringComparison.OrdinalIgnoreCase) >= 0) return;  // safety net
            if (!IsZoomed(hwnd)) return;                            // only maximized dialogs

            ShowWindow(hwnd, 9);                                    // SW_RESTORE
            Thread.Sleep(120);
            Centre(hwnd, 0.85);
        }
        catch { }
    }

    static void Centre(IntPtr h, double maxFrac)
    {
        var mi = new MONITORINFO();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        IntPtr mon = MonitorFromWindow(h, 2);                       // MONITOR_DEFAULTTONEAREST
        if (!GetMonitorInfo(mon, ref mi)) return;

        RECT r;
        if (!GetWindowRect(h, out r)) return;
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        int workW = mi.rcWork.Right - mi.rcWork.Left;
        int workH = mi.rcWork.Bottom - mi.rcWork.Top;
        int maxW = (int)(workW * maxFrac), maxH = (int)(workH * maxFrac);
        if (w > maxW) w = maxW;
        if (ht > maxH) ht = maxH;
        SetWindowPos(h, IntPtr.Zero, mi.rcWork.Left + (workW - w) / 2, mi.rcWork.Top + (workH - ht) / 2, w, ht, 0x0004);
    }
}
