# TD Dialog Restore

**TouchDesigner's floating dialogs — the OP Create Dialog (<kbd>Tab</kbd>), the colour picker,
Window Placement, … — open maximized on some Windows machines, covering the whole monitor with
black padding and putting their resize edge off-screen. This fixes that: each dialog is
un-maximized and centred the moment it appears, however TouchDesigner was started.**

No administrator rights, no registry, no service, no driver, no TouchDesigner API, no project
or preference change. One small PowerShell process, ~0 % idle CPU.

Windows 10 / 11 · PowerShell 5.1 · per-user install · MIT

---

## The symptom

Press <kbd>Tab</kbd> in TouchDesigner and the OP Create Dialog fills the screen:

- the dialog *window* is exactly the monitor rectangle (`0,0 → 1920×1200`) and even covers the taskbar;
- its *content* is laid out at natural size inside that window, so you get thick black bands on the sides;
- the resize grip is off-screen, so the dialog cannot be made smaller by dragging;
- dragging the title bar pops it back to a normal ~1176×949 popup — Windows' own un-maximize —
  but TouchDesigner re-creates it maximized on the next <kbd>Tab</kbd>, and after a restart.

Small dialogs such as the About box (549×251) are fine. Only windows that TouchDesigner creates
in the maximized state are affected.

## Quick start

Open **Windows PowerShell** (no need for admin) and run this single line — it downloads the
installer and runs it:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "iwr -useb https://raw.githubusercontent.com/DIY23/td-dialog-restore/main/install.ps1 -OutFile $env:TEMP\tdr-install.ps1; & $env:TEMP\tdr-install.ps1"
```

Or, if you prefer to see what you run: download the repository (green **Code** button →
*Download ZIP*), unzip it anywhere, and in that folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

Either way the installer:

1. copies the watcher to `%LOCALAPPDATA%\TDDialogRestore\` (so you can delete the download afterwards);
2. adds a Startup shortcut, so it runs hidden at every logon;
3. starts it now and checks that exactly one instance is running.

Sample output:

```
TD Dialog Restore - installer

  source: C:\Users\you\Downloads\td-dialog-restore-main\src\td-dialog-restore.ps1
  installed: C:\Users\you\AppData\Local\TDDialogRestore\td-dialog-restore.ps1
  logon entry: C:\Users\you\AppData\Roaming\Microsoft\Windows\Start Menu\Programs\Startup\TD Dialog Restore.lnk
  running: pid 18040

Installed.
```

Installer options: `-InstallDir <path>`, `-NoStartup` (run it yourself), `-NoStart` (install the
logon entry only), `-NoLog` (no `restore.log`).

## Verify it works

Press <kbd>Tab</kbd> in TouchDesigner: the dialog should appear as a normal popup within half a
second, centred. Or run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\status.ps1
```

which prints the installed version, whether the logon entry is enabled, the running PID, and the
last dialogs restored from `restore.log`.

`verify.ps1` goes further and measures it: it gives TouchDesigner the foreground, sends
<kbd>Tab</kbd>, reads the dialog's window state and tells you **normal** or **MAXIMIZED**
(exit code 0 or 2). Use `-NoInput` to only report, `-Close` to close the dialog afterwards.

## Turn it off and on

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\toggle.ps1 off    # off now, and stays off after reboot
powershell -NoProfile -ExecutionPolicy Bypass -File .\toggle.ps1 on     # back on
powershell -NoProfile -ExecutionPolicy Bypass -File .\toggle.ps1 status # same as status.ps1
```

`off` stops the process and renames the Startup shortcut to `TD Dialog Restore.lnk.disabled`.
Nothing is deleted — `on` renames it back and starts it. The fix then behaves exactly as if it
were never installed; TouchDesigner is untouched in both directions.

Manual equivalent, if you no longer have the scripts: delete (or rename) `TD Dialog Restore.lnk`
in `shell:startup` — type `shell:startup` in the Explorer address bar — and end the
`powershell.exe` whose command line contains `td-dialog-restore.ps1` in Task Manager.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
```

It stops the watcher, removes the Startup shortcut (enabled or disabled) and deletes
`%LOCALAPPDATA%\TDDialogRestore`. `-KeepFiles` stops and de-autostarts it but keeps the script.
It verifies at the end that nothing is left running.

Manual equivalent:

1. `shell:startup` → delete `TD Dialog Restore.lnk` (and `…lnk.disabled` if present);
2. Task Manager → end the `powershell.exe` running `td-dialog-restore.ps1`;
3. delete `%LOCALAPPDATA%\TDDialogRestore`.

That is the whole footprint: one shortcut and one folder. There is no registry key, no scheduled
task, no service, no installer entry under *Apps & features*.

## What it actually does

One process, event-driven — it does not poll:

1. `SetWinEventHook(EVENT_OBJECT_SHOW)` + a message loop: Windows wakes it only when *a window is
   shown*, so idle CPU is literally `0.000 s`.
2. It filters, with no TouchDesigner API at all:
   - window **class** is `TouchDesigner Window` (TouchDesigner's own UI class, shared by the main
     window and all its floating dialogs);
   - the window is **owned** (`GetWindow(hwnd, GW_OWNER) != 0`) — dialogs are owned by the main
     window, the application window is not;
   - it is currently **maximized** (`IsZoomed`).
3. On a match: `ShowWindow(SW_RESTORE)`, then `SetWindowPos()` to centre it on its monitor, capped
   at 85 % of the work area.

It only ever calls those three functions on a window it recognises. It cannot modify TouchDesigner
data, preferences, `.toe` files or licences.

**Measured cost** (Legion Go, Windows 11, PowerShell 5.1): 0.000 s CPU over 12 s idle, ~72 MB
working set — that is the `powershell.exe` host's own floor, not the script. Compare with the
polling prototype this replaced: 0.62 % of one core, continuously.

If you would rather have no PowerShell host at all, `src\td-dialog-restore.cs` is the same logic as
a ~8 KB standalone `.exe` — see [below](#the-standalone-exe-optional).

## Requirements

| | |
|---|---|
| OS | Windows 10 or 11, x64 or ARM64 |
| Shell | Windows PowerShell 5.1 (present on every Windows 10/11) |
| Rights | none — the install is per-user, in your own profile |
| TouchDesigner | any build, any number of builds side by side |
| Network | only for the download |

## Compatibility

- **Any TouchDesigner build** — 2025, 2024, 099-style version strings: the detection never parses
  a version, a path, or an executable name.
- **Parallel installs** — every installed build whose main window is open is covered by the same
  watcher; installing or removing a build needs no reconfiguration.
- **Several TouchDesigner instances at once** — each instance's dialogs are handled independently.
- **A build that does not create dialogs maximized** — nothing matches `IsZoomed`, so the watcher
  does nothing at all. Safe no-op.
- **If Derivative ever renames the window class** — it silently stops acting. The failure mode is
  "does nothing", never "does something wrong".
- Runs in **your user account** only (a different Windows user would need their own install), and
  it acts on *any* TouchDesigner dialog that opens maximized — including one you maximize on
  purpose.

## Why this happens

On the machine this was written for (Lenovo Legion Go, Windows 11 26200, a rotated OLED panel),
TouchDesigner 2025.33230 creates its floating dialogs with `showCmd = SW_SHOWMAXIMIZED`. The
measurements that pointed at an environmental cause rather than a project, preference or build
problem:

| Probe | Value |
|---|---|
| `GetDpiForSystem()` | 96 (100 %) — fixed at logon, ignores the scale slider |
| `GetDpiForWindow(TD main)` / monitor DPI | 144 (150 %) |
| `GetDeviceCaps(HORZRES/VERTRES)` | 800×1280 **portrait** for a 1920×1200 landscape desktop |
| `dmDisplayOrientation` | 1 (90°) — the panel is physically portrait and presented rotated |

Portrait metrics and a system DPI that disagrees with the monitor scale are a plausible reason for
TouchDesigner's dialog sizing to end up maximized. The symptom reproduced identically at 100 / 125 /
150 % scaling, at 1920×1200 and 2560×1600, on a brand-new default project, with default
preferences, with Parsec stopped and with a rebuilt font cache — so nothing user-settable changes it.

The full investigation, including everything that was ruled out, is in
[docs/DIAGNOSIS.md](docs/DIAGNOSIS.md). It is a workaround for a TouchDesigner behaviour, not a fix
for it: the real fix belongs in TouchDesigner, and a short bug report you can send to Derivative is
at the end of that document.

## The standalone .exe (optional)

`src\td-dialog-restore.cs` builds the same watcher as a ~8 KB .NET executable with no PowerShell
host, no console, and a smaller footprint (~15 MB). The installers above use the PowerShell script
because it always works: `powershell.exe` is Microsoft-signed.

On a machine with **Smart App Control** in enforce mode (`VerifiedAndReputablePolicyState = 1`), a
newly compiled, unsigned `.exe` is refused — the CodeIntegrity log shows event 3077, *"did not meet
the Enterprise signing level requirements or violated code integrity policy"*. That is what
happened on the machine this was written for, and why the shipping version is PowerShell.

If you want the exe anyway (SAC off, or you sign it yourself):

```
csc /nologo /target:winexe /platform:anycpu /optimize+ /out:td-dialog-restore.exe src\td-dialog-restore.cs
```

Modes: no argument = attach and exit a few seconds after the last TouchDesigner quits;
`--launch <touchdesigner.exe>` = start TouchDesigner too and exit with it; `--stay` = stay resident
(what a Startup shortcut would use).

## Troubleshooting

| Symptom | Check |
|---|---|
| Dialogs still open maximized | `.\status.ps1` — is a watcher running, and is the logon entry enabled? |
| Nothing happens at logon | The shortcut may have been renamed to `…lnk.disabled` (i.e. `toggle.ps1 off` was used); `.\toggle.ps1 on`. |
| `status.ps1` says "no entry" | Installed with `-NoStartup`, or uninstalled. Run `install.ps1`. |
| Started manually, exits immediately | Another instance is already running — that is the single-instance guard working. |
| `verify.ps1` says "no dialog appeared" | TouchDesigner needs a focusable main window and an open project; run it from a session where TD is not minimised. |
| Two watchers appear in Task Manager | Should be impossible (named mutex); run `.\uninstall.ps1` then `install.ps1` again. |
| Antivirus complains about a PowerShell script | It only calls `SetWinEventHook`, `ShowWindow` and `SetWindowPos` on TouchDesigner windows; read `src\td-dialog-restore.ps1` — it is 200 lines, no download, no network at runtime. |
| You want it gone for good | `.\uninstall.ps1`, then delete the downloaded folder. |

## Repository contents

```
install.ps1                 install (copy, logon entry, start, verify)
uninstall.ps1               remove everything, verify clean
toggle.ps1                  off / on / status without uninstalling
status.ps1                  what is installed and running, last restores
verify.ps1                  test aid: send Tab to TD, measure the dialog
src/td-dialog-restore.ps1   the watcher (this is what runs)
src/td-dialog-restore.cs    same logic as a standalone .exe (optional)
docs/DIAGNOSIS.md           the full investigation and the upstream bug report
```

## Credits and licence

Written while diagnosing the issue on the owner's machine; the diagnosis and the implementations
were developed with [Hermes Agent](https://hermes-agent.nousresearch.com). MIT licence — see
[LICENSE](LICENSE).

Not affiliated with Derivative. TouchDesigner is a trademark of Derivative Inc.
